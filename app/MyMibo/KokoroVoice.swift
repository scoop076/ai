// Mibo's built-in voice: the Kokoro model (Apache 2.0) running on this device
// through Google's MediaPipe, so Mibo sounds the same on every iPhone and iPad.
//
// The model (about 295 MB) downloads once, the first time the app opens, into
// Application Support (left out of iCloud backups). Until it's ready, or if
// anything goes wrong, the app keeps using Apple's voices, so Mibo always talks.
//
// If the MediaPipe package isn't in the project (or on the simulator), this
// compiles to a stub that's never "ready", and the app behaves as before.

import AVFoundation
import Foundation
#if canImport(MediaPipeTasksAudio)
import MediaPipeTasksAudio
#endif

final class KokoroVoice: NSObject, URLSessionDownloadDelegate {
    static let shared = KokoroVoice()

    // The CPU version of the model. The GPU version crashed inside MediaPipe on an iPhone
    // (a Metal shader assert), so Mibo runs the voice on the main processor instead.
    private static let modelName = "kokoro_int8_fp16.litertlm"
    private static let modelURL = URL(string: "https://huggingface.co/litert-community/Kokoro-82M/resolve/main/kokoro_int8_fp16.litertlm")!
    private static let oldModelNames = ["kokoro_int8_gpu_fp16.litertlm"]

    /// "off" (not available here), "downloading", "loading", "ready" or "failed".
    private(set) var status = "off"
    private(set) var progress: Double = 0
    /// Called on the main thread whenever status or progress changes.
    var onStatus: (() -> Void)?
    /// "sayStart" / "spoke" events for the page, on the main thread.
    var onEvent: (([String: Any]) -> Void)?

    var isReady: Bool { status == "ready" }
    var isSpeaking: Bool { !queue.isEmpty }
    /// Changes every time speech is stopped.
    var token: Int { generation }

    #if canImport(MediaPipeTasksAudio) && !targetEnvironment(simulator)
    private var tts: TextToSpeech?
    #endif

    // Playback: one player node fed 24 kHz mono float buffers, one per sentence.
    private let engine = AVAudioEngine()
    private let node = AVAudioPlayerNode()
    private let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 24000, channels: 1, interleaved: false)!
    private var queue: [String] = []           // sentence ids not yet finished, in speaking order
    private var scheduled = Set<String>()      // ids whose audio is already queued on the player
    private var chain: Task<Void, Never>?      // keeps synthesis in sentence order
    private var generation = 0                 // bumped by stop(), so late work is dropped
    private var session: URLSession?
    private var lastReported: Double = -1

    private override init() {
        super.init()
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: format)
    }

    private var modelFile: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Kokoro", isDirectory: true).appendingPathComponent(KokoroVoice.modelName)
    }

    // MARK: - Crash guard
    //
    // A problem inside the voice engine can stop the whole app, which no error handling can catch.
    // So a small marker file is written just before loading or speaking, and removed right after.
    // Finding the marker at launch counts as a strike. But stopping the app (including pressing
    // Run in Xcode) also leaves the marker, so one strike isn't enough: the built-in voice only
    // turns off after two strikes in a row with no successful sentence in between. Every new
    // build of the app starts fresh.

    private var folder: URL { modelFile.deletingLastPathComponent() }
    private var busyMarker: URL { folder.appendingPathComponent("busy-" + KokoroVoice.modelName) }
    private var strikesFile: URL { folder.appendingPathComponent("strikes-" + KokoroVoice.modelName) }

    private func markBusy() { FileManager.default.createFile(atPath: busyMarker.path, contents: Data()) }
    private func markDone() { try? FileManager.default.removeItem(at: busyMarker) }

    /// Changes with every build of the app (the app binary's date).
    private var buildStamp: String {
        guard let exe = Bundle.main.executableURL,
              let date = try? FileManager.default.attributesOfItem(atPath: exe.path)[.modificationDate] as? Date else { return "?" }
        return String(Int(date.timeIntervalSince1970))
    }

    private func readStrikes() -> Int {
        guard let text = try? String(contentsOf: strikesFile, encoding: .utf8) else { return 0 }
        let parts = text.split(separator: "|")
        guard parts.count == 2, String(parts[0]) == buildStamp else { return 0 }   // a new build starts fresh
        return Int(parts[1]) ?? 0
    }

    private func writeStrikes(_ n: Int) {
        try? (buildStamp + "|" + String(n)).write(to: strikesFile, atomically: true, encoding: .utf8)
    }

    /// True if the built-in voice should stay off because it seems to keep crashing the app.
    private func crashedBefore() -> Bool {
        var strikes = readStrikes()
        if FileManager.default.fileExists(atPath: busyMarker.path) {
            strikes += 1
            markDone()
            print("My Mibo: the app stopped while the built-in voice was busy (strike \(strikes) of 2).")
        }
        writeStrikes(strikes)
        if strikes >= 2 { print("My Mibo: the built-in voice stays off for this build; using Apple's voices.") }
        return strikes >= 2
    }

    /// A sentence was spoken fine: clear the strikes.
    private func spokeFine() {
        if readStrikes() != 0 { writeStrikes(0) }
    }

    // MARK: - Getting the model ready

    /// Load the model, downloading it first if needed. Safe to call any time.
    func start() {
        #if canImport(MediaPipeTasksAudio) && !targetEnvironment(simulator)
        guard status == "off" || status == "failed" else { return }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for old in KokoroVoice.oldModelNames {   // free the space the old model used
            try? FileManager.default.removeItem(at: folder.appendingPathComponent(old))
        }
        try? FileManager.default.removeItem(at: folder.appendingPathComponent("off-" + KokoroVoice.modelName))   // the old one-strike switch
        if crashedBefore() { setStatus("failed"); return }
        if FileManager.default.fileExists(atPath: modelFile.path) { load() } else { download() }
        #endif
    }

    private func setStatus(_ s: String) {
        status = s
        onStatus?()
    }

    private func download() {
        try? FileManager.default.createDirectory(at: modelFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        progress = 0
        lastReported = -1
        setStatus("downloading")
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForResource = 60 * 60
        let s = URLSession(configuration: config, delegate: self, delegateQueue: .main)
        session = s
        s.downloadTask(with: KokoroVoice.modelURL).resume()
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else { return }
        progress = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
        if progress - lastReported >= 0.02 { lastReported = progress; onStatus?() }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        // The temporary file disappears when this returns, so move it now.
        let code = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else { return }   // the error is reported in didCompleteWithError below
        let fm = FileManager.default
        try? fm.removeItem(at: modelFile)
        do {
            try fm.moveItem(at: location, to: modelFile)
            var url = modelFile
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try? url.setResourceValues(values)
        } catch {
            print("My Mibo: couldn't save the voice model: \(error)")
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        self.session?.finishTasksAndInvalidate()
        self.session = nil
        let code = (task.response as? HTTPURLResponse)?.statusCode ?? 0
        if error == nil, code == 200, FileManager.default.fileExists(atPath: modelFile.path) {
            load()
        } else {
            print("My Mibo: voice model download failed (status \(code)): \(String(describing: error))")
            setStatus("failed")   // tries again the next time the app opens
        }
    }

    private func load() {
        #if canImport(MediaPipeTasksAudio) && !targetEnvironment(simulator)
        setStatus("loading")
        let path = modelFile.path
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                self.markBusy()
                let options = TextToSpeechOptions(
                    baseOptions: TTSBaseOptions(modelAssetPath: path, delegate: .cpu),
                    defaultVoiceId: "af_heart",
                    speakingRate: 1.0
                )
                let engine = try createTextToSpeech(options: options)
                self.markDone()
                DispatchQueue.main.async {
                    self.tts = engine
                    self.setStatus("ready")
                }
            } catch {
                self.markDone()
                print("My Mibo: couldn't load the voice model: \(error)")
                // A damaged file would fail every time, so remove it; it downloads again next launch.
                try? FileManager.default.removeItem(atPath: path)
                DispatchQueue.main.async { self.setStatus("failed") }
            }
        }
        #endif
    }

    // MARK: - Speaking

    /// Speak one sentence. Sentences play in the order they arrive. Each sentence is streamed:
    /// its first phrase starts playing while the rest is still being made, so Mibo starts
    /// talking sooner. The page hears "sayStart" when a sentence begins and "spoke" when it ends.
    func speak(id: String, text: String, voice: String, token: Int) {
        guard token == generation else { return }   // stopped while the audio was waking up
        #if canImport(MediaPipeTasksAudio) && !targetEnvironment(simulator)
        guard let tts else { onEvent?(["type": "spoke", "id": id]); return }
        queue.append(id)
        let gen = generation
        let previous = chain
        chain = Task { @MainActor [weak self] in
            await previous?.value                     // make sentences in order
            guard let self, self.generation == gen else { return }
            var gotAudio = false
            var seconds = 0.0, firstSound = 0.0
            let began = Date()
            self.markBusy()
            defer { self.markDone() }
            do {
                for try await chunk in tts.synthesizeStream(text, options: SynthesisOptions(voiceId: voice)) {
                    guard self.generation == gen else { return }
                    let samples = KokoroVoice.trimSilence(chunk.samples)
                    if firstSound == 0 { firstSound = Date().timeIntervalSince(began) }
                    seconds += Double(samples.count) / 24000
                    if self.enqueue(samples, rate: chunk.sampleRateHz, id: id, gen: gen) { gotAudio = true }
                }
                // How fast the voice is working: making speech slower than it plays causes gaps.
                let took = Date().timeIntervalSince(began)
                if gotAudio { self.spokeFine() }
                print(String(format: "My Mibo voice: %.1f s of speech made in %.1f s (first sound after %.1f s) — %@",
                             seconds, took, firstSound, took > seconds ? "TOO SLOW, gaps likely" : "keeping up"))
            } catch {
                guard self.generation == gen else { return }
                print("My Mibo: couldn't speak a sentence: \(error)")
            }
            guard self.generation == gen else { return }
            self.streamEnded(id, gotAudio: gotAudio)
        }
        #else
        onEvent?(["type": "spoke", "id": id])
        #endif
    }

    private var pending: [String: Int] = [:]   // buffers of each sentence still to play
    private var ended = Set<String>()           // sentences whose audio is all made
    private var started = Set<String>()         // sentences the page was told have started

    /// Kokoro pads each clip with silence at both ends, which adds up to long pauses between
    /// sentences. Cut it down to a short, natural-sounding pause: a little before, a bit more after.
    static func trimSilence(_ samples: [Float]) -> [Float] {
        let quiet: Float = 0.01                 // about -40 dB
        guard let first = samples.firstIndex(where: { abs($0) > quiet }),
              let last = samples.lastIndex(where: { abs($0) > quiet }) else { return [] }
        let start = max(0, first - 24000 * 40 / 1000)                // keep 40 ms before
        let end = min(samples.count, last + 1 + 24000 * 140 / 1000) // keep 140 ms after
        return Array(samples[start..<end])
    }

    /// Queue one phrase of audio. Returns false if it couldn't be played.
    private func enqueue(_ samples: [Float], rate: Int, id: String, gen: Int) -> Bool {
        guard !samples.isEmpty, rate == 0 || rate == 24000,
              let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)),
              let ch = buf.floatChannelData?[0] else { return false }
        buf.frameLength = AVAudioFrameCount(samples.count)
        for i in 0..<samples.count {
            let s = samples[i]
            ch[i] = s.isFinite ? max(-1, min(1, s)) : 0
        }
        if !engine.isRunning {
            do { try engine.start() } catch { print("My Mibo: voice playback failed: \(error)"); return false }
        }
        if !node.isPlaying { node.play() }
        pending[id, default: 0] += 1
        scheduled.insert(id)
        announceStartIfFirst()
        node.scheduleBuffer(buf, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            DispatchQueue.main.async {
                guard let self, self.generation == gen else { return }
                self.pending[id, default: 1] -= 1
                self.finishIfDone(id)
            }
        }
        return true
    }

    private func streamEnded(_ id: String, gotAudio: Bool) {
        ended.insert(id)
        if gotAudio { finishIfDone(id) } else { finished(id) }   // nothing to play: skip it rather than stall
    }

    private func finishIfDone(_ id: String) {
        if ended.contains(id), (pending[id] ?? 0) <= 0 { finished(id) }
    }

    /// Tell the page the sentence at the front has started, once its audio is playing.
    private func announceStartIfFirst() {
        guard let first = queue.first, scheduled.contains(first), !started.contains(first) else { return }
        started.insert(first)
        onEvent?(["type": "sayStart", "id": first])
    }

    private func finished(_ id: String) {
        guard let i = queue.firstIndex(of: id) else { return }
        queue.remove(at: i)
        scheduled.remove(id); pending[id] = nil; ended.remove(id); started.remove(id)
        onEvent?(["type": "spoke", "id": id])
        announceStartIfFirst()
    }

    /// Stop talking right away and drop anything still waiting.
    func stop() {
        generation += 1
        chain?.cancel()
        chain = nil
        #if canImport(MediaPipeTasksAudio) && !targetEnvironment(simulator)
        tts?.cancel()
        #endif
        node.stop()
        let dropped = queue
        queue.removeAll()
        scheduled.removeAll(); pending.removeAll(); ended.removeAll(); started.removeAll()
        for id in dropped { onEvent?(["type": "spoke", "id": id]) }
    }
}
