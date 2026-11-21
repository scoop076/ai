import AVFoundation
import Foundation

/// Speaks Mibo's reply sentence by sentence through the TV. Each sentence's
/// audio is fetched from the server (Cloudflare Aura) while the one before it
/// plays. If the server's voice isn't available, the Apple TV's own voice is used.
@MainActor
final class Speaker: NSObject, ObservableObject {
    /// The sentence being spoken and how many of its words have been said (for karaoke captions).
    @Published private(set) var line = ""
    @Published private(set) var wordsSaid = 0
    @Published private(set) var isSpeaking = false

    var server: MiboServer?
    var voice = "luna"
    var rate: Float = 1.0
    /// Called once everything queued has been spoken and `finishQueue()` was called.
    var onDone: (() -> Void)?

    private struct Chunk { let shown: String; let said: String; var audio: Task<Data?, Never>? }
    private var queue: [Chunk] = []
    private var player: AVAudioPlayer?
    private let synth = AVSpeechSynthesizer()
    private var queueClosed = false
    private var playing = false
    private var generation = 0
    private var ticker: Timer?
    // Short cues like "Yes?", fetched ahead of time so they play instantly.
    private var cueAudio: [String: Data] = [:]
    private var cuePlayer: AVAudioPlayer?
    /// Until when a cue (hello, goodbye) is still coming out of the TV, so the app can ignore
    /// the microphone meanwhile instead of hearing Mibo's own hello as Jim talking.
    private(set) var cueUntil = Date.distantPast

    override init() {
        super.init()
        synth.delegate = self
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
        try? AVAudioSession.sharedInstance().setActive(true)
    }

    /// Words as they should sound (the captions keep the real spelling).
    static func forVoice(_ s: String) -> String {
        s.replacingOccurrences(of: "\\bMibo\\b", with: "Meebo", options: [.regularExpression, .caseInsensitive])
         .replacingOccurrences(of: "\\bCollinsville\\b", with: "Collinsvil", options: [.regularExpression, .caseInsensitive])
    }

    func begin() {
        stop()
        queueClosed = false
    }

    func add(_ text: String) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        var c = Chunk(shown: t, said: Self.forVoice(t), audio: nil)
        c.audio = fetch(c.said)
        queue.append(c)
        if !playing { playNext() }
    }

    /// No more sentences are coming.
    func finishQueue() {
        queueClosed = true
        if !playing && queue.isEmpty { finished() }
    }

    func stop() {
        generation += 1
        for c in queue { c.audio?.cancel() }
        queue.removeAll()
        player?.stop(); player = nil
        if synth.isSpeaking { synth.stopSpeaking(at: .immediate) }
        ticker?.invalidate(); ticker = nil
        playing = false
        isSpeaking = false
        queueClosed = true
        line = ""; wordsSaid = 0
    }

    /// Loudness of the voice right now (0...1), or -1 when unknown, for the mouth.
    /// While the next sentence's audio is still on its way, this is 0, so the mouth stays still.
    var level: Double {
        guard let p = player, p.isPlaying else { return synth.isSpeaking ? -1 : 0 }
        p.updateMeters()
        let db = Double(p.averagePower(forChannel: 0))
        return min(1, max(0, pow(10, db / 20) * 4))
    }

    // MARK: Cues

    /// Fetch a short cue in the current voice ahead of time.
    func prepareCue(_ text: String) {
        let key = voice + "|" + text
        guard cueAudio[key] == nil, let server else { return }
        let v = voice
        Task {
            if let d = try? await server.speech(Self.forVoice(text), voice: v) { self.cueAudio[key] = d }
        }
    }

    /// Say a short cue right now, outside the reply queue, in Mibo's own voice. If it isn't
    /// fetched yet, fetch it now; only if that fails does the Apple TV's voice say it.
    func cue(_ text: String) {
        let key = voice + "|" + text
        if let d = cueAudio[key] { playCue(d); return }
        let v = voice
        Task {
            if let server, let d = try? await server.speech(Self.forVoice(text), voice: v) {
                self.cueAudio[v + "|" + text] = d
                self.playCue(d)
            } else {
                let u = AVSpeechUtterance(string: Self.forVoice(text))
                u.rate = AVSpeechUtteranceDefaultSpeechRate * min(1.3, max(0.7, self.rate))
                self.cueUntil = Date().addingTimeInterval(2.0)
                self.synth.speak(u)
            }
        }
    }

    private func playCue(_ d: Data) {
        guard let p = try? AVAudioPlayer(data: d, fileTypeHint: AVFileType.mp3.rawValue) else { return }
        p.enableRate = true
        p.rate = rate
        cuePlayer = p
        p.play()
        // The clip's length, plus a little for the TV's own delay and the room's echo.
        cueUntil = Date().addingTimeInterval(p.duration / Double(max(0.5, rate)) + 0.4)
    }

    // MARK: -

    private func fetch(_ said: String) -> Task<Data?, Never>? {
        guard let server else { return nil }
        let v = voice
        // Try the Aura voice up to three times before the Apple TV's own voice steps in, so
        // one slow or failed request doesn't change Mibo's voice in the middle of a story.
        return Task {
            for attempt in 1...3 {
                do { return try await server.speech(said, voice: v) }
                catch {
                    if Task.isCancelled { return nil }
                    print("My Mibo TV: Aura voice failed (try \(attempt) of 3): \(error.localizedDescription)")
                    try? await Task.sleep(nanoseconds: 250_000_000)
                }
            }
            return nil
        }
    }

    private func playNext() {
        guard !queue.isEmpty else {
            playing = false
            if queueClosed { finished() }
            return
        }
        playing = true
        isSpeaking = true
        let c = queue.removeFirst()
        let gen = generation
        Task {
            let data = await c.audio?.value
            guard gen == self.generation else { return }
            self.line = c.shown
            self.wordsSaid = 0
            if let data, let p = try? AVAudioPlayer(data: data, fileTypeHint: AVFileType.mp3.rawValue) {
                p.delegate = self
                p.isMeteringEnabled = true
                p.enableRate = true
                p.rate = self.rate
                p.prepareToPlay()
                self.player = p
                p.play()
                self.startTicker(words: Self.words(c.shown).count)
            } else {
                // The server's voice failed three times (for example, the Workers AI allowance ran out).
                print("My Mibo TV: using the Apple TV voice for: \(c.shown.prefix(60))")
                let u = AVSpeechUtterance(string: c.said)
                u.rate = AVSpeechUtteranceDefaultSpeechRate * min(1.3, max(0.7, self.rate))
                self.synth.speak(u)
            }
        }
    }

    private func startTicker(words: Int) {
        ticker?.invalidate()
        ticker = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let p = self.player, p.duration > 0 else { return }
                let said = Int((p.currentTime / p.duration * Double(words)).rounded(.up))
                if said != self.wordsSaid { self.wordsSaid = min(words, said) }
            }
        }
    }

    private func clipEnded() {
        ticker?.invalidate(); ticker = nil
        player = nil
        wordsSaid = Self.words(line).count
        let gen = generation
        // A short breath between sentences (the same 200 ms Jim picked on the iPad).
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            guard gen == self.generation else { return }
            self.playNext()
        }
    }

    private func finished() {
        playing = false
        isSpeaking = false
        line = ""; wordsSaid = 0
        let done = onDone
        onDone = nil
        done?()
    }

    static func words(_ s: String) -> [String] { s.split(whereSeparator: { $0 == " " || $0 == "\n" }).map(String.init) }
}

extension Speaker: AVAudioPlayerDelegate, AVSpeechSynthesizerDelegate {
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in if player === self.player { self.clipEnded() } }
    }
    nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        Task { @MainActor in if player === self.player { self.clipEnded() } }
    }
    nonisolated func speechSynthesizer(_ s: AVSpeechSynthesizer, willSpeakRangeOfSpeechString r: NSRange, utterance: AVSpeechUtterance) {
        Task { @MainActor in
            let before = (utterance.speechString as NSString).substring(to: min(r.location + r.length, (utterance.speechString as NSString).length))
            self.wordsSaid = Speaker.words(before).count
        }
    }
    nonisolated func speechSynthesizer(_ s: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in if self.playing { self.clipEnded() } }
    }
}
