import AppKit
import EventKit
import SwiftUI

// "Today" at a glance — no typing: the next meeting counts down in the closed notch's ears in its last
// 15 minutes, and the chat's start screen shows a strip with the next event (Join), reminders due and
// one "Plan my day" tap. Refreshed by the 30 s app timer; the ear's minutes tick with a once-a-minute
// TimelineView (rule 7: nothing per-frame while the notch is closed).

struct UpcomingEvent: Equatable {
    let title: String
    let start: Date
    let end: Date
    let link: String?
    let calendar: String
}

/// Pure rules (checked in AgentChecks).
enum TodayLogic {
    static let earLead: TimeInterval = 15 * 60     // ears count down in the last 15 minutes
    static let earGrace: TimeInterval = 5 * 60     // …and say "now" until 5 minutes after the start

    /// The meeting for the ears: the first one starting within 15 minutes (or started under 5 minutes ago).
    static func earMeeting(_ events: [UpcomingEvent], now: Date) -> UpcomingEvent? {
        events.first { $0.end > now && $0.start <= now.addingTimeInterval(earLead) && $0.start >= now.addingTimeInterval(-earGrace) }
    }

    /// The next thing today for the strip: in progress (with a link) or the next to start.
    static func next(_ events: [UpcomingEvent], now: Date) -> UpcomingEvent? {
        events.first { $0.start <= now && $0.end > now && $0.link != nil } ?? events.first { $0.start > now }
    }

    /// "12m", "now", "1h 5m".
    static func countdown(to start: Date, now: Date) -> String {
        let s = start.timeIntervalSince(now)
        if s <= 30 { return "now" }
        let m = Int((s / 60).rounded(.up))
        return m < 60 ? "\(m)m" : "\(m / 60)h" + (m % 60 == 0 ? "" : " \(m % 60)m")
    }

    /// The strip's line about the rest of the day.
    static func restLine(eventsLeft: Int, remindersDue: Int) -> String {
        var bits: [String] = []
        if eventsLeft > 0 { bits.append("\(eventsLeft) more event\(eventsLeft == 1 ? "" : "s") today") }
        if remindersDue > 0 { bits.append("\(remindersDue) reminder\(remindersDue == 1 ? "" : "s") due") }
        return bits.isEmpty ? "Nothing else today" : bits.joined(separator: " · ")
    }
}

/// Today's events and due reminders, refreshed by the app's 30 s timer. Tiny on purpose (rule 8: observe it directly).
@MainActor
final class TodayModel: ObservableObject {
    static let shared = TodayModel()
    @Published private(set) var events: [UpcomingEvent] = []
    @Published private(set) var remindersDue = 0
    @Published private(set) var earMeeting: UpcomingEvent?

    weak var calendar: CalendarStore?

    func refresh(now: Date = Date()) {
        guard let cal = calendar, cal.eventsOK else {
            if !events.isEmpty || earMeeting != nil { events = []; earMeeting = nil }
            return
        }
        let end = Calendar.current.startOfDay(for: now).addingTimeInterval(24 * 3600)
        let list = cal.events(from: now.addingTimeInterval(-3 * 3600), to: end)
            .filter { !Self.declined($0) && $0.endDate > now }
            .map { UpcomingEvent(title: $0.title ?? "Event", start: $0.startDate, end: $0.endDate,
                                 link: ProactiveEngine.joinLink($0), calendar: $0.calendar?.title ?? "") }
        if list != events { events = list }
        let ear = TodayLogic.earMeeting(list, now: now)
        if ear != earMeeting { earMeeting = ear }
        let due = cal.remindersOK ? cal.reminders.filter { r in
            guard !r.isCompleted, let d = r.dueDateComponents?.date else { return false }
            return d < end
        }.count : 0
        if due != remindersDue { remindersDue = due }
    }

    /// Meetings the user said no to don't count down.
    static func declined(_ e: EKEvent) -> Bool {
        e.attendees?.first(where: \.isCurrentUser)?.participantStatus == .declined
    }

    func join(_ e: UpcomingEvent) {
        guard let s = e.link, let u = URL(string: s) else { return }
        NSWorkspace.shared.open(u)
    }
}

// MARK: - Views

/// Closed-notch ears while a meeting is close: 📅 title · countdown.
struct MeetingEars: View {
    let meeting: UpcomingEvent
    let right: Bool

    var body: some View {
        if right {
            TimelineView(.everyMinute) { ctx in
                Text(TodayLogic.countdown(to: meeting.start, now: ctx.date))
                    .font(.system(size: 12, weight: .bold, design: .rounded)).monospacedDigit()
                    .foregroundStyle(meeting.start.timeIntervalSince(ctx.date) < 120 ? Color.orange : .white)
                    .frame(maxWidth: .infinity)
            }
            .accessibilityLabel("\(meeting.title) starts in \(TodayLogic.countdown(to: meeting.start, now: Date()))")
        } else {
            HStack(spacing: 5) {
                Image(systemName: meeting.link != nil ? "video.fill" : "calendar")
                    .font(.system(size: 10, weight: .bold)).foregroundStyle(Color(red: 0.45, green: 0.75, blue: 1))
                Text(meeting.title).font(.system(size: 11, weight: .semibold)).lineLimit(1).foregroundStyle(.white.opacity(0.9))
            }
            .padding(.leading, 12).padding(.trailing, 8)
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }
}

/// The start screen's glance: next event (Join), what's left, and one tap to plan the day.
struct TodayStrip: View {
    @ObservedObject var today: TodayModel
    let plan: () -> Void

    private func subtitle(_ next: UpcomingEvent, now: Date) -> String {
        let when: String = next.start <= now ? "Now"
            : QuickCapture.timeOnly(next.start) + " · in " + TodayLogic.countdown(to: next.start, now: now)
        let later: Int = today.events.filter { $0.start > now }.count
        let left: Int = max(0, later - (next.start > now ? 1 : 0))
        return when + " · " + TodayLogic.restLine(eventsLeft: left, remindersDue: today.remindersDue)
    }

    var body: some View {
        let now = Date()
        if let next = TodayLogic.next(today.events, now: now) {
            HStack(spacing: 10) {
                Image(systemName: next.link != nil ? "video.fill" : "calendar")
                    .font(.system(size: 12, weight: .semibold)).foregroundStyle(Color(red: 0.45, green: 0.75, blue: 1))
                    .frame(width: 26, height: 26).background(Circle().fill(.white.opacity(0.07)))
                VStack(alignment: .leading, spacing: 1) {
                    Text(next.title).font(.system(size: 12.5, weight: .semibold)).lineLimit(1)
                    Text(subtitle(next, now: now))
                        .font(.system(size: 10.5)).foregroundStyle(Theme.secondary).lineLimit(1)
                }
                Spacer(minLength: 6)
                if next.link != nil {
                    PillButton(label: "Join", primary: true) { today.join(next) }
                        .environment(\.moduleAccent, Color(red: 0.45, green: 0.75, blue: 1))
                }
                PillButton(label: "Plan my day", primary: false) { plan() }
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 14).fill(.white.opacity(0.05)))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(Theme.hairline))
        } else if today.remindersDue > 0 {
            HStack(spacing: 10) {
                Image(systemName: "checklist").font(.system(size: 12, weight: .semibold)).foregroundStyle(.orange)
                Text(TodayLogic.restLine(eventsLeft: 0, remindersDue: today.remindersDue)).font(.system(size: 12, weight: .medium))
                Spacer()
                PillButton(label: "Plan my day", primary: false) { plan() }
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 14).fill(.white.opacity(0.05)))
        }
    }
}
