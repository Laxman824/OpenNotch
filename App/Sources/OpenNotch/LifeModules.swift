import AppKit
import EventKit
import SwiftUI

// MARK: - Timers + hydration

enum NotchAlert: Equatable {
    case timerDone(String)
    case hydration
    case capture(String)
    case info(icon: String, text: String)
    case proposal(Proposal)
}

@MainActor
final class TimerStore: ObservableObject {
    enum Kind: String { case pomodoro = "Focus", countdown = "Timer", stopwatch = "Stopwatch" }

    @Published private(set) var kind: Kind?
    @Published private(set) var paused = false
    @Published private(set) var total: TimeInterval = 0
    @Published private(set) var elapsed: TimeInterval = 0
    @Published private(set) var onBreak = false
    @Published private(set) var cycles = 0
    @Published var focusMinutes = 25
    @Published var breakMinutes = 5
    @Published var countdownMinutes = 10

    @Published var hydrationOn = UserDefaults.standard.bool(forKey: "hydration.on") {
        didSet { UserDefaults.standard.set(hydrationOn, forKey: "hydration.on"); nextSip = Date().addingTimeInterval(interval) }
    }
    @Published var hydrationMinutes = max(15, UserDefaults.standard.integer(forKey: "hydration.minutes") == 0 ? 45
                                            : UserDefaults.standard.integer(forKey: "hydration.minutes")) {
        didSet { UserDefaults.standard.set(hydrationMinutes, forKey: "hydration.minutes"); nextSip = Date().addingTimeInterval(interval) }
    }
    @Published private(set) var glassesToday = 0
    @Published private(set) var nextSip = Date()

    var onAlert: ((NotchAlert) -> Void)?
    private var ticker: Timer?
    private var lastTick = Date()
    private var interval: TimeInterval { TimeInterval(hydrationMinutes * 60) }
    private var glassesKey: String { "hydration.glasses." + Self.dayKey(Date()) }

    nonisolated static func dayKey(_ d: Date) -> String {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; return f.string(from: d)
    }

    var running: Bool { kind != nil && !paused }
    var remaining: TimeInterval { kind == .stopwatch ? elapsed : max(0, total - elapsed) }
    var progress: Double { kind == .stopwatch || total == 0 ? 0 : min(1, elapsed / total) }

    /// Elapsed time right now, between the half-second ticks (smooth rings).
    func liveElapsed(_ now: Date = Date()) -> TimeInterval {
        running ? elapsed + max(0, now.timeIntervalSince(lastTick)) : elapsed
    }
    func liveProgress(_ now: Date = Date()) -> Double {
        kind == .stopwatch || total == 0 ? 0 : min(1, liveElapsed(now) / total)
    }

    /// What the closed notch shows in its ear, if anything.
    var earText: String? {
        guard let kind else { return nil }
        return (kind == .pomodoro && onBreak ? "☕ " : "") + Self.clock(remaining)
    }

    static func clock(_ t: TimeInterval) -> String {
        let s = Int(t.rounded(.down))
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60)
                         : String(format: "%d:%02d", s / 60, s % 60)
    }

    func start() {
        glassesToday = UserDefaults.standard.integer(forKey: glassesKey)
        nextSip = Date().addingTimeInterval(interval)
        ticker = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        RunLoop.main.add(ticker!, forMode: .common)
    }

    func startPomodoro() { begin(.pomodoro, minutes: focusMinutes); onBreak = false; cycles = 0 }
    func startCountdown() { begin(.countdown, minutes: countdownMinutes) }
    func startStopwatch() { begin(.stopwatch, minutes: 0) }
    func startCountdown(seconds: TimeInterval) { begin(.countdown, minutes: 0); total = seconds }
    func pauseResume() { paused.toggle(); lastTick = Date() }
    func reset() { kind = nil; paused = false; elapsed = 0; total = 0; onBreak = false }

    func drank() {
        glassesToday += 1
        UserDefaults.standard.set(glassesToday, forKey: glassesKey)
        nextSip = Date().addingTimeInterval(interval)
    }

    private func begin(_ k: Kind, minutes: Int) {
        kind = k
        paused = false
        elapsed = 0
        total = TimeInterval(minutes * 60)
        lastTick = Date()
    }

    private func tick() {
        let now = Date()
        let dt = now.timeIntervalSince(lastTick)
        lastTick = now
        if running {
            elapsed += dt
            if kind != .stopwatch && elapsed >= total { finished() }
        }
        // Hydration: only during waking hours, and not while the screen is asleep.
        if hydrationOn, now >= nextSip {
            let hour = Calendar.current.component(.hour, from: now)
            nextSip = now.addingTimeInterval(interval)
            if (8...22).contains(hour) { onAlert?(.hydration) }
        }
        let key = "hydration.glasses." + Self.dayKey(now)
        if key != glassesKey { glassesToday = UserDefaults.standard.integer(forKey: key) }
    }

    private func finished() {
        switch kind {
        case .pomodoro:
            if onBreak {
                onAlert?(.timerDone("Break's over — back to focus."))
                onBreak = false
                total = TimeInterval(focusMinutes * 60)
            } else {
                cycles += 1
                onAlert?(.timerDone("Focus session \(cycles) done — take \(breakMinutes) minutes."))
                onBreak = true
                total = TimeInterval(breakMinutes * 60)
            }
            elapsed = 0
        default:
            onAlert?(.timerDone("Timer finished."))
            reset()
        }
    }
}

struct TimersView: View {
    @ObservedObject var store: TimerStore

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(spacing: 12) {
                ZStack {
                    Circle().stroke(.white.opacity(0.08), lineWidth: 8)
                    Circle().trim(from: 0, to: store.kind == .stopwatch ? 1 : 1 - store.progress)
                        .stroke(AngularGradient(colors: store.onBreak ? [.green, .mint, .green] : Theme.glow, center: .center),
                                style: StrokeStyle(lineWidth: 8, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .animation(.linear(duration: 0.5), value: store.progress)
                    VStack(spacing: 2) {
                        Text(store.kind == nil ? "--:--" : TimerStore.clock(store.remaining))
                            .font(.system(size: 30, weight: .semibold, design: .rounded).monospacedDigit())
                        Text(store.kind.map { $0 == .pomodoro ? (store.onBreak ? "Break" : "Focus · \(store.cycles) done") : $0.rawValue } ?? "Ready")
                            .font(.system(size: 11)).foregroundStyle(Theme.secondary)
                    }
                }
                .frame(width: 150, height: 150)
                if store.kind == nil {
                    HStack(spacing: 6) {
                        PillButton(label: "Focus \(store.focusMinutes)m", icon: "brain.head.profile", primary: true) { store.startPomodoro() }
                    }
                    HStack(spacing: 6) {
                        PillButton(label: "\(store.countdownMinutes)m", icon: "timer") { store.startCountdown() }
                        PillButton(label: "Stopwatch", icon: "stopwatch") { store.startStopwatch() }
                    }
                } else {
                    HStack(spacing: 8) {
                        PillButton(label: store.paused ? "Resume" : "Pause", icon: store.paused ? "play.fill" : "pause.fill",
                                   primary: true) { store.pauseResume() }
                        PillButton(label: "Reset", icon: "arrow.counterclockwise") { store.reset() }
                    }
                }
            }
            .frame(maxWidth: .infinity)

            VStack(alignment: .leading, spacing: 12) {
                Text("Durations").font(.system(size: 12, weight: .semibold))
                Stepper("Focus  \(store.focusMinutes) min", value: $store.focusMinutes, in: 5...90, step: 5)
                Stepper("Break  \(store.breakMinutes) min", value: $store.breakMinutes, in: 1...30)
                Stepper("Timer  \(store.countdownMinutes) min", value: $store.countdownMinutes, in: 1...180)
                Divider().overlay(Theme.hairline)
                HStack {
                    Image(systemName: "drop.fill").foregroundStyle(.cyan)
                    Text("Hydration").font(.system(size: 12, weight: .semibold))
                    Spacer()
                    Toggle("", isOn: $store.hydrationOn).toggleStyle(.switch).controlSize(.mini)
                }
                Stepper("Every \(store.hydrationMinutes) min", value: $store.hydrationMinutes, in: 15...180, step: 15)
                    .disabled(!store.hydrationOn)
                HStack(spacing: 3) {
                    ForEach(0..<8, id: \.self) { i in
                        Image(systemName: i < store.glassesToday ? "drop.fill" : "drop")
                            .foregroundStyle(i < store.glassesToday ? Color.cyan : Theme.tertiary)
                            .font(.system(size: 12))
                    }
                    Spacer()
                    Button("+1 glass") { store.drank() }.buttonStyle(.plain)
                        .font(.system(size: 11, weight: .semibold)).foregroundStyle(.cyan)
                }
                if store.hydrationOn {
                    Text("Next reminder \(relativeTime(store.nextSip))").font(.system(size: 10)).foregroundStyle(Theme.tertiary)
                }
            }
            .font(.system(size: 12))
            .frame(width: 240)
        }
        .padding(18)
    }
}

/// The animated alert that drops out of the notch (hydration / timer / capture).
struct AlertPeek: View {
    let alert: NotchAlert
    @EnvironmentObject var hub: Hub
    @ObservedObject var backend: Backend
    @ObservedObject var notch: NotchController
    var drank: () -> Void
    @State private var fill: CGFloat = 0
    @State private var wave: Double = 0

    var body: some View {
        VStack(spacing: 0) {
            Spacer().frame(height: notch.notchSize.height + 4)
            HStack(spacing: 12) {
                switch alert {
                case .hydration:
                    ZStack(alignment: .bottom) {                          // a glass filling up
                        RoundedRectangle(cornerRadius: 5).stroke(.white.opacity(0.5), lineWidth: 1.5)
                        WaterShape(level: fill, phase: wave)
                            .fill(LinearGradient(colors: [.cyan, .blue], startPoint: .top, endPoint: .bottom))
                            .clipShape(RoundedRectangle(cornerRadius: 5))
                    }
                    .frame(width: 22, height: 30)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Time for some water").font(.system(size: 13, weight: .semibold))
                        Text("Tap Done once you've had a glass 💧").font(.system(size: 11)).foregroundStyle(Theme.secondary)
                    }
                    Spacer()
                    PillButton(label: "Done", icon: "checkmark", primary: true) { drank(); notch.collapse() }
                case .timerDone(let msg):
                    AssistantFace(size: 30, backend: backend, tracksCursor: false)
                    Text(msg).font(.system(size: 13, weight: .semibold))
                    Spacer()
                case let .proposal(p):
                    ProposalCard(proposal: p, engine: hub.proactive, compact: true)
                        .padding(.horizontal, -8)
                case let .info(icon, text):
                    Image(systemName: icon).font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(LinearGradient(colors: [Theme.glow[0], Theme.glow[2]],
                                                        startPoint: .topLeading, endPoint: .bottomTrailing))
                        .symbolEffect(.variableColor.iterative)
                    Text(text).font(.system(size: 13, weight: .semibold))
                    Spacer()
                case .capture(let path):
                    if let img = NSImage(contentsOfFile: path) {
                        Image(nsImage: img).resizable().aspectRatio(contentMode: .fill)
                            .frame(width: 54, height: 34).clipShape(RoundedRectangle(cornerRadius: 5))
                    }
                    Text("Screenshot saved").font(.system(size: 13, weight: .semibold))
                    Spacer()
                    PillButton(label: "Edit", icon: "crop") { notch.expand(pinned: true) }
                }
            }
            .padding(.horizontal, 18)
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 1.6)) { fill = 0.8 }
            withAnimation(.linear(duration: 1.2).repeatForever(autoreverses: false)) { wave = .pi * 2 }
        }
    }
}

struct WaterShape: Shape {
    var level: CGFloat
    var phase: Double
    var animatableData: AnimatablePair<CGFloat, Double> {
        get { .init(level, phase) }
        set { level = newValue.first; phase = newValue.second }
    }

    func path(in r: CGRect) -> Path {
        var p = Path()
        let y0 = r.maxY - r.height * level
        p.move(to: CGPoint(x: r.minX, y: y0))
        for x in stride(from: r.minX, through: r.maxX, by: 1) {
            let rel = Double((x - r.minX) / r.width)
            p.addLine(to: CGPoint(x: x, y: y0 + CGFloat(sin(rel * .pi * 2 + phase)) * 2))
        }
        p.addLine(to: CGPoint(x: r.maxX, y: r.maxY))
        p.addLine(to: CGPoint(x: r.minX, y: r.maxY))
        p.closeSubpath()
        return p
    }
}

// MARK: - Calendar + reminders

@MainActor
final class CalendarStore: ObservableObject {
    let store = EKEventStore()
    @Published private(set) var eventsOK = EKEventStore.authorizationStatus(for: .event) == .fullAccess
    @Published private(set) var remindersOK = EKEventStore.authorizationStatus(for: .reminder) == .fullAccess
    @Published private(set) var days: [(Date, [EKEvent])] = []
    @Published private(set) var reminders: [EKReminder] = []

    /// Asks for Calendars, then Reminders (one dialog at a time). `done` on main.
    /// Callbacks hop with GCD, per the no-crash rules (claude_session_opennotch.md §5).
    func requestAccess(_ done: (() -> Void)? = nil) {
        store.requestFullAccessToEvents { @Sendable ok, _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.eventsOK = ok
                    self.store.requestFullAccessToReminders { @Sendable ok2, _ in
                        DispatchQueue.main.async {
                            MainActor.assumeIsolated {
                                self.remindersOK = ok2
                                self.reload()
                                done?()
                            }
                        }
                    }
                }
            }
        }
    }

    func reload() {
        if eventsOK {
            let cal = Calendar.current
            let start = cal.startOfDay(for: Date())
            let end = cal.date(byAdding: .day, value: 7, to: start)!
            let events = store.events(matching: store.predicateForEvents(withStart: start, end: end, calendars: nil))
                .sorted { $0.startDate < $1.startDate }
            days = (0..<7).map { i -> (Date, [EKEvent]) in
                let d = cal.date(byAdding: .day, value: i, to: start)!
                return (d, events.filter { cal.isDate($0.startDate, inSameDayAs: d) })
            }
        }
        if remindersOK {
            let pred = store.predicateForIncompleteReminders(withDueDateStarting: nil, ending: nil, calendars: nil)
            store.fetchReminders(matching: pred) { @Sendable rs in
                let sorted = (rs ?? []).sorted {
                    ($0.dueDateComponents?.date ?? .distantFuture) < ($1.dueDateComponents?.date ?? .distantFuture)
                }
                let top = Array(sorted.prefix(40))
                DispatchQueue.main.async { MainActor.assumeIsolated { self.reminders = top } }
            }
        }
    }

    func addReminder(_ title: String, today: Bool) {
        guard remindersOK, let cal = store.defaultCalendarForNewReminders() else { return }
        let r = EKReminder(eventStore: store)
        r.title = title
        r.calendar = cal
        if today {
            r.dueDateComponents = Calendar.current.dateComponents([.year, .month, .day], from: Date())
        }
        try? store.save(r, commit: true)
        reload()
    }

    /// Quick-capture reminder. Date-only dues become all-day. Returns the item id.
    @discardableResult
    func addReminder(_ title: String, due: Date?, timed: Bool) -> String? {
        guard remindersOK, let cal = store.defaultCalendarForNewReminders() else { return nil }
        let r = EKReminder(eventStore: store)
        r.title = title
        r.calendar = cal
        if let due {
            let comps: Set<Calendar.Component> = timed ? [.year, .month, .day, .hour, .minute] : [.year, .month, .day]
            r.dueDateComponents = Calendar.current.dateComponents(comps, from: due)
            if timed { r.addAlarm(EKAlarm(absoluteDate: due)) }       // actually remind, not just list
        }
        do { try store.save(r, commit: true) } catch { AppLog.write("reminder save failed: \(error)"); return nil }
        reload()
        return r.calendarItemIdentifier
    }

    @discardableResult
    func addEvent(_ title: String, start: Date, end: Date) -> String? {
        guard eventsOK, let cal = store.defaultCalendarForNewEvents else { return nil }
        let e = EKEvent(eventStore: store)
        e.title = title
        e.startDate = start
        e.endDate = max(end, start.addingTimeInterval(5 * 60))
        e.calendar = cal
        e.addAlarm(EKAlarm(relativeOffset: -10 * 60))
        do { try store.save(e, span: .thisEvent, commit: true) } catch { AppLog.write("event save failed: \(error)"); return nil }
        reload()
        return e.calendarItemIdentifier
    }

    /// Undo for quick capture.
    func deleteItem(_ id: String) {
        guard let item = store.calendarItem(withIdentifier: id) else { return }
        if let r = item as? EKReminder { try? store.remove(r, commit: true) }
        if let e = item as? EKEvent { try? store.remove(e, span: .thisEvent, commit: true) }
        reload()
    }

    /// Events in a window, for the proactive layer (meeting heads-up, brief).
    func events(from start: Date, to end: Date) -> [EKEvent] {
        guard eventsOK else { return [] }
        return store.events(matching: store.predicateForEvents(withStart: start, end: end, calendars: nil))
            .filter { !$0.isAllDay }
            .sorted { $0.startDate < $1.startDate }
    }

    /// Refresh the permission flags (the user may have granted in Settings).
    func refreshAuth() {
        eventsOK = EKEventStore.authorizationStatus(for: .event) == .fullAccess
        remindersOK = EKEventStore.authorizationStatus(for: .reminder) == .fullAccess
    }

    func complete(_ r: EKReminder) {
        r.isCompleted = true
        try? store.save(r, commit: true)
        withAnimation { reminders.removeAll { $0.calendarItemIdentifier == r.calendarItemIdentifier } }
    }
}

struct CalendarView: View {
    @ObservedObject var store: CalendarStore
    @ObservedObject var notch: NotchController
    @State private var newReminder = ""
    @State private var dueToday = true

    var body: some View {
        if !store.eventsOK && !store.remindersOK {
            VStack(spacing: 14) {
                Image(systemName: "calendar.badge.lock").font(.system(size: 30)).foregroundStyle(Theme.secondary)
                Text("See your week and reminders here").font(.system(size: 14, weight: .semibold))
                Text("OpenNotch reads Calendar and Reminders locally through macOS. Nothing leaves your Mac.")
                    .font(.system(size: 12)).foregroundStyle(Theme.secondary).multilineTextAlignment(.center)
                PillButton(label: "Allow access", icon: "checkmark.shield", primary: true) {
                    notch.yieldForSystemPrompt("Calendars & Reminders")
                    store.requestAccess()
                }
            }
            .padding(30).frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            HStack(alignment: .top, spacing: 12) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(store.days, id: \.0) { day, events in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(dayTitle(day)).font(.system(size: 11, weight: .bold))
                                    .foregroundStyle(Calendar.current.isDateInToday(day) ? Theme.glow[0] : Theme.secondary)
                                if events.isEmpty {
                                    Text("Nothing scheduled").font(.system(size: 11)).foregroundStyle(Theme.tertiary)
                                }
                                ForEach(events, id: \.eventIdentifier) { e in
                                    HStack(spacing: 8) {
                                        RoundedRectangle(cornerRadius: 2).fill(Color(nsColor: e.calendar.color)).frame(width: 3)
                                        VStack(alignment: .leading, spacing: 1) {
                                            Text(e.title ?? "Untitled").font(.system(size: 12, weight: .medium)).lineLimit(1)
                                            Text(e.isAllDay ? "All day" : timeRange(e))
                                                .font(.system(size: 10).monospacedDigit()).foregroundStyle(Theme.tertiary)
                                        }
                                    }
                                    .frame(height: 30)
                                }
                            }
                        }
                    }
                    .padding(14)
                }
                .frame(maxWidth: .infinity)

                VStack(alignment: .leading, spacing: 8) {
                    Text("Reminders").font(.system(size: 13, weight: .semibold))
                    HStack(spacing: 6) {
                        TextField("New reminder", text: $newReminder).textFieldStyle(.plain).font(.system(size: 12))
                            .onSubmit(add)
                        Button { dueToday.toggle() } label: {
                            Text("Today").font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(dueToday ? .white : Theme.tertiary)
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(Capsule().fill(dueToday ? Color.orange.opacity(0.6) : .white.opacity(0.06)))
                        }.buttonStyle(.plain)
                    }
                    .padding(8)
                    .background(RoundedRectangle(cornerRadius: 9).fill(.white.opacity(0.06)))
                    ScrollView {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(store.reminders, id: \.calendarItemIdentifier) { r in
                                HStack(alignment: .top, spacing: 8) {
                                    Button { store.complete(r) } label: {
                                        Image(systemName: "circle").font(.system(size: 13)).foregroundStyle(Theme.secondary)
                                    }.buttonStyle(.plain)
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(r.title ?? "").font(.system(size: 12)).lineLimit(2)
                                        if let d = r.dueDateComponents?.date {
                                            Text(d, style: .date).font(.system(size: 10))
                                                .foregroundStyle(d < Date() ? .orange : Theme.tertiary)
                                        }
                                    }
                                }
                            }
                            if store.reminders.isEmpty {
                                Text("All clear ✨").font(.system(size: 11)).foregroundStyle(Theme.tertiary)
                            }
                        }
                    }
                }
                .frame(width: 230)
                .padding(.vertical, 14).padding(.trailing, 14)
            }
            .onAppear { store.reload() }
        }
    }

    private func add() {
        let t = newReminder.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return }
        store.addReminder(t, today: dueToday)
        newReminder = ""
    }

    private func dayTitle(_ d: Date) -> String {
        if Calendar.current.isDateInToday(d) { return "TODAY" }
        if Calendar.current.isDateInTomorrow(d) { return "TOMORROW" }
        let f = DateFormatter(); f.dateFormat = "EEEE d MMM"; return f.string(from: d).uppercased()
    }

    private func timeRange(_ e: EKEvent) -> String {
        let f = DateFormatter(); f.timeStyle = .short
        return "\(f.string(from: e.startDate)) – \(f.string(from: e.endDate))"
    }
}

// MARK: - Music

struct MediaView: View {
    @ObservedObject var backend: Backend

    var body: some View {
        let np = backend.nowPlaying
        VStack(spacing: 18) {
            HStack(spacing: 16) {
                ZStack {
                    RoundedRectangle(cornerRadius: 14)
                        .fill(LinearGradient(colors: [Theme.glow[1], Theme.glow[2]], startPoint: .topLeading, endPoint: .bottomTrailing))
                    if let app = np.app {
                        appIcon(forPath: app == "Spotify" ? "/Applications/Spotify.app" : "/System/Applications/Music.app", size: 56)
                            .resizable().frame(width: 56, height: 56)
                    } else {
                        Image(systemName: "music.note").font(.system(size: 34)).foregroundStyle(.white)
                    }
                }
                .frame(width: 96, height: 96)
                .overlay(alignment: .bottomTrailing) {
                    if np.playing { EqualizerBars(color: .white).frame(width: 18, height: 14).padding(8) }
                }
                VStack(alignment: .leading, spacing: 5) {
                    Text(np.track.isEmpty ? "Nothing playing" : np.track)
                        .font(.system(size: 17, weight: .semibold, design: .rounded)).lineLimit(2)
                    Text([np.artist, np.album].filter { !$0.isEmpty }.joined(separator: " — "))
                        .font(.system(size: 12)).foregroundStyle(Theme.secondary).lineLimit(1)
                    Text(np.app.map { "on \($0)" } ?? "Spotify or Music")
                        .font(.system(size: 11)).foregroundStyle(Theme.tertiary)
                }
                Spacer()
            }
            HStack(spacing: 30) {
                mediaButton("backward.fill", 18) { backend.media("previous") }
                mediaButton(np.playing ? "pause.fill" : "play.fill", 26) { backend.media(np.playing ? "pause" : "play") }
                mediaButton("forward.fill", 18) { backend.media("next") }
            }
            Text("Or just say it: “play some music”, “next song”, “pause”, “volume 30”.")
                .font(.system(size: 11)).foregroundStyle(Theme.tertiary)
        }
        .padding(24)
        .task {
            while !Task.isCancelled {
                await backend.refreshNowPlaying()
                try? await Task.sleep(nanoseconds: 2_500_000_000)
            }
        }
    }

    private func mediaButton(_ icon: String, _ size: CGFloat, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: size, weight: .semibold))
                .frame(width: 54, height: 54)
                .background(Circle().fill(.white.opacity(0.08)))
        }
        .buttonStyle(HoverLift())
    }
}

/// Little bouncing bars for "music is playing".
struct EqualizerBars: View {
    var color: Color = .white
    @Environment(\.notchContentVisible) private var visible
    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !visible)) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            HStack(alignment: .bottom, spacing: 2) {
                ForEach(0..<4, id: \.self) { i in
                    let h = 0.3 + 0.7 * abs(sin(t * (3.1 + Double(i) * 1.3) + Double(i)))
                    Capsule().fill(color).frame(width: 2.5).frame(maxHeight: .infinity, alignment: .bottom)
                        .scaleEffect(y: h, anchor: .bottom)
                }
            }
        }
    }
}
