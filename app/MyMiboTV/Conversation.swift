import Foundation

/// Mibo's brain on the Apple TV: hears you through the Mibo Voice speaker,
/// turns that into words on the server, asks Claude, and speaks the answer.
@MainActor
final class Conversation: ObservableObject {
    enum State { case idle, listening, thinking, speaking }

    @Published private(set) var state: State = .idle
    @Published private(set) var youText = ""
    @Published private(set) var note = ""            // short status line, e.g. "Mibo Voice connected"
    @Published private(set) var speakerConnected = false
    @Published private(set) var accessory: String?   // the current personality's accessory
    @Published var needsSetup = false

    let speaker = Speaker()
    private var link: ESPHomeLink?
    private var server: MiboServer?
    private var settings = TVSettings.load()

    private var persona = "claude"
    private var personaVoices: [String: String] = [:]
    private var personaLooks: [String: String] = [:]
    private var defaultVoice = "luna"

    // One turn of listening.
    private var vad = VoiceDetector()
    private var recording = Data()
    private var isFollowUp = false
    private var expectingFollowUp = false
    /// A conversation stays open (Mibo keeps listening) until Jim says "go quiet",
    /// or until nobody has talked for this long.
    private var sessionUntil: Date?
    private let sessionLength: TimeInterval = 5 * 60
    private var inSession: Bool { (sessionUntil ?? .distantPast) > Date() }
    private var turn = 0
    private var replyTask: Task<Void, Never>?
    private var noteClear: DispatchWorkItem?

    init() {
        speaker.onDone = nil
        apply(settings)
    }

    func apply(_ s: TVSettings) {
        let hostChanged = s.voiceHost != settings.voiceHost
        settings = s
        s.save()
        needsSetup = s.clientID.isEmpty || s.clientSecret.isEmpty
        server = needsSetup ? nil : MiboServer(clientID: s.clientID, clientSecret: s.clientSecret)
        speaker.server = server
        if let link { if hostChanged { link.change(host: s.voiceHost) } } else {
            let l = ESPHomeLink(host: s.voiceHost)
            l.onEvent = { [weak self] e in MainActor.assumeIsolated { self?.linkEvent(e) } }
            link = l
            l.start()
        }
        Task { await loadPrefs() }
    }

    var currentSettings: TVSettings { settings }

    // MARK: Prefs and personalities (shared with the other screens)

    func loadPrefs() async {
        guard let server else { return }
        do {
            if let list = try await server.getJSON("api/personas") as? [[String: Any]] {
                for p in list {
                    guard let id = p["id"] as? String else { continue }
                    if let a = p["aura"] as? String { personaVoices[id] = a }
                    if let look = p["look"] as? [String: Any], let acc = look["acc"] as? String { personaLooks[id] = acc }
                }
            }
            if let prefs = try await server.getJSON("api/prefs") as? [String: Any] {
                if let v = prefs["auraVoice"] as? String { defaultVoice = v }
                if let r = prefs["rate"] as? Double { speaker.rate = Float(min(1.4, max(0.6, r / 1.2))) }
                setPersona((prefs["persona"] as? String) ?? "claude")
            }
        } catch {
            show(error.localizedDescription, for: 8)
        }
    }

    private func setPersona(_ id: String) {
        persona = id
        speaker.voice = id == "claude" ? defaultVoice : (personaVoices[id] ?? defaultVoice)
        accessory = id == "claude" ? nil : personaLooks[id]
    }

    // MARK: The speaker (Voice PE)

    private func linkEvent(_ e: ESPHomeLink.Event) {
        switch e {
        case .connected(let name):
            speakerConnected = true
            show("Connected to \(name). Say \u{201C}Hey Mibo.\u{201D}", for: 5)
        case .disconnected:
            speakerConnected = false
            if state == .listening { state = .idle }
            show("Looking for the Mibo Voice speaker\u{2026}", for: 0)
        case .start:
            startListening()
        case .stop:
            // "Hey Mibo" or "stop" while Mibo was thinking or talking: stop, then listen
            // (so "Hey Mibo" interrupts). While listening it just cancels.
            let interrupted = state == .speaking || state == .thinking
            cancelTurn()
            if interrupted { DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { _ = self.link?.listenAgain() } }
        case .audio(let d):
            heard(d)
        }
    }

    private func startListening() {
        if state == .speaking || state == .thinking { cancelTurn(endRun: false) }
        guard let link else { return }
        guard server != nil else {
            link.acceptStart(false)
            needsSetup = true
            return
        }
        turn += 1
        isFollowUp = expectingFollowUp
        expectingFollowUp = false
        if !isFollowUp { sessionUntil = Date().addingTimeInterval(sessionLength) }   // "Hey Mibo" opens a conversation
        vad = VoiceDetector(waitForSpeech: 20)   // seconds to start talking, after "Hey Mibo" or a reply
        recording = Data()
        youText = ""
        link.acceptStart()
        link.event(.runStart)
        link.event(.sttStart)
        state = .listening
    }

    private func heard(_ pcm: Data) {
        guard state == .listening else { return }
        recording.append(pcm)
        switch vad.feed(pcm) {
        case .waiting: break
        case .speechStarted:
            sessionUntil = Date().addingTimeInterval(sessionLength)
            link?.event(.vadStart)
        case .speechEnded:
            print("My Mibo TV: you finished talking (loudest \(Int(vad.peak)), background \(Int(vad.background)))")
            link?.event(.vadEnd); finishedTalking()
        case .nothingSaid:
            print("My Mibo TV: heard nothing (loudest \(Int(vad.peak)), background \(Int(vad.background)))")
            endRun(); state = .idle
            keepListening()
        }
    }

    /// Still in a conversation: open the mic again so Jim doesn't need "Hey Mibo".
    private func keepListening() {
        guard inSession else { sessionUntil = nil; return }
        expectingFollowUp = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            guard self.state == .idle, self.inSession else { self.expectingFollowUp = false; return }
            if self.link?.listenAgain() != true { self.expectingFollowUp = false }
        }
    }

    // MARK: One turn

    private func finishedTalking() {
        state = .thinking
        let wav = VoiceDetector.wav(recording)
        recording = Data()
        let my = turn
        replyTask = Task { await self.reply(to: wav, turn: my) }
    }

    private func reply(to wav: Data, turn my: Int) async {
        guard let server, let link else { return }
        do {
            let text = try await server.transcribe(wav)
            guard my == turn else { return }
            link.event(.sttEnd, [("text", text)])
            if text.isEmpty || Self.isNoise(text) {
                endRun(); state = .idle
                keepListening()
                return
            }
            youText = text
            if Self.isSleepCommand(text) {
                sessionUntil = nil
                endRun(); state = .idle
                show("Going quiet. Say \u{201C}Hey Mibo\u{201D} when you need me.", for: 4)
                return
            }
            link.event(.intentStart)

            var pending = "", full = "", started = false
            speaker.begin()
            speaker.onDone = { [weak self] in self?.doneSpeaking(turn: my) }
            for try await ev in server.chat(text: text, system: Self.rules(screen: settings.screenName), model: "claude-haiku-5-5", device: settings.screenName) {
                guard my == turn else { return }
                switch ev {
                case .persona(let p): setPersona(p)
                case .text(let t):
                    pending += t; full += t
                    while case let (chunk, rest)? = Self.nextChunk(pending, first: !started) {
                        pending = rest
                        if !started {
                            started = true
                            link.event(.intentEnd)
                            link.event(.ttsStart, [("text", String(full.prefix(400)))])
                            state = .speaking
                        }
                        speaker.add(chunk)
                    }
                }
            }
            guard my == turn else { return }
            if !pending.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                if !started {
                    started = true
                    link.event(.intentEnd)
                    link.event(.ttsStart, [("text", String(full.prefix(400)))])
                    state = .speaking
                }
                speaker.add(pending)
            }
            if !started { endRun(); state = .idle; keepListening(); return }
            speaker.finishQueue()
        } catch {
            guard my == turn, !(error is CancellationError) else { return }
            speaker.stop()
            link.event(.error, [("code", "mibo-error"), ("message", String(error.localizedDescription.prefix(120)))])
            endRun()
            state = .idle
            show(error.localizedDescription, for: 8)
        }
    }

    private func doneSpeaking(turn my: Int) {
        guard my == turn, state == .speaking else { return }
        endRun()
        state = .idle
        keepListening()
    }

    private func endRun() { link?.event(.runEnd) }

    /// Stop whatever Mibo is doing (the remote's button, or the speaker said stop).
    private func cancelTurn(endRun end: Bool = true) {
        turn += 1
        replyTask?.cancel(); replyTask = nil
        speaker.stop()
        if end && state != .idle { endRun() }
        expectingFollowUp = false
        state = .idle
    }

    // MARK: The remote

    /// Click on the remote: talk, or stop Mibo talking.
    func remoteTap() {
        switch state {
        case .idle:
            guard speakerConnected else { show("The Mibo Voice speaker isn't connected yet.", for: 4); return }
            _ = link?.listenAgain()
        case .speaking, .thinking:
            cancelTurn()
        case .listening:
            break
        }
    }

    func remoteStop() {
        sessionUntil = nil
        if state != .idle { cancelTurn() }
    }

    // MARK: Helpers

    private func show(_ s: String, for seconds: Double) {
        note = s
        noteClear?.cancel()
        guard seconds > 0 else { return }
        let w = DispatchWorkItem { [weak self] in self?.note = "" }
        noteClear = w
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: w)
    }

    /// The next piece worth speaking: a full sentence, or (for the very first piece) up to a comma, so Mibo starts sooner.
    static func nextChunk(_ s: String, first: Bool) -> (String, String)? {
        let chars = Array(s)
        var i = 0
        while i < chars.count - 1 {
            let c = chars[i], next = chars[i + 1]
            if ".!?".contains(c) && (next == " " || next == "\n") && i >= 3 {
                return (String(chars[0...i]), String(chars[(i + 1)...]))
            }
            if first && c == "," && next == " " && i >= 24 {
                return (String(chars[0...i]), String(chars[(i + 1)...]))
            }
            if c == "\n" && i >= 3 {
                return (String(chars[0..<i]), String(chars[(i + 1)...]))
            }
            i += 1
        }
        return nil
    }

    static func isSleepCommand(_ text: String) -> Bool {
        let t = text.lowercased().replacingOccurrences(of: "[^a-z\\s']", with: " ", options: .regularExpression)
            .split(separator: " ").joined(separator: " ")
        guard !t.isEmpty, t.split(separator: " ").count <= 6 else { return false }
        return t.range(of: "\\b(go (silent|quiet|to sleep)|be quiet|stop listening|quiet mode|hush|shush)\\b", options: .regularExpression) != nil
    }

    /// Whisper sometimes "hears" these in silence or TV noise.
    static func isNoise(_ text: String) -> Bool {
        let t = text.lowercased().trimmingCharacters(in: .punctuationCharacters.union(.whitespaces))
        return ["", "you", "thank you", "thanks for watching", "bye", "uh", "um", "hmm", "mibo", "collinsville"].contains(t)
    }

    static func rules(screen: String) -> String {
        let f = DateFormatter()
        f.dateFormat = "EEEE, MMMM d, yyyy, h:mm a"
        return [
            "You are Mibo, the voice and face of a digital frame in Jim's home. Mibo is playful, warm and a little techy, and goes by they/them.",
            "Under the hood you are built on Claude, an AI model made by Anthropic. If Jim asks what you are or what you run on, say so plainly.",
            "Everything you write is spoken aloud by a text-to-speech voice, so talk like a warm, curious friend who knows a lot.",
            "Keep replies short: usually one to three sentences, unless Jim asks for more. Start with the answer itself, with no preamble.",
            "Never use lists, markdown, emoji, symbols, or web addresses. Write numbers and abbreviations the way you would say them.",
            "You can search the web for current or specific information.",
            "When it fits naturally, you may end with a short question to keep the conversation going.",
            "Never end a sentence with Jim's name; he has asked you many times to stop. Use his name only at the start of a sentence, or leave it out entirely.",
            "Apologize only when a real mistake truly calls for it, once and briefly, then move on. Once something is corrected, don't restate or re-correct it or remind Jim of past mistakes unless he asks or it affects what he's doing now.",
            "The current date and time is \(f.string(from: Date())).",
            "Jim is talking to you right now from the screen he calls \"\(screen)\", which is an Apple TV. He talks to you through the Mibo Voice speaker in the room, and you appear and speak on the TV. The frame can run on several of his screens around the house and on his phone. Use this naturally when it matters, for example if he asks where you are or which screen he's on, but don't announce it otherwise.",
        ].joined(separator: " ")
    }
}

/// Decides when you've started and stopped talking, from the speaker's microphone audio.
struct VoiceDetector {
    enum Result { case waiting, speechStarted, speechEnded, nothingSaid }

    private var waitForSpeech: Double
    private var floor: Double = -1
    private var talking = false
    private var loudRun = 0
    private var quietTime = 0.0
    private var heardTime = 0.0
    private var talkTime = 0.0
    private(set) var peak = 0.0
    var background: Double { max(0, floor) }

    init(waitForSpeech: Double = 7) { self.waitForSpeech = waitForSpeech }

    mutating func feed(_ pcm: Data) -> Result {
        let n = pcm.count / 2
        guard n > 0 else { return .waiting }
        var sum = 0.0
        pcm.withUnsafeBytes { raw in
            for i in 0..<n {
                let v = Double(Int16(littleEndian: raw.loadUnaligned(fromByteOffset: i * 2, as: Int16.self)))
                sum += v * v
            }
        }
        let rms = (sum / Double(n)).squareRoot()
        let dt = Double(n) / 16000
        heardTime += dt
        peak = max(peak, rms)
        if floor < 0 { floor = rms }
        let threshold = max(floor * 3, 250)

        if !talking {
            // Follow the room's background level while nobody is talking.
            floor = rms < floor ? floor * 0.7 + rms * 0.3 : floor * 0.98 + rms * 0.02
            loudRun = rms > threshold ? loudRun + 1 : 0
            if loudRun >= 3 { talking = true; quietTime = 0; return .speechStarted }
            return heardTime > waitForSpeech ? .nothingSaid : .waiting
        }
        talkTime += dt
        quietTime = rms > threshold * 0.5 ? 0 : quietTime + dt
        if quietTime > 1.5 || talkTime > 30 { return .speechEnded }   // a 1.5 s pause ends your turn
        return .waiting
    }

    /// 16 kHz mono 16-bit PCM wrapped as a WAV file.
    static func wav(_ pcm: Data) -> Data {
        var d = Data()
        func u32(_ v: UInt32) { var x = v.littleEndian; withUnsafeBytes(of: &x) { d.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { var x = v.littleEndian; withUnsafeBytes(of: &x) { d.append(contentsOf: $0) } }
        d.append(contentsOf: Array("RIFF".utf8)); u32(UInt32(36 + pcm.count))
        d.append(contentsOf: Array("WAVE".utf8))
        d.append(contentsOf: Array("fmt ".utf8)); u32(16); u16(1); u16(1); u32(16000); u32(32000); u16(2); u16(16)
        d.append(contentsOf: Array("data".utf8)); u32(UInt32(pcm.count))
        d.append(pcm)
        return d
    }
}

/// What the Apple TV remembers between launches (and rebuilds).
struct TVSettings: Codable {
    var clientID = ""
    var clientSecret = ""
    var voiceHost = "mibo-voice.local"
    var screenName = "Studio Apple TV"

    static func load() -> TVSettings {
        guard let d = UserDefaults.standard.data(forKey: "tvSettings"),
              let s = try? JSONDecoder().decode(TVSettings.self, from: d) else { return TVSettings() }
        return s
    }
    func save() {
        if let d = try? JSONEncoder().encode(self) { UserDefaults.standard.set(d, forKey: "tvSettings") }
    }
}
