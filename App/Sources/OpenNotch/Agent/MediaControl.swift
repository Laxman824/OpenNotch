import AppKit
import Foundation

/// Spotify and Apple Music via AppleScript — a port of the original
/// `media_control.py`. Everything here blocks (osascript), so call it off the
/// main thread. Never launches a player just to answer "what's playing".
enum MediaControl {
    static let players = ["Spotify", "Music"]
    private static let artworkFile = AppPaths.root + "/music_artwork"
    nonisolated(unsafe) private static var artKey = ""
    private static let lock = NSLock()

    // MARK: queries

    static func nowPlaying() -> [String: Any] {
        for app in players where running(app) {
            let extra = app == "Spotify" ? "(artwork url of t)" : "\"\""
            let (ok, out) = osa("""
            tell application "\(app)"
              if player state is stopped then return "stopped|||"
              set t to current track
              return (player state as text) & "|" & (name of t) & "|" & (artist of t) & "|" & (album of t) & "|" & (player position as text) & "|" & ((duration of t) as text) & "|" & \(extra)
            end tell
            """)
            guard ok, out.contains("|") else { continue }
            var f = out.components(separatedBy: "|")
            while f.count < 7 { f.append("") }
            let duration = num(f[5]) / (app == "Spotify" ? 1000 : 1)          // Spotify reports ms
            var res: [String: Any] = ["success": true, "app": app, "state": f[0], "track": f[1],
                                      "artist": f[2], "album": f[3], "position": num(f[4]), "duration": duration]
            if app == "Spotify", f[6].hasPrefix("https://") { res["artwork_url"] = f[6] }
            if app == "Music", f[0] != "stopped", !f[1].isEmpty {
                res["artwork_path"] = musicArtwork(key: "\(f[1])|\(f[2])|\(f[3])")
            }
            return res
        }
        return ["success": true, "state": "stopped", "track": "", "artist": "", "album": ""]
    }

    // MARK: actions

    /// play | pause | toggle | next | previous | seek | volume | play_query
    static func control(_ action: String, query: String? = nil, position: Double? = nil, level: Int? = nil) -> [String: Any] {
        let a = action.lowercased().replacingOccurrences(of: " ", with: "_")
        switch a {
        case "now_playing", "status", "current":
            return nowPlaying()
        case "seek":
            guard let pos = position else { return fail("seek needs a position in seconds") }
            guard let p = players.first(where: running) else { return fail("Nothing is playing.") }
            let (ok, out) = osa("tell application \"\(p)\" to set player position to \(String(format: "%.2f", max(0, pos)))")
            return ok ? ["success": true, "app": p, "action": "seek", "position": max(0, pos)] : fail(out)
        case "volume":
            guard let level else {
                let (ok, out) = osa("output volume of (get volume settings)")
                return ["success": ok, "volume": out]
            }
            let v = max(0, min(100, level))
            let (ok, out) = osa("set volume output volume \(v)")
            return ok ? ["success": true, "volume": v] : fail(out)
        case "play_query", "search":
            return playQuery(query ?? "")
        case "play" where !(query ?? "").isEmpty:
            return playQuery(query ?? "")
        default:
            break
        }
        let verbs = ["play": "play", "resume": "play", "pause": "pause", "stop": "pause",
                     "toggle": "playpause", "playpause": "playpause",
                     "next": "next track", "skip": "next track",
                     "previous": "previous track", "prev": "previous track", "back": "previous track"]
        guard let verb = verbs[a] else { return fail("Unknown action “\(action)”.") }
        guard let p = pickPlayer() else { return fail("Neither Spotify nor Music is installed.") }
        let (ok, out) = osa("tell application \"\(p)\" to \(verb)")
        guard ok else { return fail(out) }
        var res: [String: Any] = ["success": true, "app": p, "action": a]
        // "Play" can succeed and still play nothing (a Music app with no songs, no
        // Spotify). Check before claiming it, and offer something that works.
        if verb == "play" {
            Thread.sleep(forTimeInterval: 0.8)
            if (nowPlaying()["state"] as? String) != "playing" { return nothingToPlay(p) }
        }
        if verb != "pause" {
            let np = nowPlaying()
            if let t = np["track"] as? String, !t.isEmpty { res["track"] = t; res["artist"] = np["artist"] }
        }
        return res
    }

    private static func playQuery(_ query: String) -> [String: Any] {
        let q = query.replacingOccurrences(of: "\"", with: "")
        guard !q.isEmpty else { return fail("What should I play?") }
        if installed("Music") {
            let (ok, out) = osa("""
            tell application "Music"
              set hits to (every track of library playlist 1 whose name contains "\(q)" or artist contains "\(q)" or album contains "\(q)")
              if (count of hits) is 0 then return "none"
              play item 1 of hits
              return (name of current track) & " — " & (artist of current track)
            end tell
            """, timeout: 15)
            if ok && out != "none" { return ["success": true, "app": "Music", "playing": out] }
        }
        let enc = q.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? q
        if installed("Spotify"), let url = URL(string: "spotify:search:" + enc) {
            NSWorkspace.shared.open(url)
            return ["success": true, "app": "Spotify", "opened_search": q,
                    "note": "Spotify search opened — press play on the top result."]
        }
        if let url = URL(string: "https://music.youtube.com/search?q=" + enc) { NSWorkspace.shared.open(url) }
        return ["success": true, "app": "YouTube Music", "opened_search": q]
    }

    /// Pressed play and nothing started. An empty Music library is the usual reason on
    /// a Mac without Spotify, so open YouTube Music in the browser instead of pretending.
    private static func nothingToPlay(_ player: String) -> [String: Any] {
        if player == "Music" {
            let (ok, out) = osa("tell application \"Music\" to count of tracks of library playlist 1")
            if ok, Int(out.trimmingCharacters(in: .whitespaces)) == 0 {
                if let url = URL(string: "https://music.youtube.com") { NSWorkspace.shared.open(url) }
                return ["success": true, "app": "YouTube Music",
                        "say": "Your Music library has no songs, so I opened YouTube Music in your browser. Tell me an artist or song and I'll search for it."]
            }
        }
        return fail("\(player) didn't start playing — open \(player) and pick something, or tell me a song or artist.")
    }

    // MARK: helpers

    static func pickPlayer() -> String? {
        players.first(where: running) ?? players.first(where: installed)
    }

    static func running(_ app: String) -> Bool { run("/usr/bin/pgrep", ["-xq", app]).status == 0 }

    static func installed(_ app: String) -> Bool {
        ["/Applications/\(app).app", "/System/Applications/\(app).app", NSHomeDirectory() + "/Applications/\(app).app"]
            .contains { FileManager.default.fileExists(atPath: $0) }
    }

    /// Apple Music only exposes artwork as raw data — written once per track.
    private static func musicArtwork(key: String) -> String {
        lock.lock(); defer { lock.unlock() }
        if key == artKey { return FileManager.default.fileExists(atPath: artworkFile) ? artworkFile : "" }
        _ = opennotchDir("")
        let (ok, _) = osa("""
        tell application "Music"
          if (count of artworks of current track) is 0 then error "none"
          set d to raw data of artwork 1 of current track
        end tell
        set f to open for access POSIX file "\(artworkFile)" with write permission
        set eof f to 0
        write d to f
        close access f
        """)
        artKey = key
        return ok ? artworkFile : ""
    }

    private static func num(_ s: String) -> Double {
        Double(s.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")) ?? 0
    }

    private static func fail(_ msg: String) -> [String: Any] { ["success": false, "error": msg] }

    static func osa(_ script: String, timeout: TimeInterval = 8) -> (Bool, String) {
        let r = run("/usr/bin/osascript", ["-e", script], timeout: timeout)
        return (r.status == 0, r.out.isEmpty ? r.err : r.out)
    }

    private static func run(_ path: String, _ args: [String], timeout: TimeInterval = 4) -> (status: Int32, out: String, err: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        guard (try? p.run()) != nil else { return (-1, "", "couldn't run \(path)") }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { if p.isRunning { p.terminate() } }
        let o = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let e = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        p.waitUntilExit()
        return (p.terminationStatus, o.trimmingCharacters(in: .whitespacesAndNewlines), e.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}

/// Short music commands handled instantly, with no model call ("pause",
/// "next song", "volume 40", "play arijit singh"). Deliberately narrow: only
/// whole-utterance matches, so "play around with the parser" or "stop the dev
/// server" still reach the assistant. Checked by Checks/media_cases.swift.
enum MediaIntent {
    struct Command: Equatable {
        var action: String
        var query: String? = nil
        var level: Int? = nil
    }

    private static let fast: [(String, String)] = [
        (#"^(?:please\s+)?(?:turn on|start|put on|play)(?: some| the| my)?\s+(?:music|songs?|spotify)$"#, "play"),
        (#"^(?:please\s+)?(?:resume|unpause|continue)(?: the)?(?: music| song| playback)?$"#, "play"),
        (#"^(?:please\s+)?(?:pause|stop|turn off)(?: the)?(?: music| song| playback| spotify)?$"#, "pause"),
        (#"^(?:please\s+)?(?:next|skip)(?: this)?(?: song| track)?$"#, "next"),
        (#"^(?:please\s+)?(?:previous|go back|last)(?: song| track)?$"#, "previous"),
        (#"^(?:what(?:'s| is) (?:playing|this song)|which song is this|now playing)\??$"#, "now_playing"),
    ]

    static func parse(_ text: String, assistantName: String = "ledge") -> Command? {
        var t = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        t = t.replacingOccurrences(of: #"[.!]+$"#, with: "", options: .regularExpression)
        let name = NSRegularExpression.escapedPattern(for: assistantName.lowercased())
        t = t.replacingOccurrences(of: "^(?:hey |ok |okay )?\(name)[, ]+", with: "", options: .regularExpression)
        guard !t.isEmpty, t.split(separator: " ").count <= 10 else { return nil }
        // Trailing filler and the player's name aren't part of what to play:
        // "play some music for me on the music app" → "play some music".
        // Keeps at least two words, so "turn on music" stays whole.
        for _ in 0..<3 {
            for rx in [#"\s+(?:for me|please|now|right now)$"#,
                       #"\s+(?:on|in|using|from)\s+(?:the\s+|my\s+)?(?:spotify|apple music|itunes|music)(?:\s+app)?$"#] {
                let s = t.replacingOccurrences(of: rx, with: "", options: .regularExpression)
                if s.split(separator: " ").count >= 2 { t = s }
            }
        }
        for (rx, action) in fast where t.range(of: rx, options: .regularExpression) != nil {
            return Command(action: action)
        }
        if let n = group(t, #"^(?:set )?volume(?: to)?\s+(\d{1,3})%?$"#) {
            return Command(action: "volume", level: Int(n))
        }
        if let g = group(t, #"^(?:please\s+)?play\s+(.{2,80})$"#) {
            let q = g.trimmingCharacters(in: .whitespaces)
            let blocked = q.range(of: #"^(?:music$|some music$|songs?$|around\b|with\b|back\b|a game\b)"#, options: .regularExpression) != nil
                || q.range(of: #"\b(?:test|tests|file|code|video|game|role)\b"#, options: .regularExpression) != nil
            if !blocked { return Command(action: "play_query", query: q) }
        }
        return nil
    }

    /// First capture group of `pattern` matched against the whole of `s`.
    private static func group(_ s: String, _ pattern: String) -> String? {
        guard let rx = try? NSRegularExpression(pattern: pattern),
              let m = rx.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)), m.numberOfRanges > 1,
              let r = Range(m.range(at: 1), in: s) else { return nil }
        return String(s[r])
    }

    /// One short, speakable line for the result.
    static func describe(_ c: Command, _ res: [String: Any]) -> String {
        guard res["success"] as? Bool == true else {
            return "Couldn't do that — \(res["error"] as? String ?? "unknown error")."
        }
        if let say = res["say"] as? String { return say }
        let app = res["app"] as? String ?? "the player"
        let now = [res["track"] as? String, res["artist"] as? String].compactMap { $0 }.filter { !$0.isEmpty }
            .joined(separator: " — ")
        switch c.action {
        case "pause": return "Paused \(app)."
        case "volume": return "Volume set to \(res["volume"].map { "\($0)" } ?? "?")."
        case "now_playing":
            return (res["state"] as? String == "playing" && !now.isEmpty) ? "Playing \(now) on \(app)." : "Nothing is playing right now."
        case "play_query":
            if let p = res["playing"] as? String { return "Playing \(p)." }
            return "Opened a \(app) search for \(res["opened_search"] as? String ?? c.query ?? "that")."
        default:
            let verb = ["play": "Playing", "next": "Skipped —", "previous": "Went back —"][c.action] ?? "Done —"
            return now.isEmpty ? "\(verb.replacingOccurrences(of: " —", with: "")) on \(app)." : "\(verb) \(now) on \(app)."
        }
    }
}
