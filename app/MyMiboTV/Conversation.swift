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
    private var barge = BargeDetector(miboPeak: 0, jimVoice: 0)
    private var jimRawLevels: [Double] = []   // Jim's voice this turn, on the raw channel
    private var lastCleanLevel = 8000.0
    private var preroll = Data()            // the last moment of audio, so Jim's first words aren't lost
    private var wasInterrupted = false
    private var interruptedReply = ""       // what Mibo was saying when it was cut off
    private var spokenSoFar = ""            // the reply Mibo is saying now
    private var roomFloor = 500.0
    private var ignoreAudioUntil = Date.distantPast

    // Live words (Deepgram Flux): Jim's speech is turned into words while he talks, and
    // Flux decides when he's finished, so Mibo can answer sooner. Whisper is the backup.
    private var flux: FluxStream?
    private var fluxLast = Date.distantPast       // when Flux last said anything
    private var fluxOffUntil = Date.distantPast   // after a failure, use Whisper for a while
    private var localEnded = false                // our own pause detector thinks Jim stopped
    /// An answer started early, when Flux thought Jim was probably done.
    private var early: EarlyReply?
    /// How loud Mibo's own voice (from the TV) is at the speaker; learned as Mibo talks.
    /// Learned on the speaker's raw channel (0 = not learned yet): how loud Mibo's voice gets
    /// at its loudest, and how loud Jim usually talks. Talk-over puts its bar between them.
    private var miboPeak: Double {
        get { UserDefaults.standard.double(forKey: "miboPeakRaw") }
        set { UserDefaults.standard.set(newValue, forKey: "miboPeakRaw") }
    }
    private var jimVoice: Double {
        get { UserDefaults.standard.double(forKey: "jimVoiceRaw") }
        set { UserDefaults.standard.set(newValue, forKey: "jimVoiceRaw") }
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
            // Inside a conversation Mibo keeps listening either way (before, "Hey Mibo" said
            // while Mibo was already listening cancelled the listen and nothing reopened it).
            cancelTurn()
            keepListening()
        case .audio(let d, let raw):
            heard(d, raw: raw)
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
        early?.cancel(); early = nil
        isFollowUp = expectingFollowUp
        expectingFollowUp = false
        if !isFollowUp { sessionUntil = Date().addingTimeInterval(sessionLength) }   // "Hey Mibo" opens a conversation
        vad = VoiceDetector(waitForSpeech: 20)   // seconds to start talking, after "Hey Mibo" or a reply
        recording = Data(); jimRawLevels = []
        youText = ""
        hearingYou = false
        micLevel = 0
        link.acceptStart()
        link.event(.runStart)
        link.event(.sttStart)
        state = .listening
        startFlux()
    }

    private func heard(_ pcm: Data, raw: Data? = nil) {
        if bargeMic && state == .speaking { hearOverMibo(pcm, raw: raw); return }
        guard state == .listening else { return }
        if Date() < ignoreAudioUntil { return }   // the tail of Mibo's voice, still coming out of the TV
        recording.append(pcm)
        flux?.send(pcm)
        if let raw, hearingYou { jimRawLevels.append(BargeDetector.rms(raw)) }
        let level = min(1, vad.lastLevel / 6000)
        micLevel = micLevel * 0.5 + level * 0.5
        switch vad.feed(pcm) {
        case .waiting: break
        case .speechStarted:
            roomFloor = max(150, vad.background)
            hearingYou = true
            link?.event(.vadStart)
        case .speechEnded:
            if flux != nil {
                // Flux decides when Jim is done; our own pause detector is only the backup.
                if !localEnded { localEnded = true; checkFluxAlive(turn: turn) }
                return
            }
            print("My Mibo TV: you finished talking (loudest \(Int(vad.peak)), background \(Int(vad.background)))")
            link?.event(.vadEnd); finishedTalking()
        case .nothingSaid:
            print("My Mibo TV: heard nothing (loudest \(Int(vad.peak)), background \(Int(vad.background)))")
            stopFlux()
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

    /// Jim finished his turn. `words` comes from Flux; without it, Whisper transcribes the recording.
    /// Learn how loud Jim talks (raw channel), from a turn where he spoke for a while.
    private func learnJimVoice() {
        defer { jimRawLevels = [] }
        guard jimRawLevels.count >= 20 else { return }
        let v = BargeDetector.percentile(jimRawLevels, 0.8)
        guard v > 0 else { return }
        jimVoice = jimVoice > 0 ? jimVoice * 0.7 + v * 0.3 : v
        print("My Mibo TV: learned your voice: \(Int(jimVoice))")
    }

    private func finishedTalking(words: String? = nil) {
        learnJimVoice()
        stopFlux()
        state = .thinking
        micLevel = 0
        let wav = VoiceDetector.wav(recording)
        recording = Data()
        let my = turn
        let head = early
        early = nil
        replyTask = Task { await self.reply(to: wav, words: words, early: head, turn: my) }
    }

    private func reply(to wav: Data, words: String?, early head: EarlyReply?, turn my: Int) async {
        guard let server, let link else { return }
        do {
            var text: String
            if let words { text = words } else { text = try await server.transcribe(wav) }
            if wasInterrupted { text = Self.dropOwnLead(text, interruptedReply) }
            guard my == turn else { head?.cancel(); return }
            // Use the early answer only if it was for exactly what Jim ended up saying.
            let useEarly = head.map { Self.sameWords($0.text, text) } ?? false
            if !useEarly { head?.cancel() }
            link.event(.sttEnd, [("text", text)])
            if text.isEmpty || Self.isNoise(text) {
                if useEarly { head?.cancel() }
                endRun(); state = .idle
                keepListening()
                return
            }
            if wasInterrupted && Self.isOwnWords(text, interruptedReply) {
                // The "interruption" was Mibo hearing itself through the TV: say nothing.
                print("My Mibo TV: that was my own voice: \(text)")
                if useEarly { head?.cancel() }
                wasInterrupted = false
                endRun(); state = .idle
                keepListening()
                return
            }
            if Self.isSleepCommand(text) {
                if useEarly { head?.cancel() }
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
            spokenSoFar = ""
            speaker.begin()
            speaker.onDone = { [weak self] in self?.doneSpeaking(turn: my) }
            let answer: AsyncThrowingStream<MiboServer.ChatEvent, Error>
            if useEarly, let head {
                print("My Mibo TV: using the early answer")
                Task { await server.commit(draft: head.draft) }
                answer = head.events()
            } else {
                answer = server.chat(text: text, system: Self.rules(screen: settings.screenName, justWoken: !isFollowUp, interrupted: interruptedNow), model: "claude-haiku-5-5", device: settings.screenName)
            }
            for try await ev in answer {
                guard my == turn else { return }
                switch ev {
                case .persona(let p): setPersona(p)
                case .text(let t):
                    pending += t; full += t
                    spokenSoFar = full
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
        if let v = barge.learnedMiboPeak() {
            miboPeak = miboPeak > 0 ? miboPeak * 0.5 + v * 0.5 : v
            print("My Mibo TV: learned Mibo's loudest: \(Int(miboPeak))")
        }
        if bargeMic {
            // The mic is already open, so Jim's turn starts now, with no gap or cue.
            bargeMic = false
            turn += 1
            isFollowUp = true
            expectingFollowUp = false
            vad = VoiceDetector(waitForSpeech: 20)
            recording = Data(); preroll = Data(); jimRawLevels = []
            hearingYou = false; micLevel = 0
            ignoreAudioUntil = Date().addingTimeInterval(0.3)
            state = .listening
            startFlux()
            return
        }
        if bargeMicPending { state = .idle; return }   // the mic is on its way; it becomes Jim's turn
        endRun()
        state = .idle
        keepListening()
    }

    // MARK: Live words (Flux)

    private func startFlux() {
        stopFlux()
        localEnded = false
        guard let server, Date() > fluxOffUntil else { return }
        let f = server.listen()
        let my = turn
        fluxLast = Date()
        f.onEvent = { [weak self] e in self?.fluxEvent(e, turn: my) }
        flux = f
    }

    private func stopFlux() {
        flux?.close()
        flux = nil
        localEnded = false
    }

    private func fluxEvent(_ e: FluxStream.Event, turn my: Int) {
        guard my == turn, state == .listening, flux != nil else { return }
        fluxLast = Date()
        switch e {
        case .update:
            break
        case .eager(let heard):
            let text = wasInterrupted ? Self.dropOwnLead(heard, interruptedReply) : heard
            // Jim has probably finished: start Mibo's answer now, but hold it.
            guard hearingYou, let server, !text.isEmpty, !Self.isNoise(text), !Self.isSleepCommand(text), !Self.isJustTheName(text),
                  !(wasInterrupted && Self.isOwnWords(text, interruptedReply)) else { return }
            if let early, Self.sameWords(early.text, text) { return }
            early?.cancel()
            print("My Mibo TV: probably done: \(text)")
            early = EarlyReply(text: text, stream: { draft in
                server.chat(text: text, system: Self.rules(screen: self.settings.screenName, justWoken: !self.isFollowUp, interrupted: self.wasInterrupted), model: "claude-haiku-5-5", device: self.settings.screenName, draft: draft)
            })
        case .resumed:
            early?.cancel(); early = nil
        case .endOfTurn(let text):
            // Only once Jim himself has spoken this turn (Flux also hears other people).
            guard hearingYou else { return }
            if Self.isJustTheName(text) {
                // Just "Hey Mibo" and a pause: Jim is about to ask something. Keep this turn
                // open (Flux hears the rest as its next turn) instead of ending it.
                print("My Mibo TV: just my name; still listening")
                early?.cancel(); early = nil
                vad = VoiceDetector(waitForSpeech: 20)
                recording = Data(); jimRawLevels = []
                hearingYou = false
                localEnded = false
                return
            }
            print("My Mibo TV: you finished talking (live words): \(text)")
            link?.event(.vadEnd)
            finishedTalking(words: text)
        case .failed(let why):
            print("My Mibo TV: live words failed (\(why)); using Whisper for a while")
            fluxOffUntil = Date().addingTimeInterval(10 * 60)
            stopFlux()
            early?.cancel(); early = nil
            if localEnded || vad.isDone { link?.event(.vadEnd); finishedTalking() }
        }
    }

    /// Our own pause detector thinks Jim stopped. Flux normally decides, but if it has
    /// gone quiet, fall back to Whisper so Mibo never just hangs.
    private func checkFluxAlive(turn my: Int) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self, my == self.turn, self.state == .listening, self.flux != nil else { return }
            if Date().timeIntervalSince(self.fluxLast) < 1.5 { self.checkFluxAlive(turn: my); return }
            print("My Mibo TV: live words went quiet; using Whisper")
            self.stopFlux()
            self.early?.cancel(); self.early = nil
            self.link?.event(.vadEnd)
            self.finishedTalking()
        }
    }

    /// After a talk-over, the start of what was heard is often the end of Mibo's own sentence
    /// (it's in the audio kept from before Mibo stopped). Drop a leading run of 3+ words that
    /// follows Mibo's reply word pair by word pair; Jim's own words won't.
    static func dropOwnLead(_ heard: String, _ reply: String) -> String {
        func norm(_ w: Substring) -> String {
            w.lowercased().replacingOccurrences(of: "[^a-z0-9']", with: "", options: .regularExpression)
        }
        let r = reply.split(whereSeparator: { $0 == " " || $0 == "\n" }).map(norm).filter { !$0.isEmpty }
        guard r.count >= 2 else { return heard }
        var pairs = Set<String>()
        for i in 0..<(r.count - 1) { pairs.insert(r[i] + " " + r[i + 1]) }
        let raw = heard.split(separator: " ")
        let h = raw.map(norm)
        var run = 0
        while run + 1 < h.count && pairs.contains(h[run] + " " + h[run + 1]) { run += 1 }
        guard run >= 2 else { return heard }            // 3+ words in Mibo's order
        let rest = raw.dropFirst(run + 1).joined(separator: " ")
        print("My Mibo TV: dropped my own words: \(raw.prefix(run + 1).joined(separator: " "))")
        return rest.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Are these words (nearly) all from what Mibo was saying?
    static func isOwnWords(_ heard: String, _ reply: String) -> Bool {
        func words(_ s: String) -> [String] {
            s.lowercased().replacingOccurrences(of: "[^a-z0-9' ]", with: " ", options: .regularExpression)
                .split(separator: " ").map(String.init)
        }
        let h = words(heard), r = Set(words(reply))
        guard !h.isEmpty, !r.isEmpty else { return false }
        return Double(h.filter { r.contains($0) }.count) / Double(h.count) >= 0.8
    }

    /// Only Mibo's name ("Hey Mibo", "Mibo?", "Hi Meebo"...), nothing else.
    static func isJustTheName(_ text: String) -> Bool {
        let t = text.lowercased().replacingOccurrences(of: "[^a-z ]", with: " ", options: .regularExpression)
            .split(separator: " ").filter { !["hey", "hi", "ok", "okay", "hello", "yo"].contains($0) }
        return !t.isEmpty && t.count <= 2 && mentionsName(t.joined(separator: " "))
    }

    static func sameWords(_ a: String, _ b: String) -> Bool {
        func norm(_ s: String) -> String {
            s.lowercased().replacingOccurrences(of: "[^a-z0-9' ]", with: " ", options: .regularExpression)
                .split(separator: " ").joined(separator: " ")
        }
        return norm(a) == norm(b)
    }

    // MARK: Talking over Mibo

    /// Mibo just started answering: open the speaker's mic so Jim can talk over it.
    private func requestBargeMic() {
        guard inSession, link != nil, !bargeMic, !bargeMicPending else { return }
        endRun()                      // frees the speaker for a new run; the reply keeps playing on the TV
        bargeMicPending = true
        expectingFollowUp = true
        barge = BargeDetector(miboPeak: miboPeak, jimVoice: jimVoice)
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

    private func hearOverMibo(_ pcm: Data, raw: Data?) {
        preroll.append(pcm)
        let keep = 16000 * 2 * 3                // the last 3 s
        if preroll.count > keep { preroll.removeFirst(preroll.count - keep) }
        // Judge loudness on the raw channel: the cleaned-up one has automatic gain, which
        // turns Mibo's voice up when the room is quiet and Jim's down when he's loud.
        lastCleanLevel = BargeDetector.rms(pcm)
        if let raw, barge.feed(raw, miboAudible: speaker.isSpeaking) { talkedOver() }
    }

    /// Jim talked over Mibo: stop mid-word and make what he's saying his next turn.
    private func talkedOver() {
        interruptedReply = spokenSoFar
        print("My Mibo TV: you talked over Mibo (you \(Int(barge.lastLevel)), Mibo's loudest \(Int(barge.peakNow)), needed \(Int(barge.needed)))")
        turn += 1
        replyTask?.cancel(); replyTask = nil
        speaker.onDone = nil
        speaker.stop()
        bargeMic = false
        wasInterrupted = true
        isFollowUp = true
        expectingFollowUp = false
        sessionUntil = Date().addingTimeInterval(sessionLength)
        vad = VoiceDetector(waitForSpeech: 20, talkingAt: max(lastCleanLevel, 3000), floor: roomFloor)
        jimRawLevels = []
        // Keep Jim's words from when he started (plus a quarter second), not just the moment
        // Mibo noticed, so the whole question reaches the speech-to-text.
        let back = min(3.0, barge.secondsSinceJimStarted() + 0.25)
        let bytes = min(preroll.count, Int(back * 16000) * 2)
        recording = Data(preroll.suffix(bytes)); preroll = Data()
        print("My Mibo TV: kept \(String(format: "%.1f", back)) s from before Mibo stopped")
        startFlux()
        flux?.send(recording)
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
        stopFlux()
        early?.cancel(); early = nil
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
        return t.range(of: "\\b(miguel|mibo|meebo|mebo|miebo|mibbo|nibo|neebo|mybo|me bo|mi bo|mee bo|mabel|mable|maybel|mibel|mi-bo)\\b", options: .regularExpression) != nil
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
            "Speech-to-text often mishears your name Mibo as Miguel, Meebo, Mabel or Nibo; treat those as your name.",
            "In a conversation with you, a clear request or question (like \"tell me a story\" or \"what's a music box?\") is for you, even without your name; answer it.",
            "You are listening in a room where Jim is often with other people. Only answer when you're being talked to: Jim says your name, asks you something, or is clearly continuing his conversation with you. If what you heard is people talking to each other, the TV, background noise, or anything not meant for you, reply with exactly [quiet] and nothing else. Never interject into other people's conversations. When unsure, reply [quiet].",
            "Never end a sentence with Jim's name; he has asked you many times to stop. Use his name only at the start of a sentence, or leave it out entirely.",
            "Apologize only when a real mistake truly calls for it, once and briefly, then move on. Once something is corrected, don't restate or re-correct it or remind Jim of past mistakes unless he asks or it affects what he's doing now.",
            "The current date and time is \(f.string(from: Date())).",
            "Jim is talking to you right now from the screen he calls \"\(screen)\", which is an Apple TV. He talks to you through the Mibo Voice speaker in the room, and you appear and speak on the TV. The frame can run on several of his screens around the house and on his phone. Use this naturally when it matters, for example if he asks where you are or which screen he's on, but don't announce it otherwise.",
        ].joined(separator: " ") + (justWoken
            ? " Jim just said \"Hey Mibo\", so this message is for you: answer it (never reply [quiet] to it)."
            : "") + (interrupted
            ? " Jim just talked over you while you were answering, so you stopped partway and he heard only the beginning of your last reply. What he said reached you mixed with your own voice from the TV, so the words may include bits of your own reply or be garbled: ignore any of your own words, and work out what he asked (for example a question about something in your story). Answer it briefly. If you truly can't tell what he said, ask in a few words, like \"Sorry, what was that?\" Reply [quiet] only if it's clearly someone else talking to another person. Don't resume the old answer unless Jim asks."
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
    /// Jim talked and has now paused long enough to count as done.
    var isDone: Bool { talking && quietTime > 0.8 }

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

/// An answer started before Jim had certainly finished. It collects Claude's reply as it
/// streams, so if Jim did finish with those exact words, Mibo can start speaking at once.
/// The server only keeps it in memory once the app commits it.
@MainActor
final class EarlyReply {
    let text: String
    let draft = UUID().uuidString
    private var buffered: [MiboServer.ChatEvent] = []
    private var finished = false
    private var failure: Error?
    private var waiter: CheckedContinuation<Void, Never>?
    private var task: Task<Void, Never>?

    init(text: String, stream: (String) -> AsyncThrowingStream<MiboServer.ChatEvent, Error>) {
        self.text = text
        let s = stream(draft)
        task = Task { [weak self] in
            do {
                for try await e in s { self?.buffered.append(e); self?.wake() }
                self?.finished = true
            } catch {
                self?.failure = error
                self?.finished = true
            }
            self?.wake()
        }
    }

    func cancel() {
        task?.cancel(); task = nil
        failure = failure ?? CancellationError()
        finished = true
        wake()
    }

    /// Everything so far, then the rest as it arrives.
    func events() -> AsyncThrowingStream<MiboServer.ChatEvent, Error> {
        AsyncThrowingStream { cont in
            let reader = Task { @MainActor [weak self] in
                var i = 0
                while let self {
                    if i < self.buffered.count { cont.yield(self.buffered[i]); i += 1; continue }
                    if let f = self.failure { cont.finish(throwing: f); return }
                    if self.finished { cont.finish(); return }
                    await withCheckedContinuation { self.waiter = $0 }
                }
                cont.finish(throwing: CancellationError())
            }
            // If Mibo is cut off while using this answer, stop fetching the rest too.
            cont.onTermination = { [weak self] _ in
                reader.cancel()
                Task { @MainActor in self?.stopIfUnfinished() }
            }
        }
    }

    private func stopIfUnfinished() {
        if !finished { cancel() }
    }

    private func wake() {
        let w = waiter
        waiter = nil
        w?.resume()
    }
}

/// Decides when Jim talks over Mibo, on the speaker's raw channel (no automatic gain).
/// It calibrates itself: it learns how loud Mibo's voice gets at its loudest (from Mibo's
/// replies) and how loud Jim usually talks (from his turns), and puts the bar between
/// them. Until both are learned it only listens.
struct BargeDetector {
    static let needTime = 0.25       // above the bar this long in total...
    static let needWindow = 0.8      // ...within this long
    static let ignoreFirst = 0.6     // Mibo's voice starting up through the TV can spike
    /// The bar is at least this much above Mibo's loudest.
    static let overMibo = 1.3

    private let miboPeak: Double     // learned: Mibo's voice at its loudest (97th percentile)
    private let jimVoice: Double     // learned: Jim's usual talking level (80th percentile)
    private var recent: [Double] = []
    private var aboveRecent: [Bool] = []
    private var levelsBack: [Double] = []
    private var miboLevels: [Double] = []
    private var heardMibo = 0.0
    private var chunkTime = 0.032
    private var logIn = 1.0
    private var secondPeak = 0.0
    private(set) var lastLevel = 0.0
    private(set) var peakNow = 0.0
    private(set) var needed = 0.0

    var ready: Bool { miboPeak > 0 && jimVoice > 0 }

    init(miboPeak: Double, jimVoice: Double) {
        self.miboPeak = miboPeak
        self.jimVoice = jimVoice
    }

    mutating func feed(_ pcm: Data, miboAudible: Bool) -> Bool {
        let rms = Self.rms(pcm)
        let dt = Double(pcm.count / 2) / 16000
        guard dt > 0 else { return false }
        chunkTime = dt
        lastLevel = rms
        if miboAudible { heardMibo += dt }
        let window = Int(3.0 / dt)
        recent.append(rms)
        if recent.count > window { recent.removeFirst(recent.count - window) }
        // Mibo's loudest over the last few seconds (leaving out the last half second), in
        // case the TV got louder; it can raise the learned level by at most half.
        let lag = Int(0.5 / dt)
        let windowPeak = recent.count > lag + 10 ? Self.percentile(Array(recent.dropLast(lag)), 0.97) : 0
        if ready {
            peakNow = max(miboPeak, min(windowPeak, miboPeak * 1.5))
            needed = max(peakNow * Self.overMibo, (peakNow * jimVoice).squareRoot())
        } else {
            peakNow = windowPeak
            needed = 0
        }
        let above = needed > 0 && rms > needed && heardMibo >= Self.ignoreFirst
        aboveRecent.append(above)
        let w = max(1, Int(Self.needWindow / dt))
        if aboveRecent.count > w { aboveRecent.removeFirst(aboveRecent.count - w) }
        levelsBack.append(rms)
        if levelsBack.count > window { levelsBack.removeFirst(levelsBack.count - window) }
        if miboAudible && !above {
            miboLevels.append(rms)          // learn Mibo's level from Mibo, not from Jim
            if miboLevels.count > 9000 { miboLevels.removeFirst(3000) }
        }
        secondPeak = max(secondPeak, rms)
        logIn -= dt
        if logIn <= 0 {
            logIn = 1
            if ready {
                print("My Mibo TV: over Mibo: loudest \(Int(secondPeak)), Mibo's loudest \(Int(peakNow)), your voice \(Int(jimVoice)), needed \(Int(needed))")
            } else {
                print("My Mibo TV: over Mibo (still learning, can't interrupt yet): loudest \(Int(secondPeak)), Mibo so far \(Int(peakNow)), your voice \(jimVoice > 0 ? String(Int(jimVoice)) : "not learned")")
            }
            secondPeak = 0
        }
        return Double(aboveRecent.filter { $0 }.count) * dt >= Self.needTime
    }

    /// Mibo's loudest during this reply, if Mibo talked long enough to tell.
    func learnedMiboPeak() -> Double? {
        miboLevels.count >= 60 ? Self.percentile(miboLevels, 0.97) : nil
    }

    /// How many seconds ago Jim started talking: walk back while his voice keeps showing
    /// up, allowing pauses of up to 0.8 s between words.
    func secondsSinceJimStarted() -> Double {
        let onset = max(needed * 0.75, peakNow * 1.1)
        let maxGap = Int(0.8 / chunkTime)
        var start = levelsBack.count - 1
        var gap = 0
        var i = levelsBack.count - 1
        while i >= 0 {
            if levelsBack[i] > onset { start = i; gap = 0 } else { gap += 1; if gap > maxGap { break } }
            i -= 1
        }
        return Double(levelsBack.count - start) * chunkTime
    }

    static func rms(_ pcm: Data) -> Double {
        let n = pcm.count / 2
        guard n > 0 else { return 0 }
        var sum = 0.0
        pcm.withUnsafeBytes { raw in
            for i in 0..<n {
                let v = Double(Int16(littleEndian: raw.loadUnaligned(fromByteOffset: i * 2, as: Int16.self)))
                sum += v * v
            }
        }
        return (sum / Double(n)).squareRoot()
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
