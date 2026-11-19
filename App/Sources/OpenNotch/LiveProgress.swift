import AppKit
import SwiftUI

// What the assistant is doing right now, in the chat: a live card instead of a grey "Fetching…" line.
// Phase in plain words (Getting started → Thinking it through → Checking the calendar · next 3 days → Reading what came
// back → Writing the answer, or Waiting for your OK), the steps so far as a checklist (spinner → ✓ past tense + time),
// elapsed time, and a gentle hint when a model is slow. Animation = SF Symbol effects only, paused when the notch is
// hidden (rule 7); the clock ticks once a second.

/// Pure rules (checked in AgentChecks).
enum ProgressLogic {
    enum Phase: Equatable { case starting, thinking, reasoning, tool(String), reading, approval, question }

    /// What's happening, from the turn's state.
    static func phase(elapsed: TimeInterval, approval: Bool, question: Bool, running: [String], hadTools: Bool,
                      reasoningLive: Bool) -> Phase {
        if approval { return .approval }
        if question { return .question }
        if let v = running.last { return .tool(v) }
        if reasoningLive { return .reasoning }
        if hadTools { return .reading }
        return elapsed < 1.5 ? .starting : .thinking
    }

    static func title(_ p: Phase, running: Int = 1) -> String {
        switch p {
        case .starting: return "Getting started"
        case .thinking: return "Thinking"
        case .reasoning: return "Thinking it through"
        case .tool(let v): return running > 1 ? "\(v) · and \(running - 1) more at once" : v
        case .reading: return "Reading what came back"
        case .approval: return "Waiting for your OK"
        case .question: return "Waiting for your answer"
        }
    }

    static func icon(_ p: Phase) -> String {
        switch p {
        case .starting, .thinking, .reasoning: return "sparkles"
        case .tool(let v): return toolSymbol(v)
        case .reading: return "text.magnifyingglass"
        case .approval: return "hand.raised.fill"
        case .question: return "questionmark.bubble.fill"
        }
    }

    private static let irregular: [String: String] = [
        "making": "made", "writing": "wrote", "reading": "read", "running": "ran", "sending": "sent", "finding": "found",
        "getting": "got", "taking": "took", "thinking": "thought", "keeping": "kept", "setting": "set", "putting": "put",
        "leaving": "left", "bringing": "brought", "buying": "bought", "building": "built", "choosing": "chose",
        "giving": "gave", "seeing": "saw", "telling": "told", "understanding": "understood", "using": "used",
        "closing": "closed", "changing": "changed", "moving": "moved", "removing": "removed", "sharing": "shared",
        "saving": "saved", "creating": "created", "preparing": "prepared", "scheduling": "scheduled", "summarising": "summarised",
        "summarizing": "summarized", "translating": "translated", "dictating": "dictated", "comparing": "compared",
        "typing": "typed", "pasting": "pasted", "starting": "started", "stopping": "stopped", "planning": "planned",
    ]

    /// "Checking the calendar" → "Checked the calendar" (first word only; anything else is left alone).
    static func past(_ verb: String) -> String {
        let parts = verb.split(separator: " ", maxSplits: 1).map(String.init)
        guard let first = parts.first, first.lowercased().hasSuffix("ing"), first.count > 4 else { return verb }
        let low = first.lowercased()
        var p = irregular[low] ?? String(low.dropLast(3)) + "ed"
        if first.first?.isUppercase == true { p = p.prefix(1).uppercased() + p.dropFirst() }
        return parts.count > 1 ? p + " " + parts[1] : p
    }

    /// The last bit of live reasoning, one tidy line (≤ 110 chars, from a word start).
    static func tail(_ text: String, max: Int = 110) -> String {
        let flat = text.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces)
        guard flat.count > max else { return flat }
        let cut = String(flat.suffix(max))
        if let sp = cut.firstIndex(of: " ") { return "…" + cut[cut.index(after: sp)...] }
        return "…" + cut
    }

    /// Say something reassuring when it's slow, but only while the model itself is the wait.
    static func slowHint(_ p: Phase, elapsed: TimeInterval) -> String? {
        switch p {
        case .thinking, .reasoning, .reading, .starting:
            return elapsed >= 12 ? "Still working — some models take a while to start. Details shows where the time goes." : nil
        case .tool:
            return elapsed >= 20 ? "This step is taking longer than usual." : nil
        default: return nil
        }
    }

    static func duration(_ s: TimeInterval) -> String { s < 1 ? "\(Int(s * 1000)) ms" : String(format: "%.1f s", s) }
}

struct LiveProgressCard: View {
    @ObservedObject var backend: Backend
    let steps: [Item]                    // this turn's tool and thinking rows
    @Environment(\.notchContentVisible) private var visible

    private var tools: [Item] { steps.filter { if case .tool = $0.kind { return true }; return false } }
    private var running: [String] {
        tools.compactMap { if case let .tool(state, _, verb, _, _) = $0.kind, state == "running" { return verb.isEmpty ? "Working" : verb }; return nil }
    }
    private var reasoning: Item? { steps.last { $0.kind == .thinking && $0.streaming } }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { ctx in
            let elapsed = backend.turnStarted.map { ctx.date.timeIntervalSince($0) } ?? 0
            let p = ProgressLogic.phase(elapsed: elapsed, approval: !backend.approvals.isEmpty, question: backend.question != nil,
                                        running: running, hadTools: !tools.isEmpty, reasoningLive: reasoning != nil)
            VStack(alignment: .leading, spacing: 9) {
                header(p, elapsed: elapsed)
                if let r = reasoning, !r.text.isEmpty {
                    Text(ProgressLogic.tail(r.text)).font(.system(size: 11).italic()).foregroundStyle(Theme.tertiary).lineLimit(1)
                        .padding(.leading, 30)
                }
                if !tools.isEmpty { checklist(now: ctx.date) }
                if let hint = ProgressLogic.slowHint(p, elapsed: elapsed) {
                    HStack(spacing: 8) {
                        Image(systemName: "hourglass").font(.system(size: 10))
                        Text(hint).font(.system(size: 10.5)).fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 4)
                        Button("Stop") { backend.stop() }.buttonStyle(.plain).font(.system(size: 10.5, weight: .semibold))
                            .foregroundStyle(Theme.secondary).help("Stop (⌘.)")
                    }
                    .foregroundStyle(Theme.tertiary)
                    .padding(.leading, 30)
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 10)
            .background(RoundedRectangle(cornerRadius: 14).fill(.white.opacity(0.045)))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(tint(p).opacity(0.28), lineWidth: 1))
            .animation(.spring(duration: 0.3), value: tools.count)
            .animation(.easeOut(duration: 0.2), value: p)
        }
        .transition(.opacity.combined(with: .move(edge: .bottom)))
    }

    private func tint(_ p: ProgressLogic.Phase) -> Color {
        switch p {
        case .approval, .question: return .orange
        case .tool: return Theme.glow[0]
        default: return Theme.glow[1]
        }
    }

    private func header(_ p: ProgressLogic.Phase, elapsed: TimeInterval) -> some View {
        HStack(spacing: 8) {
            AssistantFace(size: 22, backend: backend, tracksCursor: false)
            Image(systemName: ProgressLogic.icon(p))
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(tint(p))
                .symbolEffect(.variableColor.iterative.dimInactiveLayers, options: .repeating, isActive: visible && p != .approval)
                .symbolEffect(.pulse, options: .repeating, isActive: visible && (p == .approval || p == .question))
                .contentTransition(.symbolEffect(.replace))
            Text(ProgressLogic.title(p, running: running.count))
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(p == .approval || p == .question ? Color.orange : .white.opacity(0.9))
                .lineLimit(1)
                .contentTransition(.opacity)
            Spacer(minLength: 6)
            Text(ProgressLogic.duration(elapsed.rounded(.down))).font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Theme.tertiary).monospacedDigit()
        }
    }

    private func checklist(now: Date) -> some View {
        let shown = tools.suffix(5)
        return VStack(alignment: .leading, spacing: 5) {
            if tools.count > shown.count {
                Text("+\(tools.count - shown.count) earlier step\(tools.count - shown.count == 1 ? "" : "s")")
                    .font(.system(size: 10.5)).foregroundStyle(Theme.tertiary).padding(.leading, 30)
            }
            ForEach(Array(shown)) { item in
                if case let .tool(state, _, verb, detail, error) = item.kind {
                    HStack(spacing: 8) {
                        Group {
                            if state == "running" { ProgressView().controlSize(.mini) }
                            else if state == "error" { Image(systemName: "xmark.circle.fill").foregroundStyle(.red.opacity(0.85)) }
                            else { Image(systemName: "checkmark.circle.fill").foregroundStyle(.green.opacity(0.85)) }
                        }
                        .font(.system(size: 11)).frame(width: 14, height: 14)
                        .padding(.leading, 16)
                        Image(systemName: toolSymbol(verb)).font(.system(size: 10)).foregroundStyle(Theme.tertiary).frame(width: 12)
                        Text(state == "running" ? verb : state == "error" ? verb + " failed" : ProgressLogic.past(verb))
                            .font(.system(size: 11.5, weight: state == "running" ? .semibold : .regular))
                            .foregroundStyle(state == "error" ? Color.red.opacity(0.9) : state == "running" ? .white.opacity(0.9) : Theme.secondary)
                            .lineLimit(1)
                        if let e = error, state == "error" {
                            Text(e).font(.system(size: 11)).foregroundStyle(Theme.tertiary).lineLimit(1)
                        } else if !detail.isEmpty {
                            Text(detail).font(.system(size: 11)).foregroundStyle(Theme.tertiary).lineLimit(1)
                        }
                        Spacer(minLength: 4)
                        if let s = item.started {
                            Text(ProgressLogic.duration((item.ended ?? now).timeIntervalSince(s)))
                                .font(.system(size: 10.5, design: .monospaced)).foregroundStyle(Theme.tertiary)
                        }
                    }
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
        }
    }
}

/// `--render-progress out.png`: the live card in three moments (sample data, nothing sent).
enum ProgressSheet {
    @MainActor static func render(to path: String) -> Int32 {
        func backend(_ secs: TimeInterval) -> Backend { let b = Backend(); b.busy = true; b.turnStarted = Date().addingTimeInterval(-secs); return b }
        let now = Date()
        func tool(_ id: String, _ state: String, _ verb: String, _ detail: String, _ start: Double, _ took: Double?, error: String? = nil) -> Item {
            var i = Item(id: id, kind: .tool(state: state, icon: "◆", verb: verb, detail: detail, error: error), text: "",
                         started: now.addingTimeInterval(-start))
            i.ended = took.map { now.addingTimeInterval(-start + $0) }
            return i
        }
        let thinking = Item(id: "t", kind: .thinking, text: "The user wants a sync on Friday at 3 with Priya and Sam. I should find their email addresses first, then check Friday's calendar for conflicts", streaming: true)
        let b1 = backend(4)
        let b2 = backend(7)
        let b3 = backend(16)
        b3.approvals = [Approval(id: "a", tool: "create_reminder", preview: "“Prep launch sync”", spoken: "", allowLabel: nil)]
        let steps2 = [tool("1", "done", "Finding a contact", "Priya", 6.2, 0.12), tool("2", "done", "Finding a contact", "Sam", 6.2, 0.14),
                      tool("3", "running", "Checking the calendar", "Friday", 1.4, nil)]
        let steps3 = steps2.map { var x = $0; if case let .tool(_, ic, v, d, e) = x.kind, x.id == "3" { x.kind = .tool(state: "done", icon: ic, verb: v, detail: d, error: e); x.ended = now.addingTimeInterval(-1.1) }; return x }
            + [tool("4", "error", "Searching the web", "", 9, 0.3, error: "No connection")]
        let sheet = VStack(alignment: .leading, spacing: 18) {
            LiveProgressCard(backend: b1, steps: [thinking])
            LiveProgressCard(backend: b2, steps: steps2)
            LiveProgressCard(backend: b3, steps: steps3)
        }
        .padding(20).frame(width: 560).background(Color.black)
        .environment(\.notchContentVisible, false)
        let host = NSHostingView(rootView: sheet)
        host.frame = NSRect(x: 0, y: 0, width: 560, height: 520)
        let w = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        w.appearance = NSAppearance(named: .darkAqua)
        w.contentView = host
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.6))
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return 1 }
        host.cacheDisplay(in: host.bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else { return 1 }
        try? png.write(to: URL(fileURLWithPath: path))
        return 0
    }
}
