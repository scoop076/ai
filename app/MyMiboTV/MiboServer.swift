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
    func chat(text: String, system: String, model: String, device: String) -> AsyncThrowingStream<ChatEvent, Error> {
        AsyncThrowingStream { cont in
            let task = Task {
                do {
                    var r = request("api/chat", method: "POST")
                    r.timeoutInterval = 90
                    r.setValue("application/json", forHTTPHeaderField: "content-type")
                    r.httpBody = try JSONSerialization.data(withJSONObject: ["text": text, "system": system, "model": model, "device": device])
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
