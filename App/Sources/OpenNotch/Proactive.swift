import AppKit
import EventKit
import SwiftUI

/// Something the notch suggests on its own. **Proposals never act by
/// themselves** — the primary action runs only when you click it (the
/// "propose, don't act" stance from plan_new_personal_agent.md).
struct Proposal: Identifiable, Codable, Equatable {
    enum Kind: String, Codable { case brief, meeting, inbox, memory, recap, week, notes, watch }
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
        case .memory: return "brain"
        case .recap: return "moon.stars.fill"
        case .week: return "chart.bar.fill"
        case .notes: return "waveform.badge.mic"
        case .watch: return "eye.fill"
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

    @Published var recapOn = Defaults.bool("proactive.recap", true) { didSet { Defaults.set("proactive.recap", recapOn) } }
    @Published var recapHour = UserDefaults.standard.object(forKey: "proactive.recapHour") as? Int ?? 18 {
        didSet { UserDefaults.standard.set(recapHour, forKey: "proactive.recapHour") }
    }
    @Published private(set) var recapRunning = false

    weak var backend: Backend?
    weak var calendar: CalendarStore?
    weak var screenTime: ScreenTimeTracker?
    /// Drop a proposal out of the notch.
    var present: ((Proposal) -> Void)?
    /// Open the chat so the result of an action is visible.
    var openChat: (() -> Void)?

    private var timer: Timer?
    private var seen: Set<String> = Set(UserDefaults.standard.stringArray(forKey: "proactive.seen") ?? [])
    private var lastPresented = Date.distantPast
    private var lastInboxCheck = Date.distantPast
    private var lastBriefFailure = Date.distantPast
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
        if Defaults.bool("proactive.recap", true) && !quiet { checkRecap(now, force: false) }   // Settings or menu
        if !quiet { checkWeek(now) }
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
        // No AI yet, or it failed recently: don't retry every minute (each try is a paid request).
        guard force || (backend?.aiConnected == true && now.timeIntervalSince(lastBriefFailure) > 30 * 60) else { return }
        briefRunning = true
        seen.insert(id); persistSeen()
        let prompt = briefPrompt(now)
        backend?.oneshotWithTools(prompt, tools: Self.briefTools) { [weak self] result in
            guard let self else { return }
            self.briefRunning = false
            switch result {
            case .success(let text):
                ValueLedger.shared.add(.briefs)
                self.add(Proposal(id: id, kind: .brief, title: "Your morning brief is ready",
                                  detail: String(SpeechText.clean(text).prefix(140)),
                                  actionLabel: "Open", prompt: nil, url: nil, body: text,
                                  expires: cal.startOfDay(for: now).addingTimeInterval(24 * 3600)), present: true)
            case .failure(let msg):
                AppLog.write("brief failed: \(msg)")
                self.lastBriefFailure = Date()
                self.seen.remove(id); self.persistSeen()           // try again in 30 min (still within the window)
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
        parts.append("Check my unread email from the last day with mail_recent (read any that look important with "
                     + "mail_read) and tell me what needs a reply. If you know my city (recall home-city), add the weather. "
                     + "Keep the whole brief under 150 words: first the schedule, then what needs me, then one suggestion for the day. "
                     + "Don't send or draft anything.")
        return parts.joined(separator: "\n\n")
    }

    // MARK: end of day

    /// Once a day after `recapHour`, when you're at the Mac: what you did, what's left, tomorrow.
    private func checkRecap(_ now: Date, force: Bool) {
        let id = "recap:\(TimerStore.dayKey(now))"
        let hour = Calendar.current.component(.hour, from: now)
        guard !recapRunning, backend?.busy == false, backend?.aiConnected == true else { return }
        guard force || (!seen.contains(id) && hour >= recapHour && hour < recapHour + 4
                        && Attention.shared.state == .available) else { return }
        recapRunning = true
        seen.insert(id); persistSeen()
        backend?.oneshotWithTools(recapPrompt(now), tools: Self.briefTools) { [weak self] result in
            guard let self else { return }
            self.recapRunning = false
            switch result {
            case .success(let text):
                ValueLedger.shared.add(.recaps)
                self.add(Proposal(id: id, kind: .recap, title: "Your day, wrapped up 🌙",
                                  detail: String(SpeechText.clean(text).prefix(140)),
                                  actionLabel: "Open", prompt: nil, url: nil, body: text,
                                  expires: Calendar.current.startOfDay(for: now).addingTimeInterval(30 * 3600)), present: true)
            case .failure(let msg):
                AppLog.write("recap failed: \(msg)")
                self.lastBriefFailure = Date()
            }
        }
    }

    private func recapPrompt(_ now: Date) -> String {
        var parts = ["Wrap up my day (\(DateFormatter.localizedString(from: now, dateStyle: .full, timeStyle: .none)))."]
        if let st = screenTime, !st.today.isEmpty {
            let top = st.today.sorted { $0.value > $1.value }.prefix(5)
                .map { "- \(st.names[$0.key] ?? $0.key): \(Int($0.value / 60)) min" }.joined(separator: "\n")
            parts.append("Where my time went today (apps):\n" + top)
        }
        let done = ValueLedger.shared.counts()
        let lines = ValueLogic.highlights(done)
        if !lines.isEmpty { parts.append("What you (\(Prefs.name)) did for me this week so far: " + lines.joined(separator: "; ") + ".") }
        parts.append("Check my reminders (reminders_list) for what's still open or overdue, and tomorrow's first events "
                     + "(calendar_events). Then write, in under 120 words: 1) what I spent the day on, 2) what's left, "
                     + "3) the first thing tomorrow, 4) one kind, practical suggestion. Warm, short, no headings. "
                     + "Don't create or send anything.")
        return parts.joined(separator: "\n\n")
    }

    func recapNow() {
        proposals.removeAll { $0.kind == .recap }
        checkRecap(Date(), force: true)
    }

    /// Friday afternoon (or later in the weekend): the shareable "my week with Ledge" card.
    private func checkWeek(_ now: Date) {
        let cal = Calendar.current
        let weekday = cal.component(.weekday, from: now)              // 1 = Sunday … 6 = Friday, 7 = Saturday
        let hour = cal.component(.hour, from: now)
        guard (weekday == 6 && hour >= 16) || weekday == 7 || weekday == 1 else { return }
        let week = ValueLogic.weekKey(now)
        let id = "week:\(week)"
        guard !seen.contains(id), Attention.shared.state == .available else { return }
        let counts = ValueLedger.shared.counts(week: week)
        let minutes = ValueLogic.minutes(counts)
        guard minutes >= 10 else { return }
        add(Proposal(id: id, kind: .week, title: "Your week with \(Prefs.name): \(ValueLogic.saved(minutes)) saved",
                     detail: ValueLogic.highlights(counts).prefix(2).joined(separator: " · ").capitalizedFirst,
                     actionLabel: "Share", prompt: nil, url: nil, body: week,
                     expires: now.addingTimeInterval(3 * 24 * 3600)), present: true)
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
                prompt: "These unread emails may need a reply:\n\(list)\n\nRead each one with mail_read. For those that genuinely "
                    + "need a response, write a short reply in my voice and open it as a draft with mail_draft (I review and send it "
                    + "myself). Do not send anything. Then list what you drafted and what you skipped.",
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
        if !(p.kind == .meeting && p.url != nil) && p.kind != .memory && p.kind != .week { openChat?() }
        switch p.kind {
        case .brief:
            if let text = p.body { backend?.showLocalExchange(user: "Morning brief", reply: text) }
        case .meeting:
            if let u = p.url, let url = URL(string: u) { NSWorkspace.shared.open(url) }
            else if let prompt = p.prompt { backend?.send(prompt) }
        case .inbox:
            if let prompt = p.prompt { backend?.send(prompt) }
        case .recap:
            if let text = p.body { backend?.showLocalExchange(user: "Wrap up my day", reply: text) }
        case .week:
            if let path = ValueLedger.shared.share(week: p.body ?? ValueLogic.weekKey(Date())) {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
                backend?.notice("Your week card is copied — paste it into a message or post. It's also saved in Finder.")
            }
        case .notes:
            if let text = p.body { backend?.showLocalExchange(user: "Notes from my call", reply: text) }
        case .watch:
            if let text = p.body { backend?.showLocalExchange(user: p.prompt ?? "Watcher", reply: text) }
        case .memory:
            for f in Self.facts(p) { MemoryStore.shared.remember(f.key, f.fact) }
            backend?.notice("Saved to memory — Settings › AI › Memory shows everything I remember.")
        }
        dismiss(p)
    }

    /// Facts the assistant noticed in a chat; saved only if you click Save.
    func proposeMemory(_ facts: [(key: String, fact: String)]) {
        guard !facts.isEmpty, let json = try? JSONSerialization.data(withJSONObject: facts.map { ["key": $0.key, "fact": $0.fact] }),
              let body = String(data: json, encoding: .utf8) else { return }
        proposals.removeAll { $0.kind == .memory }                 // newest suggestion replaces an unanswered one
        add(Proposal(id: "memory:\(Int(Date().timeIntervalSince1970))", kind: .memory,
                     title: facts.count == 1 ? "Remember this about you?" : "Remember \(facts.count) things about you?",
                     detail: facts.map(\.fact).joined(separator: " · "),
                     actionLabel: "Save", prompt: nil, url: nil, body: body,
                     expires: Date().addingTimeInterval(3 * 24 * 3600)), present: false)
    }

    static func facts(_ p: Proposal) -> [(key: String, fact: String)] {
        guard let b = p.body, let arr = try? JSONSerialization.jsonObject(with: Data(b.utf8)) as? [[String: String]] else { return [] }
        return arr.compactMap { d in d["key"].flatMap { k in d["fact"].map { (k, $0) } } }
    }

    /// A watcher finished: met (with what it found), blocked or expired. Always drops down (it's what was asked for).
    func proposeWatch(_ w: Watch, answer: String) {
        let title: String
        switch w.phase {
        case .met: title = "It happened: \(w.until)"
        case .blocked: title = "I can't keep watching \(w.what)"
        default: title = "Stopped watching \(w.what)"
        }
        let body = answer.components(separatedBy: "\n").filter { !$0.uppercased().hasPrefix("STATUS:") }.joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        lastPresented = .distantPast
        add(Proposal(id: "watch:\(w.id):\(w.checks)", kind: .watch, title: String(title.prefix(90)), detail: w.note ?? "",
                     actionLabel: "Show", prompt: "Watching: \(w.what)", url: nil,
                     body: (w.note ?? "") + (body.isEmpty ? "" : "\n\n" + body),
                     expires: Date().addingTimeInterval(7 * 24 * 3600)), present: true)
    }

    /// Call notes are ready (MeetingNotes).
    func proposeNotes(app: String, body: String) {
        add(Proposal(id: "notes:\(Int(Date().timeIntervalSince1970))", kind: .notes, title: "Notes from your \(app) call are ready",
                     detail: String(SpeechText.clean(body).prefix(140)), actionLabel: "Open", prompt: nil, url: nil, body: body,
                     expires: Date().addingTimeInterval(3 * 24 * 3600)), present: true)
    }

    /// What the morning brief may look at (read-only).
    static let briefTools: Set<String> = ["calendar_events", "reminders_list", "mail_recent", "mail_read", "weather", "recall"]

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
                    Text("For you").eyebrow()
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
