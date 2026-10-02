import AppKit
import IOKit.pwr_mgt

// What the user is doing right now, so Ledge knows when to stay quiet.
// One state for the whole app (nudges, peek-a-boo, Puff's perch):
//
//   watching    an app holds a "don't sleep the display" assertion (Chrome's
//               "Video Wake Lock", Safari/QuickTime/VLC/IINA playback…), even windowed
//   presenting  a full-screen app in front (slides, a full-screen video, a game)
//   inCall      the mic or camera is in use by another app
//   deepWork    steady typing for most of the last minute
//   away        no input for 5 minutes
//   available   none of the above
//
// Nudges that arrive while you're busy wait in a queue and are offered at the
// next natural break (the state turning available) — interruptions at task
// boundaries cost far less than mid-task ones (Iqbal & Bailey, CHI 2007/08).

enum AttentionState: String {
    case available, watching, presenting, inCall, deepWork, away

    /// Quiet: no nudges, no peek-a-boo.
    var isBusy: Bool { self != .available }

    var label: String {
        switch self {
        case .available: return "Available"
        case .watching: return "Watching"
        case .presenting: return "Presenting"
        case .inCall: return "On a call"
        case .deepWork: return "Focused"
        case .away: return "Away"
        }
    }
}

/// Pure rules (checked by `--checks`).
enum AttentionLogic {
    /// Keep-awake utilities hold the same assertion but don't mean "watching".
    static let keepAwakeApps: Set<String> = ["caffeinate", "amphetamine", "keepingyouawake", "lungo", "theine",
                                             "owly", "opennotch", "jolt of caffeine", "coffee buzz", "sleep aid"]

    /// Does this display-sleep assertion mean something is being watched or shown?
    static func isMedia(process: String, assertion: String) -> Bool {
        let p = process.lowercased()
        if keepAwakeApps.contains(where: { p.contains($0) }) { return false }
        let a = assertion.lowercased()
        // System housekeeping that also blocks display sleep.
        if ["backupd", "powerd", "coreaudiod", "softwareupdate", "sharingd"].contains(where: { p.contains($0) }) { return false }
        if a.contains("caffeinate") { return false }
        return true
    }

    static func state(watching: Bool, fullScreen: Bool, inCall: Bool, typingShare: Double, idle: TimeInterval) -> AttentionState {
        if inCall { return .inCall }
        if fullScreen { return .presenting }
        if watching { return .watching }
        if idle > 5 * 60 { return .away }
        if typingShare >= 0.6 { return .deepWork }
        return .available
    }
}

/// Polls the signals every 2 s (cheap: one IOKit call, two event-age reads,
/// the window list only when something else hasn't already decided).
@MainActor
final class Attention: ObservableObject {
    static let shared = Attention()

    @Published private(set) var state: AttentionState = .available
    /// The app behind "watching", for the UI ("Watching in Chrome").
    @Published private(set) var source: String?
    /// Called when the state becomes available again — a natural break.
    var onBreak: (() -> Void)?
    /// Called when a call starts (mic/camera went on).
    var onCallStart: (() -> Void)?
    /// Whether another app is using the mic/camera (PrivacyMonitor).
    var inCall: () -> Bool = { false }

    private var timer: Timer?
    private var typingSamples: [Bool] = []

    func start() {
        let t = Timer(timeInterval: 2, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.poll() } }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        poll()
    }

    private func poll() {
        let key = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .keyDown)
        let mouse = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .mouseMoved)
        typingSamples.append(key < 2.5)
        if typingSamples.count > 30 { typingSamples.removeFirst(typingSamples.count - 30) }   // the last minute
        let share = typingSamples.isEmpty ? 0 : Double(typingSamples.filter { $0 }.count) / Double(typingSamples.count)
        let call = inCall()
        let media = call ? nil : Self.mediaApp()
        let full = call || media != nil ? false : Presence.frontmostIsFullScreen()
        let new = AttentionLogic.state(watching: media != nil, fullScreen: full, inCall: call,
                                       typingShare: typingSamples.count >= 10 ? share : 0, idle: min(key, mouse))
        if source != media { source = media }
        guard new != state else { return }
        let wasBusy = state.isBusy
        state = new
        if wasBusy && new == .available { onBreak?() }
        if new == .inCall { onCallStart?() }
    }

    /// The app holding a media-like "keep the display on" assertion, if any.
    static func mediaApp() -> String? {
        var dict: Unmanaged<CFDictionary>?
        guard IOPMCopyAssertionsByProcess(&dict) == kIOReturnSuccess,
              let byPid = dict?.takeRetainedValue() as? [NSNumber: [[String: Any]]] else { return nil }
        let me = ProcessInfo.processInfo.processIdentifier
        for (pid, list) in byPid where pid.int32Value != me {
            for a in list {
                let type = a["AssertType"] as? String ?? ""
                guard type == "PreventUserIdleDisplaySleep" || type == "NoDisplaySleepAssertion" else { continue }
                let name = NSRunningApplication(processIdentifier: pid.int32Value)?.localizedName
                    ?? (a["Process Name"] as? String) ?? "an app"
                if AttentionLogic.isMedia(process: name, assertion: a["AssertName"] as? String ?? "") { return name }
            }
        }
        return nil
    }
}
