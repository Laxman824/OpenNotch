import AppKit
import Contacts
import EventKit
import Foundation

// Reaching out first — Siri waits to be asked; this notices and offers. Each becomes a Presence nudge, so the usual
// manners apply (quiet hours, calls, full screen, typing hard, hourly caps, kinds you keep dismissing go quiet):
//   • two meetings overlap today/tomorrow → "Draft a reschedule?"
//   • reminders went overdue → "Reschedule them?"
//   • a document was just downloaded → "Summarise it?" (found through Spotlight — never opens ~/Downloads itself)
//   • a contact's birthday is today → "Draft a message?" (only if Contacts access was already given)
//   • once: Mail access is already allowed but the inbox check is off → "Keep an eye on your inbox?"
// Scans run every 5 minutes, off the main thread where they touch files or Contacts; nothing reaches the AI until a click.

/// Pure rules (checked in AgentChecks).
enum ReachoutLogic {
    struct Ev: Equatable { let id: String; let title: String; let start: Date; let end: Date }

    /// The first pair of overlapping timed events (each ≥ 10 min overlap), in start order.
    static func conflict(_ events: [Ev]) -> (Ev, Ev)? {
        let sorted = events.sorted { $0.start < $1.start }
        for (i, a) in sorted.enumerated() {
            for b in sorted[(i + 1)...] {
                if b.start >= a.end { break }
                if min(a.end, b.end).timeIntervalSince(b.start) >= 10 * 60 { return (a, b) }
            }
        }
        return nil
    }

    /// Reminders overdue by more than an hour (count).
    static func overdue(_ dues: [Date], now: Date) -> Int { dues.filter { $0 < now.addingTimeInterval(-3600) }.count }

    static let docExts: Set<String> = ["pdf", "docx", "doc", "pages", "rtf", "txt", "md", "pptx", "key", "xlsx", "csv", "numbers"]

    /// A finished download worth offering help with: a document type, not a partial file.
    static func worthOffering(download path: String) -> Bool {
        let ext = (path as NSString).pathExtension.lowercased()
        let name = (path as NSString).lastPathComponent
        return docExts.contains(ext) && !name.hasPrefix(".") && !name.hasSuffix(".crdownload") && !name.hasSuffix(".download")
    }

    /// The Spotlight query for files added to Downloads in the last N seconds that came from the web.
    static func downloadQuery(seconds: Int) -> String {
        "kMDItemDateAdded >= $time.now(-\(max(30, min(seconds, 3600)))) && kMDItemWhereFroms == \"*\""
    }

    /// Contacts whose birthday is `today` (month/day).
    static func birthdays(_ people: [(name: String, month: Int, day: Int)], month: Int, day: Int) -> [String] {
        people.filter { $0.month == month && $0.day == day && !$0.name.isEmpty }.map(\.name)
    }
}

@MainActor
final class Reachout {
    static let shared = Reachout()
    weak var hub: Hub?
    weak var backend: Backend?

    private var lastScan = Date.distantPast
    private var birthdaysScanned = ""
    private var lastDownloadScan = Date()
    private var seen: Set<String> = Set(UserDefaults.standard.stringArray(forKey: "reachout.seen") ?? [])

    private func mark(_ id: String) {
        seen.insert(id)
        UserDefaults.standard.set(Array(seen.suffix(300)), forKey: "reachout.seen")
    }

    /// Called from Presence's tick while the user is active.
    func tick(now: Date = Date()) {
        guard now.timeIntervalSince(lastScan) >= 5 * 60 else { return }
        lastScan = now
        let day = TimerStore.dayKey(now)
        if offerConflict(now: now, day: day) { return }
        if offerOverdue(now: now, day: day) { return }
        if offerInboxWatch() { return }
        scanDownloads(now: now)
        scanBirthdays(now: now, day: day)
    }

    @discardableResult
    private func offer(_ id: String, _ n: Nudge) -> Bool {
        guard !seen.contains(id), Presence.shared.offer(n) else { return false }
        mark(id)
        return true
    }

    private func offerConflict(now: Date, day: String) -> Bool {
        guard let cal = hub?.calendar, cal.eventsOK else { return false }
        let end = Calendar.current.startOfDay(for: now).addingTimeInterval(2 * 24 * 3600)
        let evs = cal.events(from: now, to: end).filter { !TodayModel.declined($0) }
            .map { ReachoutLogic.Ev(id: $0.calendarItemIdentifier, title: $0.title ?? "Event", start: $0.startDate, end: $0.endDate) }
        guard let (a, b) = ReachoutLogic.conflict(evs) else { return false }
        let when = QuickCapture.timeOnly(b.start) + (Calendar.current.isDateInToday(b.start) ? " today" : " tomorrow")
        return offer("conflict:\(a.id):\(b.id)", Nudge(kind: .conflict, icon: "calendar.badge.exclamationmark",
            title: "Two meetings overlap at \(when)", detail: "\(a.title) · \(b.title)", actionLabel: "Sort it out",
            action: .ask("“\(a.title)” and “\(b.title)” overlap (\(when)). Look at both in my calendar and suggest which to move and to when, "
                         + "then offer to draft a short reschedule email (draft only).", clip: nil)))
    }

    private func offerOverdue(now: Date, day: String) -> Bool {
        guard let cal = hub?.calendar, cal.remindersOK else { return false }
        let dues = cal.reminders.filter { !$0.isCompleted }.compactMap { $0.dueDateComponents?.date }
        let n = ReachoutLogic.overdue(dues, now: now)
        guard n > 0 else { return false }
        return offer("overdue:\(day)", Nudge(kind: .overdue, icon: "exclamationmark.circle", title: "\(n) reminder\(n == 1 ? " is" : "s are") overdue",
            detail: "Want to pick new times?", actionLabel: "Reschedule",
            action: .ask("List my overdue reminders and suggest a realistic new time for each based on my calendar. Ask before changing anything.", clip: nil)))
    }

    private func offerInboxWatch() -> Bool {
        guard let pro = hub?.proactive, !pro.inboxOn, ContextGrabber.automationStatus("com.apple.mail") == noErr,
              (UserDefaults.standard.object(forKey: FeedbackLogic.sinceKey) as? Date).map({ Date().timeIntervalSince($0) > 2 * 86_400 }) ?? false
        else { return false }
        return offer("inboxOffer", Nudge(kind: .inboxOffer, icon: "envelope.badge", title: "Want me to keep an eye on your inbox?",
            detail: "I'll tell you when a real person writes — on your Mac, nothing sent", actionLabel: "Yes, watch it", action: .enableInbox))
    }

    private func scanDownloads(now: Date) {
        let since = Int(now.timeIntervalSince(lastDownloadScan)) + 30
        lastDownloadScan = now
        let dir = NSHomeDirectory() + "/Downloads"
        let q = ReachoutLogic.downloadQuery(seconds: since)
        DispatchQueue.global(qos: .utility).async {
            let r = Proc.run("/usr/bin/mdfind", ["-onlyin", dir, q], timeout: 10)
            let files = r.out.split(separator: "\n").map(String.init).filter(ReachoutLogic.worthOffering)
            guard let f = files.last else { return }
            DispatchQueue.main.async {
                let name = (f as NSString).lastPathComponent
                Reachout.shared.offer("download:\(f)", Nudge(kind: .download, icon: "arrow.down.doc", title: "Just downloaded: \(name)",
                    detail: "Want the gist?", actionLabel: "Summarise", action: .askFile("Summarise this file in a few bullets, then the one thing I should know or do.", path: f)))
            }
        }
    }

    private func scanBirthdays(now: Date, day: String) {
        guard birthdaysScanned != day, !seen.contains("birthday:\(day)"), CNContactStore.authorizationStatus(for: .contacts) == .authorized else { return }
        let c = Calendar.current.dateComponents([.month, .day], from: now)
        guard let month = c.month, let dd = c.day, (9..<20).contains(Calendar.current.component(.hour, from: now)) else { return }
        birthdaysScanned = day                                    // once a day, offered or not
        DispatchQueue.global(qos: .utility).async {
            var people: [(name: String, month: Int, day: Int)] = []
            let req = CNContactFetchRequest(keysToFetch: [CNContactGivenNameKey, CNContactFamilyNameKey, CNContactBirthdayKey] as [CNKeyDescriptor])
            try? CNContactStore().enumerateContacts(with: req) { contact, _ in
                if let b = contact.birthday, let m = b.month, let d = b.day {
                    people.append(("\(contact.givenName) \(contact.familyName)".trimmingCharacters(in: .whitespaces), m, d))
                }
            }
            let names = ReachoutLogic.birthdays(people, month: month, day: dd)
            guard let first = names.first else { return }
            DispatchQueue.main.async {
                Reachout.shared.offer("birthday:\(day)", Nudge(kind: .birthday, icon: "gift", title: "It's \(first)'s birthday today 🎂",
                    detail: names.count > 1 ? "And \(names.count - 1) more" : "Send a note?", actionLabel: "Draft a message",
                    action: .ask("It's \(first)'s birthday today. Write me a short, warm birthday message I can send them (just the text — don't send anything).", clip: nil)))
            }
        }
    }
}
