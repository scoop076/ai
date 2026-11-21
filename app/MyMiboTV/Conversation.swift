import Foundation

/// Mibo's brain on the Apple TV: hears you through the Mibo Voice speaker,
/// turns that into words on the server, asks Claude, and speaks the answer.
@MainActor
final class Conversation: ObservableObject {
    enum State { case idle, listening, thinking, speaking }

    @Published private(set) var state: State = .idle
    @Published private(set) var youText = ""
    /// How loud Jim is right now (0...1), for the face's listening rings.
    @Published private(set) var micLevel = 0.0
    /// True once Mibo has noticed Jim talking in this turn.
    @Published private(set) var hearingYou = false
    @Published private(set) var note = ""            // short status line, e.g. "Mibo Voice connected"
    @Published private(set) var speakerConnected = false
    @Published private(set) var accessory: String?   // the current personality's accessory
    @Published var needsSetup = false
    /// Mibo's own screensaver: after a while with nothing going on the screen fades
    /// almost to black. "Hey Mibo" or a click on the remote wakes it.
    @Published private(set) var dozing = false
    private var lastActive = Date()
    private let dozeAfter: TimeInterval = 10 * 60
    private var dozeTimer: Timer?

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
    @Published private var sessionUntil: Date?
    private let sessionLength: TimeInterval = 5 * 60
    private var inSession: Bool { (sessionUntil ?? .distantPast) > Date() }
    /// Quiet mode: show the "Say Hey Mibo" hint on the TV.
    var showWakeHint: Bool { state == .idle && sessionUntil == nil && speakerConnected && !needsSetup }
    private var turn = 0
    private var replyTask: Task<Void, Never>?

    // Talking over Mibo. While Mibo answers in a conversation, the speaker's mic stays
    // open; a firm voice, well above Mibo's own voice coming from the TV, cuts Mibo off
    // and becomes Jim's next turn. Room noise and quiet chatter don't.
    private var bargeMic = false            // the mic is open while Mibo talks
    private var bargeMicPending = false     // we asked the speaker to open it
    private var barge = BargeDetector(echo: 0)
    private var preroll = Data()            // the last moment of audio, so Jim's first words aren't lost
    private var wasInterrupted = false
    private var roomFloor = 500.0
    private var ignoreAudioUntil = Date.distantPast
    /// How loud Mibo's own voice (from the TV) is at the speaker; learned as Mibo talks.
    private var miboEcho: Double {
        get { let v = UserDefaults.standard.double(forKey: "miboEcho"); return v > 0 ? v : 6000 }
        set { UserDefaults.standard.set(newValue, forKey: "miboEcho") }
    }
    private var noteClear: DispatchWorkItem?

    init() {
        speaker.onDone = nil
        apply(settings)
        dozeTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkDoze() }
        }
    }

    /// Something happened: stay awake (and wake up if dozing).
    func touch() {
        lastActive = Date()
        if dozing { dozing = false }
    }

    private func checkDoze() {
        if state != .idle || sessionUntil != nil || speaker.isSpeaking { lastActive = Date(); return }
        if !dozing && Date().timeIntervalSince(lastActive) > dozeAfter { dozing = true }
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
            bargeMic = false; bargeMicPending = false
            if state == .listening { state = .idle }
            show("Looking for the Mibo Voice speaker\u{2026}", for: 0)
        case .start:
            if bargeMicPending && state == .speaking { openBargeMic() } else { startListening() }
        case .stop:
            // "Hey Mibo" or "stop" while Mibo was thinking or talking: Mibo stops and
            // stays stopped, listening (inside a conversation). While listening it just cancels.
            let interrupted = state == .speaking || state == .thinking
            cancelTurn()
            if interrupted { keepListening() }
        case .audio(let d):
            heard(d)
        }
    }

    private func startListening() {
        touch()
        if state == .speaking || state == .thinking { cancelTurn(endRun: false) }
        guard let link else { return }
        guard server != nil else {
            link.acceptStart(false)
            needsSetup = true
            return
        }
        turn += 1
        bargeMicPending = false; bargeMic = false
        isFollowUp = expectingFollowUp
        expectingFollowUp = false
        if !isFollowUp { sessionUntil = Date().addingTimeInterval(sessionLength) }   // "Hey Mibo" opens a conversation
        vad = VoiceDetector(waitForSpeech: 20)   // seconds to start talking, after "Hey Mibo" or a reply
        recording = Data()
        youText = ""
        hearingYou = false
        micLevel = 0
        link.acceptStart()
        link.event(.runStart)
        link.event(.sttStart)
        state = .listening
    }

    private func heard(_ pcm: Data) {
        if bargeMic && state == .speaking { hearOverMibo(pcm); return }
        guard state == .listening else { return }
        if Date() < ignoreAudioUntil { return }   // the tail of Mibo's voice, still coming out of the TV
        recording.append(pcm)
        let level = min(1, vad.lastLevel / 6000)
        micLevel = micLevel * 0.5 + level * 0.5
        switch vad.feed(pcm) {
        case .waiting: break
        case .speechStarted:
            roomFloor = max(150, vad.background)
            hearingYou = true
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
        micLevel = 0
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
            if Self.isSleepCommand(text) {
                youText = text
                sessionUntil = nil
                endRun(); state = .idle
                show("Going quiet. Say \u{201C}Hey Mibo\u{201D} when you need me.", for: 4)
                return
            }
            youText = text
            sessionUntil = Date().addingTimeInterval(sessionLength)
            link.event(.intentStart)
            let interruptedNow = wasInterrupted
            wasInterrupted = false

            var pending = "", full = "", started = false
            speaker.begin()
            speaker.onDone = { [weak self] in self?.doneSpeaking(turn: my) }
            for try await ev in server.chat(text: text, system: Self.rules(screen: settings.screenName, justWoken: !isFollowUp, interrupted: interruptedNow), model: "claude-haiku-5-5", device: settings.screenName) {
                guard my == turn else { return }
                switch ev {
                case .persona(let p): setPersona(p)
                case .text(let t):
                    pending += t; full += t
                    // Wait until we know it isn't the "[quiet]" signal before speaking.
                    if Self.mayBeQuietSignal(full) { continue }
                    while case let (chunk, rest)? = Self.nextChunk(pending, first: !started) {
                        pending = rest
                        if !started {
                            started = true
                            link.event(.intentEnd)
                            link.event(.ttsStart, [("text", String(full.prefix(400)))])
                            state = .speaking
                            requestBargeMic()
                        }
                        speaker.add(chunk)
                    }
                }
            }
            guard my == turn else { return }
            if Self.isQuietSignal(full) {
                // Mibo decided this wasn't meant for it: say nothing and keep listening.
                print("My Mibo TV: not for me: \(text)")
                youText = ""
                speaker.stop()
                endRun(); state = .idle; keepListening()
                return
            }
            if !pending.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                if !started {
                    started = true
                    link.event(.intentEnd)
                    link.event(.ttsStart, [("text", String(full.prefix(400)))])
                    state = .speaking
                    requestBargeMic()
                }
                speaker.add(pending)
            }
            if !started { endRun(); state = .idle; keepListening(); return }
            speaker.finishQueue()
        } catch {
            guard my == turn, !(error is CancellationError) else { return }
            speaker.stop()
            sessionUntil = nil
            link.event(.error, [("code", "mibo-error"), ("message", String(error.localizedDescription.prefix(120)))])
            endRun()
            state = .idle
            show(error.localizedDescription, for: 8)
        }
    }

    private func doneSpeaking(turn my: Int) {
        guard my == turn, state == .speaking else { return }
        if let v = barge.miboLevel() { miboEcho = miboEcho * 0.6 + v * 0.4 }
        if bargeMic {
            // The mic is already open, so Jim's turn starts now, with no gap or cue.
            bargeMic = false
            turn += 1
            isFollowUp = true
            expectingFollowUp = false
            vad = VoiceDetector(waitForSpeech: 20)
            recording = Data(); preroll = Data()
            hearingYou = false; micLevel = 0
            ignoreAudioUntil = Date().addingTimeInterval(0.3)
            state = .listening
            return
        }
        if bargeMicPending { state = .idle; return }   // the mic is on its way; it becomes Jim's turn
        endRun()
        state = .idle
        keepListening()
    }

    // MARK: Talking over Mibo

    /// Mibo just started answering: open the speaker's mic so Jim can talk over it.
    private func requestBargeMic() {
        guard inSession, link != nil, !bargeMic, !bargeMicPending else { return }
        endRun()                      // frees the speaker for a new run; the reply keeps playing on the TV
        bargeMicPending = true
        expectingFollowUp = true
        barge = BargeDetector(echo: miboEcho)
        let my = turn
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            guard let self, my == self.turn, self.bargeMicPending else { return }
            if self.link?.listenAgain() != true { self.bargeMicPending = false }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            guard let self, self.bargeMicPending else { return }
            self.bargeMicPending = false
            if self.state == .idle { self.keepListening() }
        }
    }

    private func openBargeMic() {
        bargeMicPending = false
        guard let link else { return }
        bargeMic = true
        preroll = Data()
        link.acceptStart()
        link.event(.runStart)
        link.event(.sttStart)
    }

    private func hearOverMibo(_ pcm: Data) {
        preroll.append(pcm)
        let keep = 16000 * 2 * 4 / 10           // 0.4 s
        if preroll.count > keep { preroll.removeFirst(preroll.count - keep) }
        if barge.feed(pcm, miboAudible: speaker.isSpeaking) { talkedOver() }
    }

    /// Jim talked over Mibo: stop mid-word and make what he's saying his next turn.
    private func talkedOver() {
        print("My Mibo TV: you talked over Mibo (you \(Int(barge.lastLevel)), Mibo's voice \(Int(barge.miboNow)), needed \(Int(barge.needed)))")
        turn += 1
        replyTask?.cancel(); replyTask = nil
        speaker.onDone = nil
        speaker.stop()
        bargeMic = false
        wasInterrupted = true
        isFollowUp = true
        expectingFollowUp = false
        sessionUntil = Date().addingTimeInterval(sessionLength)
        vad = VoiceDetector(waitForSpeech: 20, talkingAt: barge.lastLevel, floor: roomFloor)
        recording = preroll; preroll = Data()
        youText = ""
        hearingYou = true
        micLevel = 0
        link?.event(.vadStart)
        state = .listening
    }

    private func endRun() { link?.event(.runEnd) }

    /// My Mibo left the screen (Home button, another app) or came back. Let go of
    /// the speaker while we're away, so "Hey Mibo" knows the app isn't open and
    /// asks Home Assistant to open it again. Reconnect when we're back.
    func onScreen(_ on: Bool) {
        if on {
            link?.start()
        } else {
            cancelTurn()
            sessionUntil = nil
            link?.stop()
        }
    }

    /// Stop whatever Mibo is doing (the remote's button, or the speaker said stop).
    private func cancelTurn(endRun end: Bool = true) {
        turn += 1
        replyTask?.cancel(); replyTask = nil
        speaker.stop()
        if end && (state != .idle || bargeMic) { endRun() }
        bargeMic = false; bargeMicPending = false
        expectingFollowUp = false
        state = .idle
    }

    // MARK: The remote

    /// Click on the remote: talk, or stop Mibo talking.
    func remoteTap() {
        if dozing { touch(); return }   // first click just wakes the screen
        touch()
        switch state {
        case .idle:
            guard speakerConnected else { show("The Mibo Voice speaker isn't connected yet.", for: 4); return }
            _ = link?.listenAgain()
        case .speaking, .thinking:
            sessionUntil = nil
            cancelTurn()
        case .listening:
            break
        }
    }

    func remoteStop() {
        touch()
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
        guard !t.isEmpty else { return false }
        let words = t.split(separator: " ").count
        if words <= 10, t.range(of: "\\b(go (silent|quiet|to sleep)|be quiet|be silent|shut up|stop talking|stop listening|quiet mode|hush|shush|stop interrupting|stop interjecting|don'?t interrupt|don'?t interject|stay out of (it|this)|leave us alone|not talking to you|i'?m not talking to you|we'?re not talking to you|quiet down|zip it|pipe down)\\b", options: .regularExpression) != nil {
            return true
        }
        // Very short ones: "Mibo, quiet." "Stop." "Enough."
        return words <= 3 && t.range(of: "\\b(quiet|stop|enough|silence|nevermind|never mind)\\b", options: .regularExpression) != nil
    }

    /// Claude answers "[quiet]" when what it heard wasn't meant for Mibo.
    static func isQuietSignal(_ s: String) -> Bool {
        s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().hasPrefix("[quiet")
    }
    static func mayBeQuietSignal(_ s: String) -> Bool {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return t.isEmpty || (t.count < 7 && "[quiet]".hasPrefix(t)) || t.hasPrefix("[quiet")
    }

    /// Did Jim say Mibo's name? (Speech-to-text sometimes hears it as Meebo, Mebo, Mabel and so on.)
    static func mentionsName(_ text: String) -> Bool {
        let t = text.lowercased()
        return t.range(of: "\\b(mibo|meebo|mebo|miebo|mibbo|nibo|neebo|mybo|me bo|mi bo|mee bo|mabel|mable|maybel|mibel|mi-bo)\\b", options: .regularExpression) != nil
    }

    /// Whisper sometimes "hears" these in silence or TV noise.
    static func isNoise(_ text: String) -> Bool {
        let t = text.lowercased()
            .replacingOccurrences(of: "[^a-z' ]", with: " ", options: .regularExpression)
            .split(separator: " ").joined(separator: " ")
        return ["", "you", "thank you", "thanks for watching", "thank you for watching", "bye", "uh", "um", "hmm",
                "mibo", "collinsville", "mibo collinsville", "meebo", "hey mibo"].contains(t)
    }

    static func rules(screen: String, justWoken: Bool = false, interrupted: Bool = false) -> String {
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
            "You are listening in a room where Jim is often with other people. Only answer when you're being talked to: Jim says your name, asks you something, or is clearly continuing his conversation with you. If what you heard is people talking to each other, the TV, background noise, or anything not meant for you, reply with exactly [quiet] and nothing else. Never interject into other people's conversations. When unsure, reply [quiet].",
            "Never end a sentence with Jim's name; he has asked you many times to stop. Use his name only at the start of a sentence, or leave it out entirely.",
            "Apologize only when a real mistake truly calls for it, once and briefly, then move on. Once something is corrected, don't restate or re-correct it or remind Jim of past mistakes unless he asks or it affects what he's doing now.",
            "The current date and time is \(f.string(from: Date())).",
            "Jim is talking to you right now from the screen he calls \"\(screen)\", which is an Apple TV. He talks to you through the Mibo Voice speaker in the room, and you appear and speak on the TV. The frame can run on several of his screens around the house and on his phone. Use this naturally when it matters, for example if he asks where you are or which screen he's on, but don't announce it otherwise.",
        ].joined(separator: " ") + (justWoken
            ? " Jim just said \"Hey Mibo\", so this message is for you: answer it (never reply [quiet] to it)."
            : "") + (interrupted
            ? " Someone just talked over you while you were answering, so you stopped partway and only the beginning of your last reply was heard. If it was Jim talking to you, respond to what he said (keep it short). If it was someone else, or not meant for you, reply [quiet] and stay stopped; don't resume the old answer unless Jim asks."
            : "")
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
    private var voicePeak = 0.0       // how loud Jim's own voice is this turn
    private(set) var peak = 0.0
    private(set) var lastLevel = 0.0
    var background: Double { max(0, floor) }

    init(waitForSpeech: Double = 7) { self.waitForSpeech = waitForSpeech }

    /// Start already "talking" (Jim talked over Mibo), at this loudness.
    init(waitForSpeech: Double, talkingAt level: Double, floor: Double) {
        self.waitForSpeech = waitForSpeech
        self.floor = floor
        talking = true
        voicePeak = level
        peak = level
    }

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
        lastLevel = max(0, rms - max(0, floor))
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
        // Jim is the loud, close voice. Quieter talk in the room (other people, the TV)
        // shouldn't keep his turn open, so "quiet" is measured against his own loudness.
        voicePeak = max(voicePeak * 0.995, rms)
        let stillTalking = max(threshold * 0.6, voicePeak * 0.15)
        quietTime = rms > stillTalking ? 0 : quietTime + dt
        if quietTime > 0.8 || talkTime > 15 { return .speechEnded }   // a 0.8 s pause ends your turn
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

/// Decides when Jim talks over Mibo. Mibo's voice comes from the TV, so the speaker
/// hears it as loud room sound; Jim counts only when he's clearly louder than that
/// (and than a fixed minimum) for about a quarter second.
struct BargeDetector {
    /// How many times louder than Mibo's voice Jim has to be.
    static let ratio = 2.2
    /// Never interrupt for anything quieter than this (room noise is about 250-2,000;
    /// Jim's voice about 15,000-23,000).
    static let minimum = 6000.0
    static let needTime = 0.25

    private let echo: Double             // Mibo's voice level learned from earlier replies
    private var recent: [Double] = []    // levels over the last few seconds
    private var audible: [Double] = []   // levels while Mibo's audio was playing
    private var loud = 0.0
    private var logIn = 1.0
    private(set) var lastLevel = 0.0
    private(set) var miboNow = 0.0
    private(set) var needed = 0.0

    init(echo: Double) { self.echo = echo }

    mutating func feed(_ pcm: Data, miboAudible: Bool) -> Bool {
        let n = pcm.count / 2
        guard n > 0 else { return false }
        var sum = 0.0
        pcm.withUnsafeBytes { raw in
            for i in 0..<n {
                let v = Double(Int16(littleEndian: raw.loadUnaligned(fromByteOffset: i * 2, as: Int16.self)))
                sum += v * v
            }
        }
        let rms = (sum / Double(n)).squareRoot()
        let dt = Double(n) / 16000
        lastLevel = rms
        recent.append(rms)
        let window = Int(3.0 / dt)
        if recent.count > window { recent.removeFirst(recent.count - window) }
        if miboAudible {
            audible.append(rms)
            if audible.count > 6000 { audible.removeFirst(2000) }
        }
        // Mibo's voice right now: a loud-ish level from the last few seconds, leaving out
        // the last half second (which may already be Jim).
        let lag = Int(0.5 / dt)
        miboNow = recent.count > lag + 5 ? Self.percentile(Array(recent.dropLast(lag)), 0.8) : 0
        needed = max(Self.minimum, Self.ratio * max(echo, miboNow))
        loud = rms > needed ? loud + dt : max(0, loud - dt)
        logIn -= dt
        if logIn <= 0 {
            logIn = 1
            print("My Mibo TV: over Mibo: level \(Int(rms)), Mibo's voice \(Int(max(echo, miboNow))), needed \(Int(needed))")
        }
        return loud >= Self.needTime
    }

    /// Mibo's typical voice level at the speaker during this reply, if there was enough of it.
    func miboLevel() -> Double? {
        audible.count >= 30 ? Self.percentile(audible, 0.7) : nil
    }

    static func percentile(_ a: [Double], _ p: Double) -> Double {
        let s = a.sorted()
        return s[min(s.count - 1, max(0, Int(Double(s.count - 1) * p)))]
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
