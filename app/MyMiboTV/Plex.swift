import AVFoundation
import AVKit
import Combine
import Foundation
import SwiftUI

/// Jim's Plex Media Server (on the Office Mac). My Mibo plays movies from it itself, since
/// the Plex app on Apple TV can't be controlled from outside (no "Advertise as player", and
/// it ignores deep links). The server lets devices on the home network in without signing
/// in (Plex settings > Network > "allowed without auth": 192.168.86.0/24).
final class PlexLibrary {
    struct Movie {
        let key: String
        let title: String
        let year: Int?
        let duration: Double        // seconds
        let viewOffset: Double      // seconds already watched
        let watched: Bool
        let directPart: String?     // a file the Apple TV can play as-is (mp4 + H.264), if any
    }
    struct Collection {
        let key: String
        let title: String
        let count: Int
    }

    /// The server's address. Change with: defaults key "plexURL".
    static var base: URL {
        URL(string: UserDefaults.standard.string(forKey: "plexURL") ?? "http://192.168.86.45:32400")!
    }
    let clientID: String = {
        if let id = UserDefaults.standard.string(forKey: "plexClientID") { return id }
        let id = UUID().uuidString
        UserDefaults.standard.set(id, forKey: "plexClientID")
        return id
    }()
    private(set) var collections: [Collection] = []
    private(set) var movieSections: [String] = []
    private(set) var movieCount = 0

    // MARK: Reading the library

    private func get(_ path: String, _ query: [URLQueryItem] = []) async throws -> [String: Any] {
        var c = URLComponents(url: Self.base.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        c.queryItems = query.isEmpty ? nil : query
        var r = URLRequest(url: c.url!)
        r.timeoutInterval = 10
        r.setValue("application/json", forHTTPHeaderField: "Accept")
        for (k, v) in headers { r.setValue(v, forHTTPHeaderField: k) }
        let (d, resp) = try await URLSession.shared.data(for: r)
        if let h = resp as? HTTPURLResponse, h.statusCode != 200 {
            throw NSError(domain: "Plex", code: h.statusCode, userInfo: [NSLocalizedDescriptionKey: "The Plex server answered \(h.statusCode)."])
        }
        let j = try JSONSerialization.jsonObject(with: d) as? [String: Any]
        return (j?["MediaContainer"] as? [String: Any]) ?? [:]
    }

    private var headers: [String: String] {
        ["X-Plex-Client-Identifier": clientID, "X-Plex-Product": "My Mibo", "X-Plex-Version": "1.0",
         "X-Plex-Platform": "iOS", "X-Plex-Device": "Apple TV", "X-Plex-Device-Name": "My Mibo"]
    }

    /// Learn the movie libraries and their collections.
    func refresh() async {
        do {
            let sections = (try await get("library/sections")["Directory"] as? [[String: Any]]) ?? []
            var cols: [Collection] = [], names: [String] = [], count = 0
            for s in sections where (s["type"] as? String) == "movie" {
                guard let key = Self.str(s["key"]) else { continue }
                names.append((s["title"] as? String) ?? "Movies")
                let all = try await get("library/sections/\(key)/all", [URLQueryItem(name: "type", value: "1"),
                    URLQueryItem(name: "X-Plex-Container-Start", value: "0"), URLQueryItem(name: "X-Plex-Container-Size", value: "0")])
                count += Int(Self.num(all["totalSize"]) ?? Self.num(all["size"]) ?? 0)
                for c in (try await get("library/sections/\(key)/collections")["Metadata"] as? [[String: Any]]) ?? [] {
                    guard let k = Self.str(c["ratingKey"]), let t = c["title"] as? String else { continue }
                    cols.append(Collection(key: k, title: t, count: Int(Self.num(c["childCount"]) ?? 0)))
                }
            }
            collections = cols
            movieSections = names
            movieCount = count
            print("My Mibo TV: Plex has \(count) movies and \(cols.count) collections")
        } catch {
            print("My Mibo TV: couldn't read the Plex library: \(error.localizedDescription)")
        }
    }

    /// The collection whose name best matches what Claude asked for.
    func findCollection(_ name: String) -> Collection? {
        let n = Self.norm(name)
        if let c = collections.first(where: { Self.norm($0.title) == n }) { return c }
        if let c = collections.first(where: { Self.norm($0.title).contains(n) || n.contains(Self.norm($0.title)) }) { return c }
        let words = Set(n.split(separator: " "))
        return collections.max(by: { a, b in
            Set(Self.norm(a.title).split(separator: " ")).intersection(words).count <
            Set(Self.norm(b.title).split(separator: " ")).intersection(words).count
        }).flatMap { Set(Self.norm($0.title).split(separator: " ")).intersection(words).isEmpty ? nil : $0 }
    }

    func movies(in c: Collection) async -> [Movie] {
        let items = (try? await get("library/collections/\(c.key)/children")["Metadata"] as? [[String: Any]]) ?? []
        return items.compactMap(Self.movie)
    }

    func findMovie(_ title: String) async -> Movie? {
        let n = Self.norm(title)
        var found: [Movie] = []
        for key in await sectionKeys() {
            let items = (try? await get("library/sections/\(key)/all", [URLQueryItem(name: "type", value: "1"),
                                                                          URLQueryItem(name: "title", value: title)])["Metadata"] as? [[String: Any]]) ?? []
            found += items.compactMap(Self.movie)
        }
        if found.isEmpty {
            let items = (try? await get("search", [URLQueryItem(name: "query", value: title), URLQueryItem(name: "type", value: "1")])["Metadata"] as? [[String: Any]]) ?? []
            found = items.compactMap(Self.movie)
        }
        return found.first(where: { Self.norm($0.title) == n }) ?? found.first
    }

    private func sectionKeys() async -> [String] {
        let sections = (try? await get("library/sections")["Directory"] as? [[String: Any]]) ?? []
        return sections.filter { ($0["type"] as? String) == "movie" }.compactMap { Self.str($0["key"]) }
    }

    /// What Mibo tells Claude about the library.
    var summary: String {
        guard !collections.isEmpty || movieCount > 0 else { return "" }
        let names = collections.prefix(150).map { "\($0.title) (\($0.count))" }.joined(separator: "; ")
        return "Jim's Plex library has \(movieCount) movies. Movie collections: \(names.isEmpty ? "none" : names)."
    }

    // MARK: Playing

    /// A URL the Apple TV can play: the file itself when it's already mp4 + H.264, otherwise
    /// an HLS stream the Plex server makes on the fly (it converts what the Apple TV can't play).
    func streamURL(_ m: Movie, session: String, direct: Bool) -> URL {
        if direct, let part = m.directPart {
            var c = URLComponents(url: Self.base.appendingPathComponent(part), resolvingAgainstBaseURL: false)!
            c.queryItems = headers.map { URLQueryItem(name: $0.key, value: $0.value) }
            return c.url!
        }
        var c = URLComponents(url: Self.base.appendingPathComponent("video/:/transcode/universal/start.m3u8"), resolvingAgainstBaseURL: false)!
        c.queryItems = [
            .init(name: "path", value: "/library/metadata/\(m.key)"), .init(name: "mediaIndex", value: "0"),
            .init(name: "partIndex", value: "0"), .init(name: "protocol", value: "hls"),
            .init(name: "fastSeek", value: "1"), .init(name: "directPlay", value: "0"),
            .init(name: "directStream", value: "1"), .init(name: "directStreamAudio", value: "1"),
            .init(name: "videoQuality", value: "100"), .init(name: "maxVideoBitrate", value: "12000"),
            .init(name: "videoResolution", value: "1920x1080"), .init(name: "subtitles", value: "burn"),
            .init(name: "session", value: session), .init(name: "X-Plex-Session-Identifier", value: session),
        ] + headers.map { URLQueryItem(name: $0.key, value: $0.value) }
        return c.url!
    }

    /// Tell Plex where playback is, so Continue Watching stays right.
    func timeline(_ m: Movie, state: String, time: Double) {
        Task {
            _ = try? await get(":/timeline", [
                .init(name: "ratingKey", value: m.key), .init(name: "key", value: "/library/metadata/\(m.key)"),
                .init(name: "state", value: state), .init(name: "time", value: String(Int(time * 1000))),
                .init(name: "duration", value: String(Int(m.duration * 1000))),
            ])
        }
    }

    func markWatched(_ m: Movie) {
        Task { _ = try? await get(":/scrobble", [.init(name: "key", value: m.key), .init(name: "identifier", value: "com.plexapp.plugins.library")]) }
    }

    func stopTranscode(session: String) {
        Task { _ = try? await get("video/:/transcode/universal/stop", [.init(name: "session", value: session)]) }
    }

    // MARK: Helpers

    static func movie(_ d: [String: Any]) -> Movie? {
        guard let key = str(d["ratingKey"]), let title = d["title"] as? String else { return nil }
        let media = (d["Media"] as? [[String: Any]])?.first
        let part = (media?["Part"] as? [[String: Any]])?.first
        let container = ((part?["container"] ?? media?["container"]) as? String)?.lowercased() ?? ""
        let video = (media?["videoCodec"] as? String)?.lowercased() ?? ""
        let audio = (media?["audioCodec"] as? String)?.lowercased() ?? ""
        // The Apple TV HD plays H.264 in mp4/mov natively; anything else goes through Plex's converter.
        let playable = ["mp4", "m4v", "mov"].contains(container) && video == "h264" && ["aac", "ac3", "eac3", "mp3"].contains(audio)
        return Movie(key: key, title: title, year: num(d["year"]).map { Int($0) },
                     duration: (num(d["duration"]) ?? 0) / 1000, viewOffset: (num(d["viewOffset"]) ?? 0) / 1000,
                     watched: (num(d["viewCount"]) ?? 0) > 0, directPart: playable ? (part?["key"] as? String) : nil)
    }

    static func str(_ v: Any?) -> String? {
        if let s = v as? String { return s }
        if let n = v as? NSNumber { return n.stringValue }
        return nil
    }
    static func num(_ v: Any?) -> Double? {
        if let n = v as? NSNumber { return n.doubleValue }
        if let s = v as? String { return Double(s) }
        return nil
    }
    static func norm(_ s: String) -> String {
        s.lowercased().replacingOccurrences(of: "&", with: " and ")
            .replacingOccurrences(of: "[^a-z0-9 ]", with: " ", options: .regularExpression)
            .split(separator: " ").filter { $0 != "the" && $0 != "collection" && $0 != "movies" }.joined(separator: " ")
    }
}

/// Plays Plex movies full-screen in My Mibo, one after another for a shuffled collection.
@MainActor
final class MoviePlayer: ObservableObject {
    @Published var showing = false
    @Published private(set) var title = ""
    let player = AVPlayer()
    var plex: PlexLibrary?
    /// The movie was paused because Jim said "Hey Mibo"; it resumes after Mibo answers.
    var autoPaused = false

    private var queue: [PlexLibrary.Movie] = []
    private var current: PlexLibrary.Movie?
    private var session = UUID().uuidString
    private var triedDirect = false
    private var timer: Timer?
    private var watchers = Set<AnyCancellable>()

    var isPlaying: Bool { showing && player.rate > 0 }

    func play(_ movies: [PlexLibrary.Movie]) {
        queue = movies
        next()
    }

    func next() {
        guard !queue.isEmpty else { close(); return }
        start(queue.removeFirst())
    }

    private func start(_ m: PlexLibrary.Movie, direct: Bool = true) {
        guard let plex else { return }
        if let old = current, old.key != m.key { plex.timeline(old, state: "stopped", time: player.currentTime().seconds) }
        plex.stopTranscode(session: session)
        session = UUID().uuidString
        current = m
        triedDirect = direct && m.directPart != nil
        title = m.title
        let item = AVPlayerItem(url: plex.streamURL(m, session: session, direct: direct))
        watchers.removeAll()
        item.publisher(for: \.status).receive(on: DispatchQueue.main).sink { [weak self] status in
            guard let self, status == .failed else { return }
            print("My Mibo TV: movie failed: \(item.error?.localizedDescription ?? "?")")
            if self.triedDirect { self.start(m, direct: false) }   // fall back to Plex's converter
        }.store(in: &watchers)
        NotificationCenter.default.publisher(for: AVPlayerItem.didPlayToEndTimeNotification, object: item)
            .receive(on: DispatchQueue.main).sink { [weak self] _ in
                guard let self, let m = self.current else { return }
                plex.markWatched(m)
                self.next()
            }.store(in: &watchers)
        player.replaceCurrentItem(with: item)
        // Pick up where Jim left off, unless he finished it.
        if !m.watched && m.viewOffset > 60 && m.viewOffset < m.duration - 300 {
            player.seek(to: CMTime(seconds: m.viewOffset, preferredTimescale: 1))
        }
        player.play()
        autoPaused = false
        showing = true
        print("My Mibo TV: playing \(m.title) (\(triedDirect ? "file" : "Plex stream"))")
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.report() }
        }
    }

    private func report() {
        guard let m = current, showing else { return }
        plex?.timeline(m, state: player.rate > 0 ? "playing" : "paused", time: player.currentTime().seconds)
    }

    func pause() { player.pause(); report() }
    func resume() { autoPaused = false; player.play(); report() }
    func seek(by seconds: Double) {
        let t = max(0, player.currentTime().seconds + seconds)
        player.seek(to: CMTime(seconds: t, preferredTimescale: 1))
    }
    func restart() { player.seek(to: .zero); player.play() }

    /// Stop and close the player (also when Jim presses Menu on the remote).
    func close() {
        if let m = current { plex?.timeline(m, state: "stopped", time: player.currentTime().seconds) }
        plex?.stopTranscode(session: session)
        timer?.invalidate(); timer = nil
        watchers.removeAll()
        player.pause()
        player.replaceCurrentItem(with: nil)
        queue = []
        current = nil
        autoPaused = false
        if showing { showing = false }
        title = ""
    }

    /// For Claude: what's on and where.
    var status: String {
        guard showing, let m = current else { return "" }
        func hms(_ s: Double) -> String {
            let s = Int(max(0, s)); return String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60)
        }
        return "Now on the TV: \(m.title)\(m.year.map { " (\($0))" } ?? ""), at \(hms(player.currentTime().seconds)) of \(hms(m.duration))"
            + (queue.isEmpty ? "" : ", \(queue.count) more from the collection after it") + "."
    }
}

/// The full-screen movie player (Apple's standard one: the remote can pause, scrub and
/// press Menu to stop).
struct MoviePlayerView: UIViewControllerRepresentable {
    let player: AVPlayer
    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let vc = AVPlayerViewController()
        vc.player = player
        return vc
    }
    func updateUIViewController(_ vc: AVPlayerViewController, context: Context) {
        if vc.player !== player { vc.player = player }
    }
}
