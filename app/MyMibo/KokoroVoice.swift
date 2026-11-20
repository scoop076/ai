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
    // If the app finds the marker when it starts, the engine took the app down last time: from then
    // on (for this model) Mibo sticks with Apple's voices instead of crashing again.

    private var folder: URL { modelFile.deletingLastPathComponent() }
    private var busyMarker: URL { folder.appendingPathComponent("busy-" + KokoroVoice.modelName) }
    private var offMarker: URL { folder.appendingPathComponent("off-" + KokoroVoice.modelName) }

    private func markBusy() { FileManager.default.createFile(atPath: busyMarker.path, contents: Data()) }
    private func markDone() { try? FileManager.default.removeItem(at: busyMarker) }

    /// True if the built-in voice should stay off because it crashed the app before.
    private func crashedBefore() -> Bool {
        let fm = FileManager.default
        if fm.fileExists(atPath: busyMarker.path) {
            print("My Mibo: the built-in voice stopped the app last time; using Apple's voices from now on.")
            fm.createFile(atPath: offMarker.path, contents: Data())
            markDone()
        }
        return fm.fileExists(atPath: offMarker.path)
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
            self.markBusy()
            defer { self.markDone() }
            do {
                for try await chunk in tts.synthesizeStream(text, options: SynthesisOptions(voiceId: voice)) {
                    guard self.generation == gen else { return }
                    if self.enqueue(chunk.samples, rate: chunk.sampleRateHz, id: id, gen: gen) { gotAudio = true }
                }
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
