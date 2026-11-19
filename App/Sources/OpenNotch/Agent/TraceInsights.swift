import Foundation

// The Developer view's maths, pure (checked in AgentChecks): where the time went, steps grouped by model pass,
// swimlanes, plain-language insights, axis ticks, day groups and the 7-day overview.

enum TraceInsights {
    // MARK: time split

    struct Breakdown: Equatable { var model = 0, tools = 0, waiting = 0, total = 0 }

    /// Union of intervals per lane (parallel tools don't double-count).
    static func union(_ spans: [(Int, Int)]) -> Int {
        let s = spans.filter { $0.1 > $0.0 }.sorted { $0.0 < $1.0 }
        var total = 0, curS = -1, curE = -1
        for (a, b) in s {
            if a > curE { total += max(0, curE - curS); curS = a; curE = b } else { curE = max(curE, b) }
        }
        return total + max(0, curE - curS)
    }

    static func breakdown(_ r: TurnRecord) -> Breakdown {
        func lane(_ kinds: Set<TraceEvent.Kind>) -> Int { union(r.events.filter { kinds.contains($0.kind) }.map { ($0.at, $0.at + $0.ms) }) }
        return Breakdown(model: lane([.llm, .decide]), tools: lane([.tool]), waiting: lane([.approval, .question]), total: r.ms)
    }

    // MARK: lanes (the minimap)

    enum Lane: String, CaseIterable { case you = "You", model = "Model", tools = "Tools" }

    static func lane(_ e: TraceEvent) -> Lane? {
        switch e.kind {
        case .approval, .question: return .you
        case .llm, .decide, .retry: return .model
        case .tool: return .tools
        case .route, .info: return nil
        }
    }

    // MARK: steps

    struct Step: Equatable {
        var title: String
        var header: Int?          // index of the llm event that opens it
        var children: [Int]       // indexes of what followed
    }

    /// "Setup" (routing/decider) then one step per model pass with the tools/approvals it led to.
    static func steps(_ r: TurnRecord) -> [Step] {
        var out: [Step] = []
        var setup: [Int] = []
        var n = 0
        for (i, e) in r.events.enumerated() {
            if e.kind == .llm {
                n += 1
                out.append(Step(title: "Step \(n)", header: i, children: []))
            } else if out.isEmpty {
                setup.append(i)
            } else {
                out[out.count - 1].children.append(i)
            }
        }
        if !setup.isEmpty { out.insert(Step(title: "Setup", header: nil, children: setup), at: 0) }
        return out
    }

    // MARK: insights

    struct Insight: Equatable {
        enum Tone: Equatable { case good, info, warn, bad }
        var tone: Tone
        var text: String
    }

    static func secs(_ ms: Int) -> String { String(format: "%.1f s", Double(ms) / 1000) }

    /// At most three, worst first.
    static func insights(_ r: TurnRecord) -> [Insight] {
        var out: [Insight] = []
        if r.end.hasPrefix("error") {
            out.append(Insight(tone: .bad, text: "It ended with an error: " + String(r.end.dropFirst(7).prefix(140))))
        } else if r.end == "limit" {
            out.append(Insight(tone: .bad, text: "It hit the tool limit for one message and stopped."))
        }
        for e in r.events where e.kind == .tool && !e.ok {
            let d = e.detail.lowercased()
            if d.contains("isn't allowed") || d.contains("access") || d.contains("permission") || d.contains("declined") {
                out.append(Insight(tone: .bad, text: "\(e.name) was blocked by a permission — turn it on in Settings › Permissions."))
            } else if d.contains("repeated") {
                out.append(Insight(tone: .warn, text: "The model repeated the same \(e.name) call; it was stopped so it couldn't loop."))
            } else if d.contains("invalid json") {
                out.append(Insight(tone: .warn, text: "The model sent broken arguments to \(e.name) and was asked to try again."))
            } else {
                out.append(Insight(tone: .bad, text: "\(e.name) failed: " + String(e.detail.prefix(120))))
            }
        }
        if r.events.contains(where: { $0.kind == .retry }) {
            out.append(Insight(tone: .warn, text: "The model hiccuped before answering and was retried once."))
        }
        let b = breakdown(r)
        if b.waiting >= 3000 {
            out.append(Insight(tone: .info, text: "\(secs(b.waiting)) of it was waiting for your OK."))
        }
        if let slowStart = r.events.filter({ $0.kind == .llm }).compactMap(\.first).max(), slowStart >= 3000 {
            out.append(Insight(tone: .warn, text: "The model took \(secs(slowStart)) to start answering — a faster model (Settings › AI) would feel snappier."))
        }
        if let slow = r.events.filter({ $0.kind == .tool && $0.ok }).max(by: { $0.ms < $1.ms }), slow.ms >= 3000 {
            out.append(Insight(tone: .info, text: "\(slow.name) was the slowest step (\(secs(slow.ms)))."))
        }
        let active = max(1, b.total - b.waiting)
        if r.ms >= 5000, Double(b.model) / Double(active) >= 0.7 {
            out.append(Insight(tone: .info, text: "Most of the time (\(Int(Double(b.model) * 100 / Double(active)))%) was the model thinking, not tools."))
        }
        let checked = r.events.filter(\.verified).count
        if checked > 0 { out.append(Insight(tone: .good, text: "\(checked) change\(checked == 1 ? " was" : "s were") read back to confirm it really happened.")) }
        let par = r.events.filter(\.parallel).count
        if par > 1 { out.append(Insight(tone: .good, text: "\(par) lookups ran side by side.")) }
        if out.isEmpty || (out.allSatisfy { $0.tone == .good } && r.ms < 5000) {
            out.insert(Insight(tone: .good, text: "Smooth — done in \(secs(r.ms))."), at: 0)
        }
        let rank: [Insight.Tone: Int] = [.bad: 0, .warn: 1, .info: 2, .good: 3]
        return Array(out.enumerated().sorted { (rank[$0.element.tone]!, $0.offset) < (rank[$1.element.tone]!, $1.offset) }.map(\.element).prefix(3))
    }

    // MARK: axis, days

    /// Up to ~6 round tick positions (ms) across a turn.
    static func ticks(total: Int) -> [Int] {
        guard total > 0 else { return [0] }
        let steps = [50, 100, 200, 250, 500, 1000, 2000, 2500, 5000, 10_000, 15_000, 30_000, 60_000, 120_000, 300_000]
        let step = steps.first { total / $0 <= 5 } ?? 600_000
        return Array(stride(from: 0, through: total, by: step))
    }

    /// The ticks that get a label at this width (≥ ~52 pt apart; always the first, the last if it fits).
    static func labelTicks(total: Int, width: Double, spacing: Double = 52) -> [Int] {
        let all = ticks(total: total)
        guard all.count > 1, width > 0, total > 0 else { return all }
        let gap = width * Double(all[1]) / Double(total)
        let every = max(1, Int((spacing / max(gap, 1)).rounded(.up)))
        return all.enumerated().filter { $0.offset % every == 0 }.map(\.element)
    }

    static func dayLabel(_ d: Date, now: Date, cal: Calendar = .current) -> String {
        if cal.isDate(d, inSameDayAs: now) { return "Today" }
        if let y = cal.date(byAdding: .day, value: -1, to: now), cal.isDate(d, inSameDayAs: y) { return "Yesterday" }
        let f = DateFormatter(); f.dateFormat = "EEEE d MMM"
        return f.string(from: d)
    }

    // MARK: overview

    struct ToolStat: Equatable { var name: String; var calls = 0; var failures = 0; var totalMs = 0 }
    struct ModelStat: Equatable { var name: String; var passes = 0; var medianFirst: Int? }
    struct DayStat: Equatable { var day: Date; var ok = 0; var problems = 0 }
    struct Overview: Equatable {
        var tasks = 0, problems = 0
        var medianMs = 0
        var medianFirst: Int?
        var days: [DayStat] = []
        var tools: [ToolStat] = []
        var models: [ModelStat] = []
        var okRate: Double { tasks == 0 ? 1 : Double(tasks - problems) / Double(tasks) }
    }

    static func median(_ xs: [Int]) -> Int? {
        guard !xs.isEmpty else { return nil }
        let s = xs.sorted()
        return s.count % 2 == 1 ? s[s.count / 2] : (s[s.count / 2 - 1] + s[s.count / 2]) / 2
    }

    static func overview(_ records: [TurnRecord], now: Date, days: Int = 7, cal: Calendar = .current) -> Overview {
        let start = cal.date(byAdding: .day, value: -(days - 1), to: cal.startOfDay(for: now)) ?? now
        let rs = records.filter { $0.started >= start }
        var o = Overview()
        o.tasks = rs.count
        o.problems = rs.filter(\.hadProblem).count
        o.medianMs = median(rs.map(\.ms)) ?? 0
        o.medianFirst = median(rs.flatMap { $0.events.filter { $0.kind == .llm }.compactMap(\.first) })
        o.days = (0..<days).compactMap { i in cal.date(byAdding: .day, value: i, to: start) }.map { d in
            let day = rs.filter { cal.isDate($0.started, inSameDayAs: d) }
            return DayStat(day: d, ok: day.filter { !$0.hadProblem }.count, problems: day.filter(\.hadProblem).count)
        }
        var tools: [String: ToolStat] = [:]
        var models: [String: (Int, [Int])] = [:]
        for r in rs {
            for e in r.events {
                if e.kind == .tool {
                    var t = tools[e.name] ?? ToolStat(name: e.name)
                    t.calls += 1; t.totalMs += e.ms; if !e.ok { t.failures += 1 }
                    tools[e.name] = t
                } else if e.kind == .llm {
                    var m = models[e.name] ?? (0, [])
                    m.0 += 1; if let f = e.first { m.1.append(f) }
                    models[e.name] = m
                }
            }
        }
        o.tools = tools.values.sorted { ($0.failures, $0.totalMs) > ($1.failures, $1.totalMs) }
        o.models = models.map { ModelStat(name: $0.key, passes: $0.value.0, medianFirst: median($0.value.1)) }.sorted { $0.passes > $1.passes }
        return o
    }
}
