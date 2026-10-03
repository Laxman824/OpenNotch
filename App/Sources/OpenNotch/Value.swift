import AppKit
import SwiftUI

// What Ledge did for you, counted on this Mac (never sent anywhere), and a
// weekly card you can share: "This week Ledge drafted 14 replies, explained 6
// errors… ≈ 2 h saved". The time estimates are deliberately conservative.

enum ValueMetric: String, CaseIterable, Codable {
    case answers, toolCalls, drafts, explained, summaries, dictatedWords, eventsAndReminders,
         briefs, recaps, meetingNotes, nudgesTaken

    /// Minutes a single one saves you (dictation: per 100 words).
    var minutesSaved: Double {
        switch self {
        case .answers: return 1.5
        case .toolCalls: return 0.3
        case .drafts: return 4
        case .explained: return 3
        case .summaries: return 4
        case .dictatedWords: return 1.8          // per 100 words: speaking ~130 wpm vs typing ~40
        case .eventsAndReminders: return 1
        case .briefs, .recaps: return 5
        case .meetingNotes: return 15
        case .nudgesTaken: return 1
        }
    }

    func label(_ n: Int) -> String? {
        guard n > 0 else { return nil }
        switch self {
        case .answers: return "answered \(n) question\(n == 1 ? "" : "s")"
        case .toolCalls: return nil
        case .drafts: return "drafted \(n) email\(n == 1 ? "" : "s")"
        case .explained: return "explained \(n) error\(n == 1 ? "" : "s") or code snippet\(n == 1 ? "" : "s")"
        case .summaries: return "summarised \(n) page\(n == 1 ? "" : "s") or text\(n == 1 ? "" : "s")"
        case .dictatedWords: return "typed \(n.formatted()) word\(n == 1 ? "" : "s") I dictated"
        case .eventsAndReminders: return "added \(n) event\(n == 1 ? "" : "s") or reminder\(n == 1 ? "" : "s")"
        case .briefs: return "gave \(n) morning brief\(n == 1 ? "" : "s")"
        case .recaps: return "wrapped up \(n) day\(n == 1 ? "" : "s")"
        case .meetingNotes: return "took notes in \(n) call\(n == 1 ? "" : "s")"
        case .nudgesTaken: return nil
        }
    }
}

/// Pure maths (checked by `--checks`).
enum ValueLogic {
    static func minutes(_ counts: [ValueMetric: Int]) -> Double {
        counts.reduce(0) { sum, kv in
            sum + (kv.key == .dictatedWords ? Double(kv.value) / 100 : Double(kv.value)) * kv.key.minutesSaved
        }
    }

    static func saved(_ minutes: Double) -> String {
        if minutes < 1 { return "a little time" }
        if minutes < 60 { return "≈ \(Int(minutes.rounded())) min" }
        let h = minutes / 60
        return h < 10 ? String(format: "≈ %.1f h", h) : "≈ \(Int(h.rounded())) h"
    }

    /// The highlights for the card, biggest time-savers first, at most 4.
    static func highlights(_ counts: [ValueMetric: Int]) -> [String] {
        counts.sorted { a, b in
            let ma = (a.key == .dictatedWords ? Double(a.value) / 100 : Double(a.value)) * a.key.minutesSaved
            let mb = (b.key == .dictatedWords ? Double(b.value) / 100 : Double(b.value)) * b.key.minutesSaved
            return ma > mb
        }.compactMap { $0.key.label($0.value) }.prefix(4).map { $0 }
    }

    /// "2026-W40": weeks start on Monday.
    static func weekKey(_ d: Date) -> String {
        var cal = Calendar(identifier: .iso8601)
        cal.timeZone = .current
        let c = cal.dateComponents([.yearForWeekOfYear, .weekOfYear], from: d)
        return String(format: "%04d-W%02d", c.yearForWeekOfYear ?? 0, c.weekOfYear ?? 0)
    }
}

@MainActor
final class ValueLedger {
    static let shared = ValueLedger()
    private let key = "value.weeks"           // week → metric → count (last 12 weeks)

    func add(_ m: ValueMetric, _ n: Int = 1) {
        guard n > 0 else { return }
        var all = UserDefaults.standard.dictionary(forKey: key) as? [String: [String: Int]] ?? [:]
        let w = ValueLogic.weekKey(Date())
        all[w, default: [:]][m.rawValue, default: 0] += n
        if all.count > 12 { for old in all.keys.sorted().prefix(all.count - 12) { all[old] = nil } }
        UserDefaults.standard.set(all, forKey: key)
    }

    func counts(week: String = ValueLogic.weekKey(Date())) -> [ValueMetric: Int] {
        let all = UserDefaults.standard.dictionary(forKey: key) as? [String: [String: Int]] ?? [:]
        var out: [ValueMetric: Int] = [:]
        for (k, v) in all[week] ?? [:] { if let m = ValueMetric(rawValue: k) { out[m] = v } }
        return out
    }

    /// Count what the agent did, from its events (tool rows and finished turns).
    func observe(_ ev: [String: Any]) {
        switch ev["type"] as? String {
        case "tool" where ev["state"] as? String == "done":
            add(.toolCalls)
            switch ev["name"] as? String ?? "" {
            case "mail_draft": add(.drafts)
            case "create_event", "create_reminder": add(.eventsAndReminders)
            case "fetch_url", "active_tab": add(.summaries)
            default: break
            }
        case "done":
            if !(ev["text"] as? String ?? "").isEmpty { add(.answers) }
        default: break
        }
    }

    /// Render the card, copy it to the clipboard and save it next to OpenNotch's data
    /// (not Downloads — a protected folder would mean a permission prompt).
    func share(week: String = ValueLogic.weekKey(Date())) -> String? {
        let card = WeekCard(counts: counts(week: week))
        let r = ImageRenderer(content: card)
        r.scale = 2
        guard let img = r.nsImage, let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return nil }
        let url = URL(fileURLWithPath: opennotchDir("share")).appendingPathComponent("My week with \(Prefs.name) \(week).png")
        try? png.write(to: url)
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects([img])
        return url.path
    }
}

/// The shareable card (also shown in the "For you" proposal).
struct WeekCard: View {
    let counts: [ValueMetric: Int]

    var body: some View {
        let minutes = ValueLogic.minutes(counts)
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                PuffCanvas(size: 44, mood: .happy, palette: AvatarPalette.named(UserDefaults.standard.string(forKey: "avatarPalette") ?? "aurora"),
                           t: 1000.3, gaze: .zero, limbs: PerchPose.action(.wave, p: 0.5, t: 1000.3).limbs)
                    .frame(width: 44, height: 44)
                VStack(alignment: .leading, spacing: 1) {
                    Text("My week with \(Prefs.name)").font(Typo.title(17)).foregroundStyle(.white)
                    Text("OpenNotch · the AI in my MacBook's notch").font(.system(size: 11)).foregroundStyle(.white.opacity(0.6))
                }
            }
            Text(ValueLogic.saved(minutes) + " saved")
                .font(Typo.numeric(34, weight: .bold))
                .foregroundStyle(LinearGradient(colors: [Theme.glow[0], Theme.glow[2]], startPoint: .leading, endPoint: .trailing))
            VStack(alignment: .leading, spacing: 6) {
                ForEach(ValueLogic.highlights(counts), id: \.self) { line in
                    HStack(spacing: 7) {
                        Image(systemName: "checkmark.circle.fill").font(.system(size: 11)).foregroundStyle(.green)
                        Text(line.capitalizedFirst).font(.system(size: 13, weight: .medium)).foregroundStyle(.white.opacity(0.9))
                    }
                }
            }
            Text("Free & open source — github.com/Laxman824/OpenNotch")
                .font(.system(size: 10.5, weight: .medium)).foregroundStyle(.white.opacity(0.45))
        }
        .padding(22)
        .frame(width: 420, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 22)
                .fill(LinearGradient(colors: [Color(white: 0.09), Color(red: 0.10, green: 0.07, blue: 0.18)],
                                     startPoint: .topLeading, endPoint: .bottomTrailing)))
        .overlay(RoundedRectangle(cornerRadius: 22).strokeBorder(.white.opacity(0.08)))
    }
}
