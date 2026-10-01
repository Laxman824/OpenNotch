import AppKit
import EventKit
import SwiftUI

/// Something the notch suggests on its own. **Proposals never act by
/// themselves** — the primary action runs only when you click it (the
/// "propose, don't act" stance from plan_new_personal_agent.md).
struct Proposal: Identifiable, Codable, Equatable {
    enum Kind: String, Codable { case brief, meeting, inbox }
    var id: String                     // stable per source item → natural de-duplication
    var kind: Kind
    var title: String
    var detail: String
    var actionLabel: String
    var prompt: String?                // sent to Ledge when you take the action
    var url: String?                   // meeting join link
    var body: String?                  // precomputed text (the brief)
    var created = Date()
    var expires: Date

    var icon: String {
        switch kind {
        case .brief: return "sun.max.fill"
        case .meeting: return "video.fill"
        case .inbox: return "envelope.badge.fill"
        }
    }
}

/// Watches the clock, the calendar and the inbox; turns what matters into
/// proposals. Deliberately quiet: quiet hours, at most one drop-down every
/// 10 minutes, nothing repeated, and each routine can be switched off.
@MainActor
final class ProactiveEngine: ObservableObject {
    @Published private(set) var proposals: [Proposal] = []
    @Published var briefOn = Defaults.bool("proactive.brief", true) { didSet { Defaults.set("proactive.brief", briefOn) } }
    @Published var meetingsOn = Defaults.bool("proactive.meetings", true) { didSet { Defaults.set("proactive.meetings", meetingsOn) } }
    @Published var inboxOn = Defaults.bool("proactive.inbox", false) { didSet { Defaults.set("proactive.inbox", inboxOn) } }
    @Published var paused = Defaults.bool("proactive.paused", false) { didSet { Defaults.set("proactive.paused", paused) } }
    @Published var briefHour = UserDefaults.standard.object(forKey: "proactive.briefHour") as? Int ?? 8 {
        didSet { UserDefaults.standard.set(briefHour, forKey: "proactive.briefHour") }
    }
    @Published private(set) var briefRunning = false

    weak var backend: Backend?
    weak var calendar: CalendarStore?
    /// Drop a proposal out of the notch.
    var present: ((Proposal) -> Void)?
    /// Open the chat so the result of an action is visible.
    var openChat: (() -> Void)?

    private var timer: Timer?
    private var seen: Set<String> = Set(UserDefaults.standard.stringArray(forKey: "proactive.seen") ?? [])
    private var lastPresented = Date.distantPast
    private var lastInboxCheck = Date.distantPast
    private let store = opennotchDir("") + "/proposals.json"

    func start() {
        if let data = try? Data(contentsOf: URL(fileURLWithPath: store)),
           let saved = try? JSONDecoder().decode([Proposal].self, from: data) {
            proposals = saved.filter { $0.expires > Date() }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) { [weak self] in self?.tick() }
    }

    // MARK: tick

    private func tick() {
        prune()
        guard !paused, backend?.connected == true else { return }
        let now = Date()
        let hour = Calendar.current.component(.hour, from: now)
        let quiet = hour >= 22 || hour < 7
        if meetingsOn && !quiet { checkMeetings(now) }
        if briefOn && !quiet { checkBrief(now, force: false) }
        if inboxOn && (9..<20).contains(hour) && now.timeIntervalSince(lastInboxCheck) > 30 * 60 {
            lastInboxCheck = now
            checkInbox()
        }
    }

    private func checkMeetings(_ now: Date) {
        guard let cal = calendar, cal.eventsOK else { return }
        for e in cal.events(from: now.addingTimeInterval(7 * 60), to: now.addingTimeInterval(12 * 60)) {
            let id = "meeting:\(e.calendarItemIdentifier):\(Int(e.startDate.timeIntervalSince1970))"
            guard !seen.contains(id) else { continue }
            let mins = max(1, Int(e.startDate.timeIntervalSince(now) / 60))
            let people = (e.attendees ?? []).compactMap { $0.name }.filter { !$0.isEmpty }.prefix(6)
            let title = e.title ?? "Meeting"
            let link = Self.joinLink(e)
            add(Proposal(
                id: id, kind: .meeting,
                title: "\(title) in \(mins) min",
                detail: [QuickCapture.timeOnly(e.startDate), e.location, people.isEmpty ? nil : people.joined(separator: ", ")]
                    .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "),
                actionLabel: link != nil ? "Join" : "Prep me",
                prompt: "Prep me for my meeting “\(title)” at \(QuickCapture.timeOnly(e.startDate))"
                    + (people.isEmpty ? "" : " with \(people.joined(separator: ", "))")
                    + ". Search my recent email and documents for context about it and the people, then give me 3 short bullets and one question I should ask.",
                url: link, body: nil,
                expires: e.endDate), present: true)
        }
    }

    private func checkBrief(_ now: Date, force: Bool) {
        let cal = Calendar.current
        let day = TimerStore.dayKey(now)
        let id = "brief:\(day)"
        let hour = cal.component(.hour, from: now)
        // Within 3 hours after the brief time, once a day; if the Mac was asleep
        // at 8:00, you still get it when you open the lid at 9:15.
        guard !briefRunning, backend?.busy == false else { return }
        guard force || (!seen.contains(id) && hour >= briefHour && hour < briefHour + 3) else { return }
        briefRunning = true
        seen.insert(id); persistSeen()
        let prompt = briefPrompt(now)
        backend?.oneshot(prompt) { [weak self] result in
            guard let self else { return }
            self.briefRunning = false
            switch result {
            case .success(let text):
                self.add(Proposal(id: id, kind: .brief, title: "Your morning brief is ready",
                                  detail: String(SpeechText.clean(text).prefix(140)),
                                  actionLabel: "Open", prompt: nil, url: nil, body: text,
                                  expires: cal.startOfDay(for: now).addingTimeInterval(24 * 3600)), present: true)
            case .failure(let msg):
                AppLog.write("brief failed: \(msg)")
                self.seen.remove(id); self.persistSeen()           // try again next tick
            }
        }
    }

    private func briefPrompt(_ now: Date) -> String {
        var parts = ["Give me my morning brief for \(DateFormatter.localizedString(from: now, dateStyle: .full, timeStyle: .none))."]
        if let cal = calendar {
            let start = Calendar.current.startOfDay(for: now)
            let events = cal.events(from: now, to: start.addingTimeInterval(24 * 3600))
            parts.append(events.isEmpty ? "My calendar is clear today."
                : "Today's calendar:\n" + events.map { "- \(QuickCapture.timeOnly($0.startDate)) \($0.title ?? "Event")" }.joined(separator: "\n"))
            let due = cal.reminders.filter { r in
                guard let d = r.dueDateComponents?.date else { return false }
                return d < start.addingTimeInterval(24 * 3600)
            }
            if !due.isEmpty {
                parts.append("Reminders due today or overdue:\n" + due.prefix(10).map { "- \($0.title ?? "")" }.joined(separator: "\n"))
            }
        }
        parts.append("Check my unread email from the last day (use the Gmail tools) and tell me what needs a reply. "
                     + "Keep the whole brief under 150 words: first the schedule, then what needs me, then one suggestion for the day. "
                     + "Don't send or draft anything.")
        return parts.joined(separator: "\n\n")
    }

    private func checkInbox() {
        backend?.inboxNeedingReply { [weak self] emails in
            guard let self, let emails, !emails.isEmpty else { return }
            let fresh = emails.filter { !self.seen.contains("mail:\($0.id)") }
            guard !fresh.isEmpty else { return }
            fresh.forEach { self.seen.insert("mail:\($0.id)") }
            self.persistSeen()
            let names = fresh.prefix(3).map { Self.senderName($0.from) }
            let list = fresh.prefix(8).map { "- \($0.subject) — from \($0.from) (id \($0.id))" }.joined(separator: "\n")
            self.add(Proposal(
                id: "inbox:\(fresh.map(\.id).sorted().joined(separator: ","))", kind: .inbox,
                title: fresh.count == 1 ? "\(names[0]) may need a reply" : "\(fresh.count) emails may need a reply",
                detail: fresh.prefix(3).map { $0.subject }.joined(separator: " · "),
                actionLabel: "Draft replies",
                prompt: "These unread emails may need a reply:\n\(list)\n\nRead each one. For those that genuinely need a response, "
                    + "write a short reply in my voice and save it as a Gmail draft (gmail_draft). Do not send anything. "
                    + "Then list what you drafted and what you skipped.",
                url: nil, body: nil, expires: Date().addingTimeInterval(12 * 3600)), present: true)
        }
    }

    // MARK: proposals

    private func add(_ p: Proposal, present show: Bool) {
        guard !proposals.contains(where: { $0.id == p.id }) else { return }
        withAnimation(.spring(duration: 0.35, bounce: 0.1)) { proposals.insert(p, at: 0) }
        seen.insert(p.id); persistSeen()
        save()
        // One drop-down per 10 minutes at most; the rest wait quietly in "For you".
        if show, Date().timeIntervalSince(lastPresented) > 10 * 60 {
            lastPresented = Date()
            present?(p)
        }
    }

    func dismiss(_ p: Proposal) {
        withAnimation(.easeOut(duration: 0.2)) { proposals.removeAll { $0.id == p.id } }
        save()
    }

    /// The only place a proposal causes anything to happen — on a click.
    func act(_ p: Proposal) {
        if !(p.kind == .meeting && p.url != nil) { openChat?() }
        switch p.kind {
        case .brief:
            if let text = p.body { backend?.showLocalExchange(user: "Morning brief", reply: text) }
        case .meeting:
            if let u = p.url, let url = URL(string: u) { NSWorkspace.shared.open(url) }
            else if let prompt = p.prompt { backend?.send(prompt) }
        case .inbox:
            if let prompt = p.prompt { backend?.send(prompt) }
        }
        dismiss(p)
    }

    /// "Prep me" for a meeting that has a join link (secondary action).
    func prep(_ p: Proposal) {
        openChat?()
        if let prompt = p.prompt { backend?.send(prompt) }
    }

    /// Run the brief now (menu item) regardless of the time.
    func briefNow() {
        proposals.removeAll { $0.kind == .brief }
        checkBrief(Date(), force: true)
    }

    private func prune() {
        let n = proposals.count
        proposals.removeAll { $0.expires < Date() }
        if proposals.count != n { save() }
        if seen.count > 500 { seen = Set(seen.suffix(300)); persistSeen() }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(proposals) { try? data.write(to: URL(fileURLWithPath: store)) }
    }

    private func persistSeen() { UserDefaults.standard.set(Array(seen), forKey: "proactive.seen") }

    // MARK: helpers

    static func joinLink(_ e: EKEvent) -> String? {
        let hay = [e.url?.absoluteString, e.location, e.notes].compactMap { $0 }.joined(separator: " ")
        let rx = #"https://[^\s<>"]*(zoom\.us/j|meet\.google\.com|teams\.microsoft\.com|teams\.live\.com|webex\.com)[^\s<>"]*"#
        guard let r = hay.range(of: rx, options: .regularExpression) else { return nil }
        return String(hay[r])
    }

    static func senderName(_ from: String) -> String {
        if let lt = from.firstIndex(of: "<") {
            let n = from[..<lt].trimmingCharacters(in: CharacterSet(charactersIn: " \""))
            if !n.isEmpty { return n }
        }
        return from
    }
}

enum Defaults {
    static func bool(_ key: String, _ fallback: Bool) -> Bool {
        UserDefaults.standard.object(forKey: key) as? Bool ?? fallback
    }
    static func set(_ key: String, _ v: Bool) { UserDefaults.standard.set(v, forKey: key) }
}

// MARK: - Views

struct ProposalCard: View {
    let proposal: Proposal
    @ObservedObject var engine: ProactiveEngine
    var compact = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: proposal.icon)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(LinearGradient(colors: [Theme.glow[0], Theme.glow[2]],
                                                startPoint: .topLeading, endPoint: .bottomTrailing))
                .frame(width: 26, height: 26)
                .background(Circle().fill(.white.opacity(0.07)))
            VStack(alignment: .leading, spacing: 3) {
                Text(proposal.title).font(.system(size: 12.5, weight: .semibold)).lineLimit(1)
                if !proposal.detail.isEmpty {
                    Text(proposal.detail).font(.system(size: 11)).foregroundStyle(Theme.secondary)
                        .lineLimit(compact ? 1 : 2)
                }
            }
            Spacer(minLength: 6)
            HStack(spacing: 6) {
                if proposal.kind == .meeting && proposal.url != nil && !compact {
                    Button("Prep") { engine.prep(proposal) }.buttonStyle(.plain)
                        .font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.secondary)
                }
                Button { engine.act(proposal) } label: {
                    Text(proposal.actionLabel).font(.system(size: 11, weight: .semibold)).foregroundStyle(.white)
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background(Capsule().fill(Theme.userBubble))
                }
                .buttonStyle(.plain)
                Button { engine.dismiss(proposal) } label: {
                    Image(systemName: "xmark").font(.system(size: 9, weight: .bold)).foregroundStyle(Theme.tertiary)
                        .frame(width: 18, height: 18)
                }
                .buttonStyle(.plain)
                .help("Dismiss")
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 12).fill(.white.opacity(0.05)))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.hairline))
    }
}

/// "For you" — pending proposals at the top of the start screen.
struct ForYouSection: View {
    @ObservedObject var engine: ProactiveEngine

    var body: some View {
        if !engine.proposals.isEmpty || engine.briefRunning {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Text("FOR YOU").font(.system(size: 10, weight: .bold)).foregroundStyle(Theme.tertiary)
                    if engine.briefRunning {
                        ProgressView().controlSize(.mini)
                        Text("preparing your brief…").font(.system(size: 10)).foregroundStyle(Theme.tertiary)
                    }
                }
                ForEach(engine.proposals.prefix(3)) { p in
                    ProposalCard(proposal: p, engine: engine)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
        }
    }
}
