import AppKit
import SwiftUI

// Ledge's presence: little drop-downs when something useful happens (you copied
// an error, you've been at it for an hour, you're back from a break, it's a new
// day) and peek-a-boos with a line that fits the moment. Everything is local and
// cheap — the AI only runs when you click the action. Good manners first: never
// during calls, full-screen apps, approvals or quiet hours; gaps and an hourly
// cap per liveliness level; a kind dismissed 3 times in a day stays quiet.

enum Liveliness: String, CaseIterable, Identifiable {
    case calm, friendly, lively
    var id: String { rawValue }
    static let pref = "presence.level"
    static var current: Liveliness {
        UserDefaults.standard.string(forKey: pref).flatMap(Liveliness.init(rawValue:)) ?? .lively
    }

    var label: String {
        switch self {
        case .calm: return "Calm"
        case .friendly: return "Friendly"
        case .lively: return "Lively"
        }
    }
    var blurb: String {
        switch self {
        case .calm: return "Speaks up rarely — meetings and things you asked for"
        case .friendly: return "Helpful nudges now and then, peeks every 15 min or so"
        case .lively: return "Checks in often, offers help with what you copy, peeks every few minutes"
        }
    }
}

struct Nudge: Identifiable, Equatable {
    enum Kind: String, CaseIterable { case clipLink, clipError, clipCode, clipLong, stretch, welcomeBack, morning }
    enum Action: Equatable {
        case ask(String, clip: String?)       // send to Ledge, optionally with the clipboard attached
        case startBreak(minutes: Int)
        case openChat
    }
    var id = UUID()
    let kind: Kind
    let icon: String
    let title: String
    var detail: String = ""
    let actionLabel: String
    let action: Action
}

/// The rules, pure (checked by `--checks`).
enum PresenceLogic {
    /// What kind of thing was copied, if it's worth offering help with.
    static func classify(_ text: String) -> Nudge.Kind? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.count >= 12, t.count <= 60_000 else { return nil }
        if t.range(of: #"^https?://\S+$"#, options: .regularExpression) != nil { return .clipLink }
        let errorPattern = #"(Traceback \(most recent call last\)|\b(Error|Exception|Panic|FATAL|fatal error)\b[:\s]|"#
            + #"error\[E\d+\]|Uncaught |Segmentation fault|exit code [1-9]|\bat .+:\d+:\d+|npm ERR!)"#
        if t.range(of: errorPattern, options: .regularExpression) != nil { return .clipError }
        let lines = t.split(separator: "\n", omittingEmptySubsequences: false)
        let codeHits = lines.filter { l in
            l.range(of: #"^\s*(func |def |class |import |#include|let |const |var |public |private |return |if \(|for \(|\}|\{$|<\/?[a-z]+[ >])"#,
                    options: .regularExpression) != nil
        }.count
        if lines.count >= 3 && Double(codeHits) / Double(lines.count) >= 0.3 { return .clipCode }
        if t.count >= 600 && t.split(separator: " ").count >= 90 { return .clipLong }
        return nil
    }

    static func nudge(forClip text: String) -> Nudge? {
        guard let kind = classify(text) else { return nil }
        let snippet = String(text.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\n", with: " ").prefix(70))
        switch kind {
        case .clipLink:
            let host = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines))?.host ?? "this link"
            return Nudge(kind: kind, icon: "link", title: "Summarise \(host)?", detail: snippet, actionLabel: "Summarise",
                         action: .ask("Summarise the page at this link in a few bullets, then tell me the one thing worth remembering: \(text.trimmingCharacters(in: .whitespacesAndNewlines))", clip: nil))
        case .clipError:
            return Nudge(kind: kind, icon: "ladybug", title: "Want me to explain that error?", detail: snippet, actionLabel: "Explain",
                         action: .ask("Explain this error in plain words: what it means, the likely cause, and how to fix it.", clip: text))
        case .clipCode:
            return Nudge(kind: kind, icon: "chevron.left.forwardslash.chevron.right", title: "Explain or improve this code?", detail: snippet,
                         actionLabel: "Explain", action: .ask("Explain what this code does, briefly, then point out any bugs or improvements.", clip: text))
        case .clipLong:
            return Nudge(kind: kind, icon: "text.alignleft", title: "Summarise what you copied?", detail: snippet, actionLabel: "Summarise",
                         action: .ask("Summarise this in 3–5 bullets, then the single most important point.", clip: text))
        default:
            return nil
        }
    }

    /// Minutes of continuous activity before suggesting a break.
    static func stretchAfter(_ l: Liveliness) -> TimeInterval {
        switch l { case .calm: return 100 * 60; case .friendly: return 60 * 60; case .lively: return 45 * 60 }
    }
    /// Minimum time between two nudges.
    static func gap(_ l: Liveliness) -> TimeInterval {
        switch l { case .calm: return 45 * 60; case .friendly: return 12 * 60; case .lively: return 4 * 60 }
    }
    static func maxPerHour(_ l: Liveliness) -> Int {
        switch l { case .calm: return 1; case .friendly: return 3; case .lively: return 6 }
    }
    /// Minutes between peek-a-boos.
    static func peekEvery(_ l: Liveliness) -> ClosedRange<Double> {
        switch l { case .calm: return 30...50; case .friendly: return 12...25; case .lively: return 4...8 }
    }
    /// Kinds that only lively/friendly levels offer (calm keeps to the essentials).
    static func allowed(_ k: Nudge.Kind, _ l: Liveliness) -> Bool {
        switch l {
        case .lively: return true
        case .friendly: return k != .clipLong && k != .clipCode
        case .calm: return k == .welcomeBack
        }
    }
    static func quietHours(_ hour: Int) -> Bool { hour >= 22 || hour < 7 }

    /// A line for a peek-a-boo, fitting the time of day. `seed` picks among options.
    static func peekLine(hour: Int, minute: Int, weekday: Int, seed: Int) -> String {
        func pick(_ a: [String]) -> String { a[abs(seed) % a.count] }
        switch (hour, minute) {
        case (7..<10, _): return pick(["Morning! ☀️", "Coffee first? ☕", "Fresh day, fresh notch ✨"])
        case (12, 15...), (13, ..<30): return pick(["Lunch soon? 🍜", "Food break? 🥪"])
        case (15, _): return pick(["Afternoon slump? Water helps 💧", "Halfway through the afternoon 💪"])
        case (17..<19, _) where weekday == 6: return pick(["Almost weekend! 🎉", "Friday feeling 🕺"])
        case (18..<22, _): return pick(["Wrapping up soon? 🌙", "Long day — nice work 🙌"])
        default: return pick(["Need anything? 👀", "Still here if you need me", "Just checking in 👋", "Ask me anything ✨",
                              "Psst — ⌥Space to talk to me"])
        }
    }

    /// What to say when you come back after being away.
    static func welcomeBack(away: TimeInterval, nextEvent: (title: String, at: Date)?, remindersDue: Int, answerReady: Bool) -> Nudge {
        var bits: [String] = []
        if answerReady { bits.append("your answer is ready") }
        if let e = nextEvent {
            let f = DateFormatter(); f.timeStyle = .short; f.dateStyle = .none
            bits.append("next: \(e.title) at \(f.string(from: e.at))")
        }
        if remindersDue > 0 { bits.append("\(remindersDue) reminder\(remindersDue == 1 ? "" : "s") due") }
        let mins = Int(away / 60)
        let title = mins >= 90 ? "Welcome back! 👋" : "Back! You were away \(mins) min"
        return Nudge(kind: .welcomeBack, icon: "hand.wave", title: title,
                     detail: bits.isEmpty ? "Nothing new — what's next?" : bits.joined(separator: " · ").capitalizedFirst,
                     actionLabel: answerReady ? "Show me" : "Catch me up",
                     action: answerReady ? .openChat
                        : .ask("I'm back at my Mac. Catch me up in 3 short bullets: what's next on my calendar today and which reminders are due.", clip: nil))
    }
}

extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}

/// Watches activity and the clipboard; decides when Ledge pops out.
@MainActor
final class Presence: ObservableObject {
    static let shared = Presence()

    weak var notch: NotchController?
    weak var backend: Backend?
    weak var hub: Hub?

    private var timer: Timer?
    private var shown: [Date] = []
    private var lastShown = Date.distantPast
    private var activeSince = Date()
    private var awaySince: Date?
    private var dismissals: [Nudge.Kind: Int] = [:]
    private var dismissDay = ""
    private var lastClipNudge: [Nudge.Kind: Date] = [:]

    func start() {
        timer = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    private var idle: TimeInterval {
        min(CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .mouseMoved),
            CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .keyDown))
    }

    private func tick() {
        let now = Date()
        let i = idle
        if i > 15 * 60 {
            if awaySince == nil { awaySince = now.addingTimeInterval(-i) }
            return
        }
        if i > 5 * 60 { activeSince = now }                                     // a real pause resets the clock
        if let since = awaySince, i < 20 {
            awaySince = nil
            activeSince = now
            let away = now.timeIntervalSince(since)
            if away >= 20 * 60 { offer(welcomeBack(away: away)) }
            maybeMorning()
            return
        }
        if now.timeIntervalSince(activeSince) > PresenceLogic.stretchAfter(Liveliness.current) {
            let mins = Int(now.timeIntervalSince(activeSince) / 60)
            if offer(Nudge(kind: .stretch, icon: "figure.cooldown", title: "You've been at it for \(mins) min",
                           detail: "A short break keeps you sharp — stretch, water, look away from the screen.",
                           actionLabel: "5-min break", action: .startBreak(minutes: 5))) {
                activeSince = now
            }
        }
    }

    /// The first time you're at the Mac each morning.
    private func maybeMorning() {
        let now = Date()
        let hour = Calendar.current.component(.hour, from: now)
        let day = TimerStore.dayKey(now)
        guard (5..<12).contains(hour), UserDefaults.standard.string(forKey: "presence.morning") != day else { return }
        UserDefaults.standard.set(day, forKey: "presence.morning")
        let start = Calendar.current.startOfDay(for: now)
        let events = hub?.calendar.events(from: now, to: start.addingTimeInterval(24 * 3600)) ?? []
        let f = DateFormatter(); f.timeStyle = .short; f.dateStyle = .none
        let detail = events.isEmpty ? "Your calendar is clear today."
            : "\(events.count) event\(events.count == 1 ? "" : "s") today, first at \(f.string(from: events[0].startDate))."
        offer(Nudge(kind: .morning, icon: "sun.max", title: "Good morning! ☀️", detail: detail, actionLabel: "Plan my day",
                    action: .ask("Plan my day: look at today's calendar events, my open reminders and the weather where I am, then give me a short, focused plan.", clip: nil)))
    }

    private func welcomeBack(away: TimeInterval) -> Nudge {
        let now = Date()
        let next = hub?.calendar.events(from: now, to: now.addingTimeInterval(3 * 3600)).first
        let due = hub?.calendar.reminders.filter { r in
            guard let d = r.dueDateComponents?.date else { return false }
            return d < now.addingTimeInterval(3600)
        }.count ?? 0
        return PresenceLogic.welcomeBack(away: away, nextEvent: next.map { ($0.title ?? "Event", $0.startDate) },
                                         remindersDue: due, answerReady: backend?.unseenAnswer ?? false)
    }

    /// Something was copied (ClipboardStore).
    func copied(_ text: String) {
        guard NSWorkspace.shared.frontmostApplication?.bundleIdentifier != Bundle.main.bundleIdentifier,
              let n = PresenceLogic.nudge(forClip: text) else { return }
        // The same kind of clip at most every 10 minutes.
        if let t = lastClipNudge[n.kind], Date().timeIntervalSince(t) < 10 * 60 { return }
        if offer(n) { lastClipNudge[n.kind] = Date() }
    }

    /// Show it if manners allow. Returns whether it was shown.
    @discardableResult
    func offer(_ n: Nudge) -> Bool {
        let level = Liveliness.current
        let now = Date()
        resetDismissalsIfNewDay()
        guard let notch, let backend,
              PresenceLogic.allowed(n.kind, level),
              !PresenceLogic.quietHours(Calendar.current.component(.hour, from: now)),
              dismissals[n.kind, default: 0] < 3,
              notch.mode == .collapsed || notch.mode == .hello,
              !backend.busy, backend.approvals.isEmpty, !(notch.handsFree?.isOn ?? false),
              !notch.privacy.active,                                  // on a call: stay out of the way
              !Self.frontmostIsFullScreen(),
              now.timeIntervalSince(lastShown) >= PresenceLogic.gap(level) else { return false }
        shown = shown.filter { now.timeIntervalSince($0) < 3600 }
        guard shown.count < PresenceLogic.maxPerHour(level) else { return false }
        shown.append(now)
        lastShown = now
        SoundFX.play(.peek)
        notch.showAlert(.nudge(n), for: n.kind == .welcomeBack || n.kind == .morning ? 12 : 9)
        return true
    }

    func act(_ n: Nudge) {
        guard let notch, let backend, let hub else { return }
        dismissals[n.kind] = 0
        switch n.action {
        case let .ask(prompt, clip):
            hub.module = .chat
            notch.expand(pinned: true)
            if let clip { backend.attach(Attachment(kind: .clipboard, value: String(clip.prefix(20_000)))) }
            backend.send(prompt)
        case .startBreak(let minutes):
            hub.timers.startCountdown(seconds: TimeInterval(minutes * 60))
            notch.collapse()
        case .openChat:
            hub.module = .chat
            notch.expand(pinned: true)
        }
    }

    func dismiss(_ n: Nudge) {
        resetDismissalsIfNewDay()
        dismissals[n.kind, default: 0] += 1
        notch?.collapse()
    }

    private func resetDismissalsIfNewDay() {
        let d = TimerStore.dayKey(Date())
        if d != dismissDay { dismissDay = d; dismissals = [:] }
    }

    /// Is the frontmost app covering the whole screen (video, slides, a full-screen editor)?
    static func frontmostIsFullScreen() -> Bool {
        guard let app = NSWorkspace.shared.frontmostApplication, let screen = NSScreen.main,
              let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
        else { return false }
        let frame = screen.frame
        return list.contains { w in
            guard (w[kCGWindowOwnerPID as String] as? pid_t) == app.processIdentifier,
                  (w[kCGWindowLayer as String] as? Int) == 0,
                  let b = w[kCGWindowBounds as String] as? [String: CGFloat] else { return false }
            return (b["Width"] ?? 0) >= frame.width && (b["Height"] ?? 0) >= frame.height
        }
    }
}

// MARK: - View

/// The drop-down: Ledge, what's up, one action, and "not now".
struct NudgeView: View {
    let nudge: Nudge
    @ObservedObject var backend: Backend
    @State private var bumps = 0

    var body: some View {
        HStack(spacing: 12) {
            AssistantFace(size: 30, backend: backend, tracksCursor: false, greets: true)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Image(systemName: nudge.icon).font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Module.chat.accent)
                        .symbolEffect(.bounce, value: bumps)
                    Text(nudge.title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                }
                if !nudge.detail.isEmpty {
                    Text(nudge.detail).font(.system(size: 11)).foregroundStyle(Theme.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 6)
            PillButton(label: nudge.actionLabel, primary: true) { Presence.shared.act(nudge) }
                .environment(\.moduleAccent, Module.chat.accent)
            Button { Presence.shared.dismiss(nudge) } label: {
                Image(systemName: "xmark").font(.system(size: 9, weight: .bold)).foregroundStyle(Theme.tertiary)
                    .frame(width: 20, height: 20).contentShape(Circle())
            }
            .buttonStyle(.plain)
            .help("Not now")
        }
        .onAppear { DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { bumps += 1 } }
    }
}
