import Foundation

/// The Mibo server at ai.liljimjim.com (the same Cloudflare Worker the iPad and
/// iPhone use). The Apple TV can't sign in through a browser, so it uses a
/// Cloudflare Access service token instead.
struct MiboServer {
    static let base = URL(string: "https://ai.liljimjim.com")!

    var clientID: String
    var clientSecret: String

    enum Failure: LocalizedError {
        case notSignedIn, status(Int, String)
        var errorDescription: String? {
            switch self {
            case .notSignedIn: return "Cloudflare Access didn't accept the Apple TV's service token. Check it in Settings."
            case .status(let c, let m): return m.isEmpty ? "The server answered with status \(c)." : m
            }
        }
    }

    enum ChatEvent { case text(String), persona(String) }

    private func request(_ path: String, method: String = "GET") -> URLRequest {
        var r = URLRequest(url: Self.base.appendingPathComponent(path))
        r.httpMethod = method
        r.timeoutInterval = 30
        r.setValue(clientID, forHTTPHeaderField: "CF-Access-Client-Id")
        r.setValue(clientSecret, forHTTPHeaderField: "CF-Access-Client-Secret")
        return r
    }

    private func check(_ resp: URLResponse, _ body: Data?) throws {
        guard let h = resp as? HTTPURLResponse else { return }
        let type = h.value(forHTTPHeaderField: "content-type") ?? ""
        // Access answers a bad token with its login page (HTML) or a 403.
        if h.statusCode == 403 || h.statusCode == 302 || type.contains("text/html") { throw Failure.notSignedIn }
        guard (200..<300).contains(h.statusCode) else {
            var msg = ""
            if let body, let j = try? JSONSerialization.jsonObject(with: body) as? [String: Any] {
                msg = (j["error"] as? String) ?? ""
            }
            if h.statusCode == 401 && msg.isEmpty { throw Failure.notSignedIn }
            throw Failure.status(h.statusCode, msg)
        }
    }

    func getJSON(_ path: String) async throws -> Any {
        let (d, r) = try await URLSession.shared.data(for: request(path))
        try check(r, d)
        return try JSONSerialization.jsonObject(with: d)
    }

    /// Speech to text (Whisper on the server). `wav` is 16 kHz mono 16-bit.
    func transcribe(_ wav: Data) async throws -> String {
        var r = request("api/transcribe", method: "POST")
        r.setValue("audio/wav", forHTTPHeaderField: "content-type")
        r.httpBody = wav
        let (d, resp) = try await URLSession.shared.data(for: r)
        try check(resp, d)
        let j = try JSONSerialization.jsonObject(with: d) as? [String: Any]
        return (j?["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Mibo's reply, streamed as it's written.
    /// Keep an early reply (see `chat(draft:)`).
    func commit(draft: String) async {
        var r = request("api/chat/commit", method: "POST")
        r.setValue("application/json", forHTTPHeaderField: "content-type")
        r.httpBody = try? JSONSerialization.data(withJSONObject: ["draft": draft])
        _ = try? await URLSession.shared.data(for: r)
    }

    /// A live connection that turns the mic into words as Jim talks.
    func listen() -> FluxStream {
        var c = URLComponents(url: Self.base.appendingPathComponent("api/listen"), resolvingAgainstBaseURL: false)!
        c.scheme = "wss"
        var r = URLRequest(url: c.url!)
        r.setValue(clientID, forHTTPHeaderField: "CF-Access-Client-Id")
        r.setValue(clientSecret, forHTTPHeaderField: "CF-Access-Client-Secret")
        return FluxStream(request: r)
    }

    /// Mibo's reply, streamed as it's written. With a draft id it's an early reply:
    /// the server only keeps it once `commit(draft:)` is called.
    func chat(text: String, system: String, model: String, device: String, draft: String? = nil) -> AsyncThrowingStream<ChatEvent, Error> {
        AsyncThrowingStream { cont in
            let task = Task {
                do {
                    var r = request("api/chat", method: "POST")
                    r.timeoutInterval = 90
                    r.setValue("application/json", forHTTPHeaderField: "content-type")
                    var body: [String: Any] = ["text": text, "system": system, "model": model, "device": device]
                    if let draft { body["draft"] = draft }
                    r.httpBody = try JSONSerialization.data(withJSONObject: body)
                    let (bytes, resp) = try await URLSession.shared.bytes(for: r)
                    if let h = resp as? HTTPURLResponse, !(200..<300).contains(h.statusCode) {
                        var body = Data()
                        for try await b in bytes { body.append(b); if body.count > 4000 { break } }
                        try check(resp, body)
                    }
                    try check(resp, nil)
                    for try await line in bytes.lines {
                        guard line.hasPrefix("data:"),
                              let j = try? JSONSerialization.jsonObject(with: Data(line.dropFirst(5).utf8)) as? [String: Any]
                        else { continue }
                        let type = j["type"] as? String
                        if type == "frame_persona", let p = j["persona"] as? String {
                            cont.yield(.persona(p))
                        } else if type == "content_block_delta",
                                  let d = j["delta"] as? [String: Any], d["type"] as? String == "text_delta",
                                  let t = d["text"] as? String {
                            cont.yield(.text(t))
                        } else if type == "error" {
                            let e = j["error"] as? [String: Any]
                            throw Failure.status(500, (e?["message"] as? String) ?? "Claude had a problem.")
                        }
                    }
                    cont.finish()
                } catch {
                    cont.finish(throwing: error)
                }
            }
            cont.onTermination = { _ in task.cancel() }
        }
    }

    /// Spoken audio (MP3) for one sentence, from Cloudflare's free Aura voices.
    func speech(_ text: String, voice: String) async throws -> Data {
        var r = request("api/tts-free", method: "POST")
        r.setValue("application/json", forHTTPHeaderField: "content-type")
        r.httpBody = try JSONSerialization.data(withJSONObject: ["text": text, "speaker": voice])
        let (d, resp) = try await URLSession.shared.data(for: r)
        try check(resp, d)
        return d
    }
}

/// Live speech to text (Deepgram Flux on Workers AI, through the Worker's /api/listen):
/// send the microphone as it comes in; get the words, and Flux's guesses about when
/// Jim has finished his turn, back.
final class FluxStream {
    enum Event {
        case update(String)          // the words so far this turn
        case eager(String)           // Jim has probably finished (start thinking, but hold the answer)
        case resumed                 // ...he hadn't
        case endOfTurn(String)       // he has
        case failed(String)
    }
    var onEvent: ((Event) -> Void)?  // always called on the main queue

    private let task: URLSessionWebSocketTask
    private var batch = Data()
    private var closed = false

    init(request: URLRequest) {
        task = URLSession.shared.webSocketTask(with: request)
        task.resume()
        receive()
    }

    /// 16 kHz, 16-bit mono PCM. Sent in pieces of at least 50 ms.
    func send(_ pcm: Data) {
        guard !closed else { return }
        batch.append(pcm)
        guard batch.count >= 1600 else { return }
        let piece = batch
        batch = Data()
        task.send(.data(piece)) { [weak self] err in
            if let err { self?.fail("send: \(err.localizedDescription)") }
        }
    }

    func close() {
        guard !closed else { return }
        closed = true
        onEvent = nil
        task.send(.string("{\"type\":\"CloseStream\"}")) { _ in }
        task.cancel(with: .normalClosure, reason: nil)
    }

    private func receive() {
        task.receive { [weak self] result in
            guard let self, !self.closed else { return }
            switch result {
            case .failure(let e):
                self.fail(e.localizedDescription)
            case .success(let msg):
                var data: Data?
                switch msg {
                case .string(let s): data = Data(s.utf8)
                case .data(let d): data = d
                @unknown default: break
                }
                if let data, let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    self.handle(j)
                }
                self.receive()
            }
        }
    }

    private func handle(_ j: [String: Any]) {
        let text = ((j["transcript"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let ev: Event?
        switch j["event"] as? String {
        case "Update", "StartOfTurn": ev = .update(text)
        case "EagerEndOfTurn": ev = .eager(text)
        case "TurnResumed": ev = .resumed
        case "EndOfTurn": ev = .endOfTurn(text)
        default:
            if (j["type"] as? String)?.lowercased().contains("error") == true {
                ev = .failed((j["description"] as? String) ?? (j["message"] as? String) ?? "Flux error")
            } else { ev = nil }
        }
        guard let ev else { return }
        DispatchQueue.main.async { [weak self] in self?.onEvent?(ev) }
    }

    private func fail(_ why: String) {
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.closed else { return }
            self.onEvent?(.failed(why))
        }
    }
}
