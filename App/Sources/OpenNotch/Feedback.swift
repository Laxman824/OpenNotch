import AppKit
import SwiftUI

// "How's it going?" — after a week of real use, one drop-down with 👍 / 👎. Either opens a small
// window for a note that the user sends themselves (a prefilled GitHub issue, or copy it anywhere).
// No telemetry: nothing leaves the Mac unless the user clicks Send. Never chat text, memories or keys —
// only the note they typed and, if they leave the box ticked, the app version, macOS version and AI kind.
// Also always reachable from the ⋯ menu › Send Feedback….

/// Pure rules (checked in AgentChecks).
enum FeedbackLogic {
    static let repo = "https://github.com/Laxman824/OpenNotch"
    static let sinceKey = "feedback.since"          // first day seen (Date)
    static let daysKey = "feedback.days"            // recent active day keys ([String], ≤ 30)
    static let askedKey = "feedback.asked"          // when the card was last shown (Date)
    static let askCountKey = "feedback.askCount"    // how many times it was shown (Int)
    static let answeredKey = "feedback.answered"    // when the user last picked 👍/👎 (Date)

    static let minDays: TimeInterval = 7 * 86_400   // a week after install
    static let minActiveDays = 3                     // used on at least 3 different days
    static let reaskAfter: TimeInterval = 21 * 86_400
    static let quietAfterAnswer: TimeInterval = 120 * 86_400
    static let maxAsks = 3                           // dismissed 3 times → never again

    /// Should the card be offered now?
    static func shouldAsk(now: Date, since: Date?, activeDays: Int, lastAsked: Date?, askCount: Int, answered: Date?) -> Bool {
        guard let since, now.timeIntervalSince(since) >= minDays, activeDays >= minActiveDays, askCount < maxAsks else { return false }
        if let answered, now.timeIntervalSince(answered) < quietAfterAnswer { return false }
        if let lastAsked, now.timeIntervalSince(lastAsked) < reaskAfter { return false }
        return true
    }

    /// Adds today to the recent active days (newest last, unique, ≤ 30).
    static func addDay(_ day: String, to days: [String]) -> [String] {
        guard days.last != day else { return days }
        return Array((days.filter { $0 != day } + [day]).suffix(30))
    }

    /// The one line of context, only if the user agreed: "OpenNotch 0.1.5 · macOS 27.2.1 · AI: apple".
    static func infoLine(version: String, os: String, ai: String?) -> String {
        "OpenNotch \(version) · macOS \(os) · AI: \(ai ?? "none")"
    }

    static func title(good: Bool, note: String) -> String {
        let first = note.split(whereSeparator: \.isNewline).first.map(String.init)?
            .trimmingCharacters(in: .whitespaces) ?? ""
        let gist = first.isEmpty ? (good ? "It's going well" : "Something isn't right") : String(first.prefix(60))
        return (good ? "👍 " : "👎 ") + "Feedback: " + gist
    }

    static func body(good: Bool, note: String, info: String?) -> String {
        let n = String(note.trimmingCharacters(in: .whitespacesAndNewlines).prefix(4000))
        var s = n.isEmpty ? (good ? "(no note — just a thumbs up)" : "(no note)") : n
        if let info { s += "\n\n---\n" + info }
        return s
    }

    /// A prefilled "new issue" page. Contains only what's passed in (the typed note + the optional info line).
    static func issueURL(good: Bool, note: String, info: String?) -> URL? {
        var c = URLComponents(string: repo + "/issues/new")
        c?.queryItems = [URLQueryItem(name: "title", value: title(good: good, note: note)),
                         URLQueryItem(name: "body", value: body(good: good, note: note, info: info)),
                         URLQueryItem(name: "labels", value: "feedback")]
        return c?.url
    }
}

/// Remembers active days and decides when to offer the card (via Presence, so its manners apply).
@MainActor
enum Feedback {
    private static var d: UserDefaults { .standard }

    /// Called while the user is active (Presence tick).
    static func noteActive(now: Date = Date()) {
        if d.object(forKey: FeedbackLogic.sinceKey) == nil { d.set(now, forKey: FeedbackLogic.sinceKey) }
        let days = d.stringArray(forKey: FeedbackLogic.daysKey) ?? []
        let next = FeedbackLogic.addDay(TimerStore.dayKey(now), to: days)
        if next != days { d.set(next, forKey: FeedbackLogic.daysKey) }
    }

    static var due: Bool {
        FeedbackLogic.shouldAsk(now: Date(), since: d.object(forKey: FeedbackLogic.sinceKey) as? Date,
                                activeDays: (d.stringArray(forKey: FeedbackLogic.daysKey) ?? []).count,
                                lastAsked: d.object(forKey: FeedbackLogic.askedKey) as? Date,
                                askCount: d.integer(forKey: FeedbackLogic.askCountKey),
                                answered: d.object(forKey: FeedbackLogic.answeredKey) as? Date)
    }

    static func markShown() {
        d.set(Date(), forKey: FeedbackLogic.askedKey)
        d.set(d.integer(forKey: FeedbackLogic.askCountKey) + 1, forKey: FeedbackLogic.askCountKey)
    }

    static func markAnswered() { d.set(Date(), forKey: FeedbackLogic.answeredKey) }

    static let nudge = Nudge(kind: .feedback, icon: "heart", title: "How's it going so far?",
                             detail: "One tap helps me get better", actionLabel: "", action: .feedback)

    static var infoLine: String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        let os = "\(v.majorVersion).\(v.minorVersion)" + (v.patchVersion > 0 ? ".\(v.patchVersion)" : "")
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
        return FeedbackLogic.infoLine(version: version, os: os, ai: ProviderStore.activeKind?.rawValue)
    }
}

// MARK: - Window

final class FeedbackWindow: NSObject, NSWindowDelegate {
    static let shared = FeedbackWindow()
    private var window: NSWindow?

    /// `good`: nil = from the menu (the user picks), true/false = from the card's thumb.
    @MainActor func show(good: Bool?) {
        let w = window ?? {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 440, height: 360),
                             styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
            w.title = "Send Feedback"
            w.titlebarAppearsTransparent = true
            w.isReleasedWhenClosed = false
            w.delegate = self
            window = w
            return w
        }()
        w.contentView = NSHostingView(rootView: FeedbackView(good: good) { [weak self] in self?.window?.close() })
        w.center()
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
    }
}

struct FeedbackView: View {
    @State var good: Bool?
    let close: () -> Void
    @State private var note = ""
    @State private var includeInfo = true
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                thumb(true)
                thumb(false)
                Spacer()
            }
            Text(heading).font(.system(size: 15, weight: .semibold))
            TextEditor(text: $note)
                .font(.system(size: 13))
                .scrollContentBackground(.hidden)
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.06)))
                .frame(minHeight: 110)
            Toggle(isOn: $includeInfo) {
                Text("Include app version, macOS version and which AI you use — never your chats or personal data")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            .toggleStyle(.checkbox)
            if includeInfo {
                Text(Feedback.infoLine).font(.system(size: 10.5, design: .monospaced)).foregroundStyle(.tertiary)
            }
            HStack {
                if good == true {
                    Button("⭐ Star on GitHub") { NSWorkspace.shared.open(URL(string: FeedbackLogic.repo)!) }
                }
                Spacer()
                Button(copied ? "Copied ✓" : "Copy") {
                    let pb = NSPasteboard.general
                    pb.clearContents()
                    pb.setString(FeedbackLogic.title(good: good ?? true, note: note) + "\n\n"
                                 + FeedbackLogic.body(good: good ?? true, note: note, info: includeInfo ? Feedback.infoLine : nil), forType: .string)
                    copied = true
                }
                .help("Copy it to send by email or anywhere you like")
                Button("Send on GitHub") {
                    if let u = FeedbackLogic.issueURL(good: good ?? true, note: note, info: includeInfo ? Feedback.infoLine : nil) {
                        NSWorkspace.shared.open(u)
                    }
                    close()
                }
                .buttonStyle(.borderedProminent)
                .disabled(good == nil)
                .help("Opens a prefilled issue in your browser — nothing is sent until you submit it there")
            }
        }
        .padding(.horizontal, 20).padding(.top, 34).padding(.bottom, 18)
        .frame(width: 440)
    }

    private var heading: String {
        switch good {
        case .some(true): return "Glad to hear it! What do you like most — or what's missing?"
        case .some(false): return "Sorry about that. What went wrong, or what did you expect?"
        case .none: return "How's it going? Pick one, then tell me anything."
        }
    }

    private func thumb(_ up: Bool) -> some View {
        Button { good = up } label: {
            Text(up ? "👍" : "👎").font(.system(size: 26))
                .frame(width: 52, height: 44)
                .background(RoundedRectangle(cornerRadius: 10).fill(good == up ? Color.accentColor.opacity(0.25) : Color.primary.opacity(0.06)))
        }
        .buttonStyle(.plain)
        .help(up ? "It's going well" : "Something isn't right")
    }
}
