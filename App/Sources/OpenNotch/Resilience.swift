import AppKit
import Foundation

/// Small append-only log for the app itself (the backend has its own).
/// ~/Library/Application Support/OpenNotch/app.log, rotated at 1 MB.
enum AppLog {
    private static let q = DispatchQueue(label: "opennotch.applog")
    static let path = opennotchDir("") + "/app.log"

    static func write(_ line: String) {
        let stamp = ISO8601DateFormatter().string(from: Date())
        q.async {
            let fm = FileManager.default
            if let size = (try? fm.attributesOfItem(atPath: path))?[.size] as? Int, size > 1_000_000 {
                try? fm.removeItem(atPath: path + ".1")
                try? fm.moveItem(atPath: path, toPath: path + ".1")
            }
            if !fm.fileExists(atPath: path) { fm.createFile(atPath: path, contents: nil) }
            guard let h = FileHandle(forWritingAtPath: path) else { return }
            h.seekToEndOfFile()
            h.write("\(stamp) \(line)\n".data(using: .utf8)!)
            try? h.close()
        }
    }
}

/// Keeps OpenNotch alive and makes crashes visible.
///
/// A Swift crash can't be caught in-process, so resilience is two things:
///  * a launchd **supervisor** (LaunchAgent `dev.opennotch.app`) that
///    relaunches the app within seconds of a crash — but not after a normal
///    Quit (`SuccessfulExit = false`) — and starts it at login;
///  * **crash capture**: on launch, any new macOS crash report for OpenNotch
///    is copied to ~/Library/Application Support/OpenNotch/crashes/, summarised into the log, and
///    surfaced once, so nothing fails silently.
enum Supervisor {
    static let label = "dev.opennotch.app"
    static var plistPath: String { "\(NSHomeDirectory())/Library/LaunchAgents/\(label).plist" }
    private static var domain: String { "gui/\(getuid())" }

    static var installed: Bool { FileManager.default.fileExists(atPath: plistPath) }

    /// Only an installed copy (~/Applications or /Applications) is supervised —
    /// never a build in the repo, which gets replaced on every rebuild.
    static var canSupervise: Bool {
        let p = Bundle.main.bundlePath
        return p.hasPrefix(NSHomeDirectory() + "/Applications/") || p.hasPrefix("/Applications/")
    }

    /// Opted out via the menu ("Keep OpenNotch running" off).
    static var disabled: Bool {
        get { UserDefaults.standard.bool(forKey: "supervisor.off") }
        set { UserDefaults.standard.set(newValue, forKey: "supervisor.off") }
    }

    /// True when this process was started by our launchd job.
    static var isSupervised: Bool {
        ProcessInfo.processInfo.environment["XPC_SERVICE_NAME"] == label
    }

    static func writePlist() -> Bool {
        guard canSupervise, let exe = Bundle.main.executablePath else { return false }
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0"><dict>
          <key>Label</key><string>\(label)</string>
          <key>ProgramArguments</key><array><string>\(exe)</string></array>
          <key>RunAtLoad</key><true/>
          <key>KeepAlive</key><dict><key>SuccessfulExit</key><false/></dict>
          <key>ThrottleInterval</key><integer>3</integer>
          <key>ProcessType</key><string>Interactive</string>
          <key>LimitLoadToSessionType</key><string>Aqua</string>
        </dict></plist>
        """
        try? FileManager.default.createDirectory(atPath: "\(NSHomeDirectory())/Library/LaunchAgents",
                                                 withIntermediateDirectories: true)
        if (try? String(contentsOfFile: plistPath, encoding: .utf8)) != xml {
            try? xml.write(toFile: plistPath, atomically: true, encoding: .utf8)
        }
        return true
    }

    /// Opened from Finder / `open` / the build script: hand over to the
    /// launchd job so crashes get restarted. A detached shell (re)loads the
    /// job just after this process exits, so the two never overlap.
    static func handOverAndExit() -> Never {
        AppLog.write("handing over to launchd supervisor")
        let d = domain, l = label, p = plistPath
        let sh = Process()
        sh.executableURL = URL(fileURLWithPath: "/bin/sh")
        sh.arguments = ["-c", "sleep 0.7; launchctl bootout \(d)/\(l) 2>/dev/null; launchctl bootstrap \(d) '\(p)'"]
        sh.standardOutput = FileHandle.nullDevice
        sh.standardError = FileHandle.nullDevice
        try? sh.run()
        exit(0)
    }

    static func uninstall() {
        launchctl(["bootout", "\(domain)/\(label)"])
        try? FileManager.default.removeItem(atPath: plistPath)
        AppLog.write("supervisor removed")
    }

    @discardableResult
    private static func launchctl(_ args: [String]) -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return -1 }
        p.waitUntilExit()
        return p.terminationStatus
    }

    /// Two copies would fight over the notch and the hotkeys. Keep the one
    /// that was already running.
    static func isDuplicateInstance() -> Bool {
        let me = ProcessInfo.processInfo.processIdentifier
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "")
            .filter { $0.processIdentifier != me && !$0.isTerminated }
        return !others.isEmpty
    }

    // MARK: crash capture

    struct CrashSummary { let when: Date; let exception: String; let frame: String; let saved: String }

    /// New crash reports since the last launch, newest first.
    static func collectCrashes() -> [CrashSummary] {
        let dir = "\(NSHomeDirectory())/Library/Logs/DiagnosticReports"
        let seenKey = "crash.lastSeen"
        let lastSeen = UserDefaults.standard.double(forKey: seenKey)
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: dir) else { return [] }
        var out: [CrashSummary] = []
        var newest = lastSeen
        for name in names where name.hasPrefix("OpenNotch") && name.hasSuffix(".ips") {
            let path = "\(dir)/\(name)"
            guard let mtime = (try? fm.attributesOfItem(atPath: path))?[.modificationDate] as? Date,
                  mtime.timeIntervalSince1970 > lastSeen else { continue }
            newest = max(newest, mtime.timeIntervalSince1970)
            // macOS refusing one launch while build.sh swaps the bundle isn't
            // a crash of ours — logging it as one showed a false alarm per build.
            if let raw = try? String(contentsOfFile: path, encoding: .utf8),
               raw.contains("\"Launch Constraint Violation\"") {
                AppLog.write("ignored launch-constraint report (app replaced while launching): \(name)")
                continue
            }
            let saved = opennotchDir("crashes") + "/" + name
            try? fm.removeItem(atPath: saved)
            try? fm.copyItem(atPath: path, toPath: saved)
            let (exc, frame) = summarise(path)
            out.append(CrashSummary(when: mtime, exception: exc, frame: frame, saved: saved))
        }
        // First run: don't report history, just set the baseline.
        UserDefaults.standard.set(newest > 0 ? newest : Date().timeIntervalSince1970, forKey: seenKey)
        if lastSeen == 0 { return [] }
        return out.sorted { $0.when > $1.when }
    }

    private static func summarise(_ path: String) -> (String, String) {
        guard let raw = try? String(contentsOfFile: path, encoding: .utf8),
              let nl = raw.firstIndex(of: "\n"),
              let body = try? JSONSerialization.jsonObject(with: Data(raw[raw.index(after: nl)...].utf8)) as? [String: Any]
        else { return ("unknown", "") }
        let e = body["exception"] as? [String: Any]
        let exc = [e?["type"] as? String, e?["subtype"] as? String].compactMap { $0 }.joined(separator: " ")
        var frame = ""
        if let threads = body["threads"] as? [[String: Any]],
           let ft = body["faultingThread"] as? Int, ft < threads.count,
           let frames = threads[ft]["frames"] as? [[String: Any]] {
            frame = frames.compactMap { $0["symbol"] as? String }.prefix(8).joined(separator: " ← ")
        }
        return (exc.isEmpty ? "unknown" : exc, frame)
    }
}

/// Debug-only smoothness probe. `defaults write dev.opennotch.OpenNotch debug.frames -bool true`
/// then open/close the notch: each transition logs its frame count and any
/// missed frames (main-thread hitches) to app.log. Off by default, zero cost.
@MainActor
final class FrameProbe: NSObject {
    static let shared = FrameProbe()
    private var link: CADisplayLink?
    private var stamps: [CFTimeInterval] = []
    private var label = ""
    private var until: CFTimeInterval = 0

    static var enabled: Bool { UserDefaults.standard.bool(forKey: "debug.frames") }

    func capture(_ label: String, in view: NSView?) {
        guard Self.enabled, let view else { return }
        finish()
        self.label = label
        stamps = []
        until = CACurrentMediaTime() + 0.8
        let l = view.displayLink(target: self, selector: #selector(tick(_:)))
        l.add(to: .main, forMode: .common)
        link = l
    }

    @objc private func tick(_ l: CADisplayLink) {
        stamps.append(l.timestamp)
        if l.timestamp > until { finish() }
    }

    private func finish() {
        link?.invalidate()
        link = nil
        guard stamps.count > 2 else { return }
        let gaps = zip(stamps.dropFirst(), stamps).map { ($0 - $1) * 1000 }
        let hitches = gaps.filter { $0 > 20 }
        AppLog.write(String(format: "frames %@: %d frames, avg %.1fms, max %.1fms, hitches>20ms: %d %@",
                            label, gaps.count, gaps.reduce(0, +) / Double(gaps.count), gaps.max() ?? 0,
                            hitches.count, hitches.map { String(format: "%.0f", $0) }.joined(separator: ",")))
        stamps = []
    }
}
