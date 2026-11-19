// Native listening and speaking for Claude Frame.
//
// One steady audio setup (play and record, through the speaker) is chosen at
// launch and never switched, so the microphone and the voice can't fight over
// the device's audio the way they do in Safari. Everything here runs on the
// main thread; work from audio threads hops back with DispatchQueue.main.

import AVFoundation
import Speech
import UIKit

final class NativeAudio: NSObject {
    static let shared = NativeAudio()

    /// Sends an event to the page (set by the web view).
    var send: ([String: Any]) -> Void = { _ in }

    // Listening
    private var engine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var listenId: String?
    private var gotText = false
    private var listenStarted = Date()
    private var quickFailures = 0

    // Wake phrase: between conversations, listen quietly for "Hey Claude".
    private enum Mode { case listen, wake }
    private var mode = Mode.listen
    private var wakeWanted = false
    private var wakePattern: NSRegularExpression?
    private var wakeCount = 0
    private var wakeFastFails = 0
    private var adoptedFromWake = false

    // Playing the cloud voice (ElevenLabs or Aura)
    private var player: AVAudioPlayer?
    private var playId: String?
    private var link: CADisplayLink?

    // This device's own voices
    private let synth = AVSpeechSynthesizer()
    private let synthEvents = SynthEvents()
    private var voiceIds: [String: String] = [:]
    private var voices: [[String: String]] = []

    private override init() {
        super.init()
        configureSession()
        synth.usesApplicationAudioSession = true
        synth.delegate = synthEvents
        synthEvents.onEvent = { [weak self] event in self?.send(event) }
        loadVoices()
        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(interrupted(_:)), name: AVAudioSession.interruptionNotification, object: nil)
        nc.addObserver(self, selector: #selector(mediaReset), name: AVAudioSession.mediaServicesWereResetNotification, object: nil)
    }

    // MARK: - Audio setup

    private func configureSession() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playAndRecord, mode: .default,
                                    options: [.defaultToSpeaker, .allowBluetoothA2DP, .allowAirPlay])
            try session.setActive(true)
        } catch {
            print("Claude Frame: audio setup failed: \(error)")
        }
    }

    func activate() {
        try? AVAudioSession.sharedInstance().setActive(true)
    }

    func stopAll() {
        wakeWanted = false
        if let id = listenId {
            teardown(cancel: true); listenId = nil
            if mode == .listen { send(["type": "end", "id": id]) }
        }
        stopPlayback()
        synth.stopSpeaking(at: .immediate)
    }

    @objc private func interrupted(_ note: Notification) {
        guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              let kind = AVAudioSession.InterruptionType(rawValue: raw) else { return }
        DispatchQueue.main.async {
            if kind == .began { self.stopAll() } else { self.activate() }
        }
    }

    @objc private func mediaReset() {
        DispatchQueue.main.async {
            if let id = self.listenId { self.send(["type": "end", "id": id]) }
            self.listenId = nil
            self.request = nil
            self.task = nil
            self.engine = AVAudioEngine()
            self.configureSession()
        }
    }

    // MARK: - Messages from the page

    func handle(_ m: [String: Any]) {
        let type = m["type"] as? String ?? ""
        let id = m["id"] as? String ?? ""
        switch type {
        case "hello":
            send(["type": "voices", "voices": voices])
        case "listen":
            startListening(id: id, lang: m["lang"] as? String ?? "en-US")
        case "stopListening":
            stopListening(id: id)
        case "abortListening":
            abortListening(id: id)
        case "play":
            play(id: id, base64: m["b64"] as? String ?? "")
        case "stopAudio":
            stopPlayback()
        case "say":
            let rate = (m["rate"] as? NSNumber)?.floatValue ?? 1
            say(id: id, text: m["text"] as? String ?? "", voice: m["voice"] as? String ?? "", rate: rate)
        case "stopSay":
            synth.stopSpeaking(at: .immediate)
        case "wakeOn":
            wakeOn(names: m["names"] as? [String] ?? ["claude"])
        case "wakeOff":
            wakeOff()
        default:
            break
        }
    }

    // MARK: - Listening

    private func startListening(id: String, lang: String) {
        if let old = listenId {
            teardown(cancel: true); listenId = nil
            if mode == .listen { send(["type": "end", "id": old]) }
        }
        stopPlayback()
        wakeWanted = false
        mode = .listen
        adoptedFromWake = false
        listenId = id
        gotText = false
        NativeAudio.askPermission { [weak self] allowed in
            guard let self, self.listenId == id else { return }
            if allowed {
                self.begin(id: id, lang: lang)
            } else {
                self.send(["type": "error", "id": id, "error": "not-allowed"])
                self.finish(id)
            }
        }
    }

    private static func askPermission(_ done: @escaping (Bool) -> Void) {
        let speechOK = SFSpeechRecognizer.authorizationStatus() == .authorized
        let micOK = AVAudioApplication.shared.recordPermission == .granted
        if speechOK && micOK { done(true); return }
        SFSpeechRecognizer.requestAuthorization { status in
            AVAudioApplication.requestRecordPermission { granted in
                DispatchQueue.main.async { done(status == .authorized && granted) }
            }
        }
    }

    private func begin(id: String, lang: String) {
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: lang)) ?? SFSpeechRecognizer(),
              recognizer.isAvailable else { failedToStart(id); return }

        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        req.addsPunctuation = true
        req.taskHint = .dictation
        if recognizer.supportsOnDeviceRecognition { req.requiresOnDeviceRecognition = true }   // faster, no daily limit

        activate()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { failedToStart(id); return }
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: format, block: NativeAudio.makeTap(req, id: id))
        engine.prepare()
        do { try engine.start() } catch {
            input.removeTap(onBus: 0)
            failedToStart(id)
            return
        }
        request = req
        listenStarted = Date()
        task = recognizer.recognitionTask(with: req, resultHandler: NativeAudio.makeResultHandler(id: id))
    }

    // Built outside the class's own methods so these closures carry no thread assumptions.
    private static func makeTap(_ req: SFSpeechAudioBufferRecognitionRequest, id: String) -> AVAudioNodeTapBlock {
        let told = Flag()
        return { buffer, _ in
            req.append(buffer)
            if !told.value {
                told.value = true
                DispatchQueue.main.async { NativeAudio.shared.heardAudio(id) }
            }
        }
    }

    private static func makeResultHandler(id: String) -> (SFSpeechRecognitionResult?, Error?) -> Void {
        return { result, error in
            let text = result?.bestTranscription.formattedString
            let isFinal = result?.isFinal ?? false
            let failed = error != nil
            DispatchQueue.main.async {
                NativeAudio.shared.recognized(id: id, text: text, isFinal: isFinal, failed: failed)
            }
        }
    }

    private func heardAudio(_ id: String) {
        if listenId == id && mode == .listen { send(["type": "audiostart", "id": id]) }
    }

    private func recognized(id: String, text rawText: String?, isFinal: Bool, failed: Bool) {
        guard listenId == id else { return }
        if mode == .wake { wakeHeard(id: id, text: rawText, isFinal: isFinal, failed: failed); return }
        var text = rawText
        if adoptedFromWake, let t = rawText { text = afterWakePhrase(t) ?? t }
        if let text, !text.isEmpty {
            gotText = true
            send(["type": "result", "id": id, "text": text, "final": isFinal])
        }
        guard isFinal || failed else { return }
        // Keep the page from retrying forever if recognition keeps failing at once.
        if failed && !gotText && Date().timeIntervalSince(listenStarted) < 1.5 { quickFailures += 1 } else { quickFailures = 0 }
        if quickFailures >= 3 {
            quickFailures = 0
            send(["type": "error", "id": id, "error": "service-not-allowed"])
        }
        finish(id)
    }

    private func failedToStart(_ id: String) {
        if mode == .wake { endWakeSession(id, failed: true); return }
        send(["type": "error", "id": id, "error": "audio-capture"])
        finish(id)
    }

    // MARK: - Wake phrase

    private func wakeOn(names: [String]) {
        var words = ["claude", "cloud", "clod", "claud", "clawed", "klaud", "claudia"]
        for n in names {
            let w = n.lowercased().filter { $0.isLetter }
            if !w.isEmpty && !words.contains(w) { words.append(w) }
        }
        wakePattern = try? NSRegularExpression(pattern: "\\b(hey|hi|okay|ok)[\\s,]+(" + words.joined(separator: "|") + ")\\b",
                                               options: [.caseInsensitive])
        wakeWanted = true
        if listenId == nil { startWake() }
    }

    private func wakeOff() {
        wakeWanted = false
        if listenId != nil, mode == .wake { teardown(cancel: true); listenId = nil }
    }

    private func startWake() {
        guard wakeWanted, listenId == nil, player == nil, !synth.isSpeaking else { return }
        wakeCount += 1
        let id = "w\(wakeCount)"
        listenId = id
        mode = .wake
        adoptedFromWake = false
        gotText = false
        NativeAudio.askPermission { [weak self] allowed in
            guard let self, self.listenId == id, self.mode == .wake else { return }
            if allowed { self.begin(id: id, lang: "en-US") } else { self.listenId = nil; self.wakeWanted = false }
        }
        // Recognition sessions are kept short; start a fresh one every 50 seconds.
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 50_000_000_000)
            let me = NativeAudio.shared
            guard me.listenId == id, me.mode == .wake else { return }
            me.teardown(cancel: true)
            me.listenId = nil
            me.startWake()
        }
    }

    private func wakeHeard(id: String, text: String?, isFinal: Bool, failed: Bool) {
        if let text, let rest = afterWakePhrase(text) {
            // Heard the phrase: this same session becomes a normal conversation turn,
            // so words said right after the phrase aren't lost.
            mode = .listen
            adoptedFromWake = true
            wakeFastFails = 0
            gotText = !rest.isEmpty
            listenStarted = Date()
            send(["type": "wake", "id": id, "text": rest])
            if isFinal || failed { finish(id) }
            return
        }
        if isFinal || failed { endWakeSession(id, failed: failed) }
    }

    private func endWakeSession(_ id: String, failed: Bool) {
        let quick = Date().timeIntervalSince(listenStarted) < 1.5
        teardown(cancel: true)
        if listenId == id { listenId = nil }
        wakeFastFails = (failed && quick) ? wakeFastFails + 1 : 0
        let wait: UInt64 = wakeFastFails >= 3 ? 10_000_000_000 : 300_000_000
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: wait)
            NativeAudio.shared.startWake()
        }
    }

    /// The words after the last "hey claude" in a transcript, or nil if it isn't there.
    private func afterWakePhrase(_ text: String) -> String? {
        guard let re = wakePattern else { return nil }
        let ns = text as NSString
        guard let m = re.matches(in: text, range: NSRange(location: 0, length: ns.length)).last else { return nil }
        let rest = ns.substring(from: m.range.location + m.range.length)
        return rest.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters))
    }

    /// The page heard a pause: stop the microphone and let the last words come in.
    private func stopListening(id: String) {
        guard listenId == id else { return }
        stopMicrophone()
        request?.endAudio()
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard NativeAudio.shared.listenId == id else { return }
            NativeAudio.shared.task?.cancel()
            NativeAudio.shared.finish(id)
        }
    }

    private func abortListening(id: String) {
        guard listenId == id else { return }
        teardown(cancel: true)
        listenId = nil
        send(["type": "end", "id": id])
    }

    private func finish(_ id: String) {
        teardown(cancel: false)
        if listenId == id { listenId = nil }
        send(["type": "end", "id": id])
    }

    private func stopMicrophone() {
        if engine.isRunning { engine.stop() }
        engine.inputNode.removeTap(onBus: 0)
    }

    private func teardown(cancel: Bool) {
        stopMicrophone()
        request?.endAudio()
        request = nil
        if cancel { task?.cancel() }
        task = nil
    }

    // MARK: - Playing the cloud voice

    private func pauseWake() {
        wakeWanted = false
        if listenId != nil, mode == .wake { teardown(cancel: true); listenId = nil }
    }

    private func play(id: String, base64: String) {
        pauseWake()
        stopPlayback()
        guard let data = Data(base64Encoded: base64),
              let p = try? AVAudioPlayer(data: data) else {
            send(["type": "played", "id": id])
            return
        }
        activate()
        p.isMeteringEnabled = true
        p.prepareToPlay()
        guard p.play() else { send(["type": "played", "id": id]); return }
        player = p
        playId = id
        if link == nil {
            let l = CADisplayLink(target: self, selector: #selector(tick))
            l.preferredFramesPerSecond = 30
            l.add(to: .main, forMode: .common)
            link = l
        }
    }

    private func stopPlayback() {
        guard let p = player, let id = playId else { return }
        p.stop()
        player = nil
        playId = nil
        send(["type": "level", "value": 0])
        send(["type": "played", "id": id])
    }

    // About 30 times a second: tell the page how loud the voice is, for the mouth.
    @objc private func tick() {
        if let p = player, let id = playId {
            if p.isPlaying {
                p.updateMeters()
                let loud = powf(10, p.averagePower(forChannel: 0) / 20)
                send(["type": "level", "value": Double(min(1, loud * 4.5))])
            } else {
                player = nil
                playId = nil
                send(["type": "level", "value": 0])
                send(["type": "played", "id": id])
            }
        }
        if player == nil {
            link?.invalidate()
            link = nil
        }
    }

    // MARK: - This device's own voice

    private func loadVoices() {
        var list: [[String: String]] = []
        var ids: [String: String] = [:]
        for v in AVSpeechSynthesisVoice.speechVoices() where v.language.hasPrefix("en") {
            if v.voiceTraits.contains(.isNoveltyVoice) || v.voiceTraits.contains(.isPersonalVoice) { continue }
            var name = v.name
            switch v.quality {
            case .premium: name += " (Premium)"
            case .enhanced: name += " (Enhanced)"
            default: break
            }
            if v.language != "en-US" { name += " · " + v.language }
            if ids[name] != nil { continue }
            ids[name] = v.identifier
            list.append(["name": name, "lang": v.language])
        }
        voiceIds = ids
        voices = list
    }

    private func say(id: String, text: String, voice: String, rate: Float) {
        let u = AVSpeechUtterance(string: text)
        if let ident = voiceIds[voice], let v = AVSpeechSynthesisVoice(identifier: ident) {
            u.voice = v
        } else {
            u.voice = AVSpeechSynthesisVoice(language: "en-US")
        }
        u.rate = max(AVSpeechUtteranceMinimumSpeechRate,
                     min(AVSpeechUtteranceMaximumSpeechRate, AVSpeechUtteranceDefaultSpeechRate * rate))
        synthEvents.tag(u, id)
        pauseWake()
        activate()
        synth.speak(u)
    }
}

/// Tells the page when a device-voice sentence starts, moves and ends.
final class SynthEvents: NSObject, AVSpeechSynthesizerDelegate {
    var onEvent: (([String: Any]) -> Void)?
    private var tags: [ObjectIdentifier: String] = [:]

    func tag(_ u: AVSpeechUtterance, _ id: String) { tags[ObjectIdentifier(u)] = id }

    func speechSynthesizer(_ s: AVSpeechSynthesizer, didStart u: AVSpeechUtterance) { emit("sayStart", u, done: false) }
    func speechSynthesizer(_ s: AVSpeechSynthesizer, willSpeakRangeOfSpeechString r: NSRange, utterance u: AVSpeechUtterance) { emit("boundary", u, done: false) }
    func speechSynthesizer(_ s: AVSpeechSynthesizer, didFinish u: AVSpeechUtterance) { emit("spoke", u, done: true) }
    func speechSynthesizer(_ s: AVSpeechSynthesizer, didCancel u: AVSpeechUtterance) { emit("spoke", u, done: true) }

    private func emit(_ type: String, _ u: AVSpeechUtterance, done: Bool) {
        let key = ObjectIdentifier(u)
        DispatchQueue.main.async {
            guard let id = self.tags[key] else { return }
            if done { self.tags[key] = nil }
            self.onEvent?(["type": type, "id": id])
        }
    }
}

/// A tiny box so the microphone tap can remember it already reported audio.
final class Flag { var value = false }
