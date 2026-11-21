import Foundation
import Network

/// Talks to the Mibo Voice speaker (a Home Assistant Voice PE running the
/// firmware in voice-pe/mibo-voice.yaml) over ESPHome's native API, the same
/// way Home Assistant would. The speaker listens for "Hey Mibo" itself; when it
/// hears it, it asks us to start and streams the microphone to us.
///
/// Protocol: plaintext frames of [0x00][size varint][type varint][protobuf].
/// Message numbers come from esphome/components/api/api.proto.
final class ESPHomeLink {
    enum Event {
        case connected(name: String)
        case disconnected
        case start          // the speaker heard "Hey Mibo" (or we asked it to listen)
        case stop           // the speaker wants us to stop (wake word or "stop" while busy, or its button)
        /// 16 kHz, 16-bit, mono PCM: the cleaned-up channel (for speech to text) and, if the
        /// speaker sends it, the raw channel with no automatic gain (for judging loudness).
        case audio(Data, Data?)
    }

    /// Voice assistant events we send back; they drive the speaker's light ring.
    enum VAEvent: UInt64 {
        case error = 0, runStart = 1, runEnd = 2, sttStart = 3, sttEnd = 4
        case intentStart = 5, intentEnd = 6, ttsStart = 7, ttsEnd = 8
        case vadStart = 11, vadEnd = 12
    }

    var onEvent: ((Event) -> Void)?          // always called on the main queue
    private(set) var isReady = false

    private var host: String
    private let port: UInt16 = 6053
    private let q = DispatchQueue(label: "mibo.voicepe")
    private var conn: NWConnection?
    private var buf = [UInt8]()
    private var listenKey: UInt32?
    private var retryDelay = 1.0
    private var running = false

    init(host: String) { self.host = host }

    func start() { q.async { self.running = true; self.retryDelay = 1; self.connect() } }
    func stop() {
        q.async {
            self.running = false
            let c = self.conn
            self.conn = nil
            c?.cancel()
            self.listenKey = nil
            if self.isReady { self.isReady = false; self.emit(.disconnected) }
        }
    }
    func change(host: String) { q.async { self.host = host; self.conn?.cancel() } }

    // MARK: Connection

    private func connect() {
        guard running, conn == nil, let p = NWEndpoint.Port(rawValue: port) else { return }
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        tcp.enableKeepalive = true
        tcp.connectionTimeout = 8
        let c = NWConnection(host: NWEndpoint.Host(host), port: p, using: NWParameters(tls: nil, tcp: tcp))
        conn = c
        buf.removeAll()
        c.stateUpdateHandler = { [weak self] st in self?.stateChanged(st, c) }
        c.start(queue: q)
        log("connecting to \(host)")
    }

    private func stateChanged(_ st: NWConnection.State, _ c: NWConnection) {
        guard c === conn else { return }
        switch st {
        case .ready:
            retryDelay = 1
            var m = PB()
            m.string(1, "My Mibo Apple TV")
            m.uint(2, 1)
            m.uint(3, 14)
            send(1, m)                                   // HelloRequest
            receive(c)
        case .waiting(let e):
            log("can't reach the speaker yet: \(e)")
            c.cancel()
        case .failed(let e):
            log("connection failed: \(e)")
            c.cancel()
        case .cancelled:
            dropped()
        default:
            break
        }
    }

    private func dropped() {
        conn = nil
        listenKey = nil
        if isReady {
            isReady = false
            emit(.disconnected)
        }
        guard running else { return }
        let d = retryDelay
        retryDelay = min(15, retryDelay * 2)
        q.asyncAfter(deadline: .now() + d) { [weak self] in self?.connect() }
    }

    private func receive(_ c: NWConnection) {
        c.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, done, err in
            guard let self, c === self.conn else { return }
            if let data, !data.isEmpty {
                self.buf.append(contentsOf: data)
                self.parseFrames()
            }
            if done || err != nil { c.cancel(); return }
            self.receive(c)
        }
    }

    private func parseFrames() {
        while true {
            guard buf.count >= 3 else { return }
            guard buf[0] == 0 else {
                log("the speaker sent an encrypted or unknown frame. Is it running the Mibo Voice firmware?")
                conn?.cancel()
                return
            }
            var i = 1
            guard let size = readVarint(buf, &i), let type = readVarint(buf, &i) else { return }
            guard buf.count >= i + Int(size) else { return }
            let payload = Array(buf[i..<(i + Int(size))])
            buf.removeFirst(i + Int(size))
            handle(type: Int(type), PBMessage(payload))
        }
    }

    // MARK: Messages from the speaker

    private func handle(type: Int, _ m: PBMessage) {
        switch type {
        case 2:                                          // HelloResponse
            let name = m.string(4) ?? "Mibo Voice"
            log("connected to \(name)")
            var sub = PB()
            sub.bool(1, true)
            sub.uint(2, 1)                               // VOICE_ASSISTANT_SUBSCRIBE_API_AUDIO
            send(89, sub)                                // SubscribeVoiceAssistantRequest
            send(11, PB())                               // ListEntitiesRequest (to find mibo_listen)
            isReady = true
            emit(.connected(name: name))
        case 7:                                          // PingRequest
            send(8, PB())
        case 5:                                          // DisconnectRequest
            send(6, PB())
            conn?.cancel()
        case 41:                                         // ListEntitiesServicesResponse
            if m.string(1) == "mibo_listen", let k = m.fixed32(2) { listenKey = k }
        case 90:                                         // VoiceAssistantRequest
            emit(m.bool(1) ? .start : .stop)
        case 106:                                        // VoiceAssistantAudio
            if let d = m.bytes(1), !d.isEmpty {
                let raw = m.bytes(3).flatMap { $0.isEmpty ? nil : Data($0) }
                emit(.audio(Data(d), raw))
            }
        default:
            break
        }
    }

    // MARK: Messages to the speaker

    /// Answer a start request: stream the microphone to us over this connection.
    func acceptStart(_ ok: Bool = true) {
        q.async {
            var m = PB()
            if !ok { m.bool(2, true) }                   // VoiceAssistantResponse (port 0 = API audio)
            self.send(91, m)
        }
    }

    func event(_ e: VAEvent, _ data: [(String, String)] = []) {
        q.async {
            var m = PB()
            m.uint(1, e.rawValue)
            for (k, v) in data {
                var d = PB()
                d.string(1, k)
                d.string(2, v)
                m.bytes(2, Data(d.data))
            }
            self.send(92, m)                             // VoiceAssistantEventResponse
        }
    }

    /// Open the speaker's microphone without the wake word (for follow-ups and the remote).
    func listenAgain() -> Bool {
        guard isReady else { return false }
        q.async {
            guard let k = self.listenKey else {
                self.log("the speaker has no mibo_listen action. Flash the Mibo Voice firmware.")
                return
            }
            var m = PB()
            m.fixed32(1, k)
            self.send(42, m)                             // ExecuteServiceRequest
        }
        return true
    }

    private func send(_ type: Int, _ m: PB) {
        guard let c = conn else { return }
        var f = PB()
        f.data.append(0)
        f.varint(UInt64(m.data.count))
        f.varint(UInt64(type))
        f.data.append(contentsOf: m.data)
        c.send(content: Data(f.data), completion: .contentProcessed { _ in })
    }

    private func emit(_ e: Event) { DispatchQueue.main.async { self.onEvent?(e) } }
    private func log(_ s: String) { print("My Mibo TV speaker link: " + s) }
}

// MARK: - Tiny protobuf helpers (only what this link needs)

struct PB {
    var data = [UInt8]()
    mutating func varint(_ v: UInt64) {
        var v = v
        while v >= 0x80 { data.append(UInt8(v & 0x7f) | 0x80); v >>= 7 }
        data.append(UInt8(v))
    }
    mutating func key(_ field: Int, _ wire: Int) { varint(UInt64(field << 3 | wire)) }
    mutating func uint(_ field: Int, _ v: UInt64) { key(field, 0); varint(v) }
    mutating func bool(_ field: Int, _ v: Bool) { if v { uint(field, 1) } }
    mutating func bytes(_ field: Int, _ b: Data) { key(field, 2); varint(UInt64(b.count)); data.append(contentsOf: b) }
    mutating func string(_ field: Int, _ s: String) { bytes(field, Data(s.utf8)) }
    mutating func fixed32(_ field: Int, _ v: UInt32) {
        key(field, 5)
        for s in stride(from: 0, to: 32, by: 8) { data.append(UInt8((v >> UInt32(s)) & 0xff)) }
    }
}

private func readVarint(_ b: [UInt8], _ i: inout Int) -> UInt64? {
    var v: UInt64 = 0, shift: UInt64 = 0
    while i < b.count {
        let byte = b[i]; i += 1
        v |= UInt64(byte & 0x7f) << shift
        if byte & 0x80 == 0 { return v }
        shift += 7
        if shift > 63 { return nil }
    }
    return nil
}

struct PBMessage {
    private var varints = [Int: UInt64]()
    private var blobs = [Int: [UInt8]]()
    private var fixed = [Int: UInt32]()

    init(_ b: [UInt8]) {
        var i = 0
        while i < b.count {
            guard let k = readVarint(b, &i) else { return }
            let field = Int(k >> 3)
            switch k & 7 {
            case 0:
                guard let v = readVarint(b, &i) else { return }
                varints[field] = v
            case 1:
                i += 8
            case 2:
                guard let n = readVarint(b, &i), i + Int(n) <= b.count else { return }
                blobs[field] = Array(b[i..<(i + Int(n))])
                i += Int(n)
            case 5:
                guard i + 4 <= b.count else { return }
                fixed[field] = UInt32(b[i]) | UInt32(b[i + 1]) << 8 | UInt32(b[i + 2]) << 16 | UInt32(b[i + 3]) << 24
                i += 4
            default:
                return
            }
        }
    }
    func bool(_ f: Int) -> Bool { (varints[f] ?? 0) != 0 }
    func bytes(_ f: Int) -> [UInt8]? { blobs[f] }
    func string(_ f: Int) -> String? { blobs[f].map { String(decoding: $0, as: UTF8.self) } }
    func fixed32(_ f: Int) -> UInt32? { fixed[f] }
}
