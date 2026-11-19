import AppKit
import Charts
import SwiftUI
import UniformTypeIdentifiers

// ⋯ › Developer… (and "Details" on a finished steps row): what the agent did, as a devtools-style trace viewer.
//   Tasks    — sidebar (search, by day, the live task on top, a time-split bar per task) · centre (stat tiles,
//              swimlane minimap You/Model/Tools, plain-language insights, a waterfall grouped by model pass with role
//              chips and inline input → result) · inspector (the selected step: timing, flags, copyable input/output).
//   Overview — the last 7 days: success rate, median times, tasks per day, slowest/failing tools, model start-up time.
// Rendered only while this window is open (rule 7). Exports are redacted (TraceLogic.redacted).

@MainActor
final class DeveloperWindow: NSObject, NSWindowDelegate {
    static let shared = DeveloperWindow()
    private var window: NSWindow?
    private let selection = DevSelection()

    func show(turn: String? = nil) {
        TraceStore.shared.loadIfNeeded()
        selection.id = turn ?? TraceStore.shared.live?.id ?? TraceStore.shared.recent.first?.id
        selection.event = nil
        selection.tab = .tasks
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1240, height: 760),
                             styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                             backing: .buffered, defer: false)
            w.title = "Developer — task traces"
            w.titlebarAppearsTransparent = true
            w.titleVisibility = .hidden
            w.appearance = NSAppearance(named: .darkAqua)
            w.isReleasedWhenClosed = false
            w.minSize = NSSize(width: 980, height: 560)
            w.delegate = self
            w.contentView = NSHostingView(rootView: DeveloperView(store: TraceStore.shared, sel: selection))
            w.center()
            window = w
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

@MainActor final class DevSelection: ObservableObject {
    enum Tab: String { case tasks = "Tasks", overview = "Overview" }
    @Published var id: String?
    @Published var event: Int?
    @Published var tab: Tab = .tasks
}

// MARK: - Palette

enum DevColor {
    static let bg = Color(red: 0.075, green: 0.075, blue: 0.085)
    static let panel = Color(red: 0.105, green: 0.105, blue: 0.12)
    static let raised = Color.white.opacity(0.055)
    static let line = Color.white.opacity(0.08)
    static let model = Color(red: 0.66, green: 0.52, blue: 1.0)
    static let tools = Color(red: 0.98, green: 0.62, blue: 0.26)
    static let you = Color(red: 0.36, green: 0.66, blue: 1.0)
    static let route = Color(white: 0.55)
    static let good = Color(red: 0.36, green: 0.84, blue: 0.52)
    static let bad = Color(red: 1.0, green: 0.38, blue: 0.38)
    static let warn = Color(red: 1.0, green: 0.8, blue: 0.3)

    static func of(_ e: TraceEvent) -> Color {
        if !e.ok { return bad }
        switch e.kind {
        case .llm, .decide: return model
        case .retry: return warn
        case .tool: return tools
        case .approval, .question: return you
        case .route, .info: return route
        }
    }
    static func of(_ l: TraceInsights.Lane) -> Color { l == .you ? you : l == .model ? model : tools }
}

// MARK: - Root

struct DeveloperView: View {
    @ObservedObject var store: TraceStore
    @ObservedObject var sel: DevSelection
    @State private var query = ""
    @State private var filter = 0                 // 0 all · 1 problems · 2 approvals
    @FocusState private var searching: Bool

    private var all: [TurnRecord] { (store.live.map { [$0] } ?? []) + store.recent }
    private var list: [TurnRecord] {
        let q = query.lowercased()
        return all.filter { r in
            (filter == 0 || (filter == 1 && r.hadProblem) || (filter == 2 && r.approvals > 0))
                && (q.isEmpty || r.prompt.lowercased().contains(q) || r.model.lowercased().contains(q)
                    || r.events.contains { $0.name.lowercased().contains(q) })
        }
    }
    private var current: TurnRecord? { all.first { $0.id == sel.id } ?? list.first }

    var body: some View {
        VStack(spacing: 0) {
            topBar
            Divider().overlay(DevColor.line)
            if sel.tab == .tasks {
                HStack(spacing: 0) {
                    TaskSidebar(list: list, live: store.live?.id, sel: sel, filter: $filter)
                        .frame(width: 290)
                    Divider().overlay(DevColor.line)
                    if let r = current {
                        TurnDetail(r: r, live: store.live?.id == r.id, sel: sel)
                        Divider().overlay(DevColor.line)
                        Inspector(r: r, sel: sel).frame(width: 330)
                    } else {
                        EmptyTraces().frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
            } else {
                OverviewPane(records: store.recent)
            }
        }
        .background(DevColor.bg)
        .foregroundStyle(.white)
        .background(shortcuts)
    }

    private var topBar: some View {
        HStack(spacing: 10) {
            Text("Traces").font(.system(size: 13, weight: .bold)).padding(.leading, 72)
            HStack(spacing: 2) {
                tab(.tasks, "list.bullet.rectangle")
                tab(.overview, "chart.bar.xaxis")
            }
            .padding(2)
            .background(RoundedRectangle(cornerRadius: 8).fill(DevColor.raised))
            if store.live != nil {
                HStack(spacing: 5) {
                    Circle().fill(DevColor.good).frame(width: 7, height: 7)
                    Text("Live").font(.system(size: 11, weight: .semibold)).foregroundStyle(DevColor.good)
                }
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(Capsule().fill(DevColor.good.opacity(0.12)))
            }
            Spacer()
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(.secondary)
                TextField("Search prompts, tools, models", text: $query).textFieldStyle(.plain).font(.system(size: 12))
                    .focused($searching)
                if !query.isEmpty {
                    Button { query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }.buttonStyle(.plain)
                } else {
                    Text("⌘F").font(.system(size: 10, design: .monospaced)).foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 9).padding(.vertical, 6)
            .frame(width: 280)
            .background(RoundedRectangle(cornerRadius: 8).fill(DevColor.raised))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(searching ? DevColor.you.opacity(0.6) : DevColor.line))
        }
        .padding(.horizontal, 12).frame(height: 46)
        .background(DevColor.panel)
    }

    private func tab(_ t: DevSelection.Tab, _ icon: String) -> some View {
        Button { sel.tab = t } label: {
            Label(t.rawValue, systemImage: icon).font(.system(size: 12, weight: .medium))
                .padding(.horizontal, 10).padding(.vertical, 4)
                .background(RoundedRectangle(cornerRadius: 6).fill(sel.tab == t ? Color.white.opacity(0.12) : .clear))
                .foregroundStyle(sel.tab == t ? .white : .secondary)
        }
        .buttonStyle(.plain)
    }

    /// ⌘F search · Esc closes the inspector's step · ⌥↑/⌥↓ moves through steps.
    private var shortcuts: some View {
        ZStack {
            Button("") { searching = true }.keyboardShortcut("f", modifiers: .command)
            Button("") { if searching { searching = false } else { sel.event = nil } }.keyboardShortcut(.escape, modifiers: [])
            Button("") { step(-1) }.keyboardShortcut(.upArrow, modifiers: .option)
            Button("") { step(1) }.keyboardShortcut(.downArrow, modifiers: .option)
        }
        .opacity(0).frame(width: 0, height: 0)
    }

    private func step(_ d: Int) {
        guard let r = current, !r.events.isEmpty else { return }
        sel.event = min(r.events.count - 1, max(0, (sel.event ?? -1) + d))
    }
}

// MARK: - Sidebar

struct TaskSidebar: View {
    let list: [TurnRecord]
    let live: String?
    @ObservedObject var sel: DevSelection
    @Binding var filter: Int
    @State private var confirmClear = false

    private var groups: [(String, [TurnRecord])] {
        let now = Date()
        var out: [(String, [TurnRecord])] = []
        for r in list {
            let d = r.id == live ? "Now" : TraceInsights.dayLabel(r.started, now: now)
            if out.last?.0 == d { out[out.count - 1].1.append(r) } else { out.append((d, [r])) }
        }
        return out
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                chip("All", 0); chip("Problems", 1); chip("Approvals", 2)
                Spacer()
                Text("\(list.count)").font(.system(size: 11, design: .monospaced)).foregroundStyle(.tertiary)
            }
            .padding(10)
            List(selection: Binding(get: { sel.id }, set: { sel.id = $0; sel.event = nil })) {
                ForEach(groups, id: \.0) { g in
                    Section(g.0) {
                        ForEach(g.1) { r in TaskRow(r: r, live: r.id == live).tag(r.id) }
                    }
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
            footer
        }
        .background(DevColor.panel)
    }

    private func chip(_ t: String, _ v: Int) -> some View {
        Button { filter = v } label: {
            Text(t).font(.system(size: 11, weight: .medium)).padding(.horizontal, 9).padding(.vertical, 4)
                .background(Capsule().fill(filter == v ? Color.white.opacity(0.14) : DevColor.raised))
                .foregroundStyle(filter == v ? .white : .secondary)
        }
        .buttonStyle(.plain)
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Button { NSWorkspace.shared.open(URL(fileURLWithPath: TraceStore.shared.folder)) } label: {
                    Label("Folder", systemImage: "folder")
                }
                Spacer()
                Button(confirmClear ? "Clear all?" : "Clear") {
                    if confirmClear { TraceStore.shared.clear(); confirmClear = false } else { confirmClear = true }
                }
                .foregroundStyle(confirmClear ? DevColor.bad : .secondary)
            }
            .buttonStyle(.plain).font(.system(size: 11))
            Label("On this Mac only · kept \(TraceLogic.keepDays) days", systemImage: "lock.fill")
                .font(.system(size: 10)).foregroundStyle(.tertiary)
        }
        .padding(10)
        .overlay(alignment: .top) { Rectangle().fill(DevColor.line).frame(height: 1) }
    }
}

struct TaskRow: View {
    let r: TurnRecord
    let live: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                status
                Text(r.prompt.isEmpty ? "(no text)" : r.prompt).font(.system(size: 12, weight: .medium)).lineLimit(1)
            }
            HStack(spacing: 6) {
                Text(r.started.formatted(date: .omitted, time: .shortened))
                Text(live ? "running…" : TraceLogic.seconds(r.ms))
                if r.toolCalls > 0 { Text("\(r.toolCalls) tool\(r.toolCalls == 1 ? "" : "s")") }
                if r.failedTools > 0 { Text("\(r.failedTools) failed").foregroundStyle(DevColor.bad) }
            }
            .font(.system(size: 10.5, design: .monospaced)).foregroundStyle(.secondary)
            SplitBar(b: TraceInsights.breakdown(r)).frame(height: 3)
        }
        .padding(.vertical, 3)
    }

    @ViewBuilder private var status: some View {
        if live { ProgressView().controlSize(.mini).frame(width: 12, height: 12) }
        else {
            Image(systemName: r.end.hasPrefix("error") ? "xmark.octagon.fill" : r.end == "stopped" ? "stop.circle.fill"
                  : r.hadProblem ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .font(.system(size: 10.5))
                .foregroundStyle(r.end == "stopped" ? Color.secondary : r.hadProblem ? (r.end.hasPrefix("error") ? DevColor.bad : DevColor.warn) : DevColor.good)
        }
    }
}

/// Model / tools / waiting as one thin stacked bar.
struct SplitBar: View {
    let b: TraceInsights.Breakdown
    var body: some View {
        GeometryReader { g in
            let t = Double(max(1, b.model + b.tools + b.waiting))
            HStack(spacing: 1) {
                Rectangle().fill(DevColor.model).frame(width: g.size.width * Double(b.model) / t)
                Rectangle().fill(DevColor.tools).frame(width: g.size.width * Double(b.tools) / t)
                Rectangle().fill(DevColor.you).frame(width: g.size.width * Double(b.waiting) / t)
            }
            .clipShape(Capsule())
        }
        .opacity(b.model + b.tools + b.waiting == 0 ? 0.2 : 1)
    }
}

// MARK: - Centre

struct TurnDetail: View {
    let r: TurnRecord
    let live: Bool
    @ObservedObject var sel: DevSelection
    @State private var includeContent = false
    @State private var note: String?

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        header
                        tiles
                        Minimap(r: r, sel: sel)
                        insights
                        waterfall
                    }
                    .padding(18)
                }
                .onChange(of: sel.event) { _, e in if let e { withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(e, anchor: .center) } } }
            }
            bottomBar
        }
        .frame(maxWidth: .infinity)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(r.prompt.isEmpty ? "(no text)" : r.prompt).font(.system(size: 17, weight: .semibold)).lineLimit(3).textSelection(.enabled)
            HStack(spacing: 6) {
                pill(live ? "Running" : r.end.hasPrefix("error") ? "Error" : r.end.capitalized, statusColor)
                pill(r.model, DevColor.model)
                pill(r.provider, .gray)
                Text(r.started.formatted(date: .abbreviated, time: .standard)).font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
    }

    private var statusColor: Color {
        if live { return DevColor.good }
        if r.end.hasPrefix("error") || r.end == "limit" { return DevColor.bad }
        return r.end == "stopped" ? .gray : DevColor.good
    }

    private func pill(_ t: String, _ c: Color) -> some View {
        Text(t).font(.system(size: 10.5, weight: .semibold)).lineLimit(1).foregroundStyle(c)
            .padding(.horizontal, 8).padding(.vertical, 3).background(Capsule().fill(c.opacity(0.14)))
    }

    private var tiles: some View {
        let b = TraceInsights.breakdown(r)
        let passes = TraceInsights.steps(r).filter { $0.header != nil }.count
        return HStack(spacing: 8) {
            tile("Total", TraceLogic.seconds(r.ms), sub: "\(passes) model pass\(passes == 1 ? "" : "es")", .white)
            tile("Model", TraceLogic.seconds(b.model), sub: share(b.model, b), DevColor.model)
            tile("Tools", TraceLogic.seconds(b.tools), sub: "\(r.events.filter { $0.kind == .tool }.count) calls", DevColor.tools)
            tile("Waiting for you", TraceLogic.seconds(b.waiting), sub: r.approvals > 0 ? "\(r.approvals) approval\(r.approvals == 1 ? "" : "s")" : "none", DevColor.you)
            tile("Tokens", "\(r.inTokens.formatted()) / \(r.outTokens.formatted())", sub: "in / out", .white)
        }
    }

    private func share(_ v: Int, _ b: TraceInsights.Breakdown) -> String {
        let t = max(1, b.model + b.tools + b.waiting)
        return "\(v * 100 / t)% of the work"
    }

    private func tile(_ title: String, _ value: String, sub: String, _ c: Color) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 5) {
                Circle().fill(c).frame(width: 6, height: 6)
                Text(title).font(.system(size: 10.5, weight: .medium)).foregroundStyle(.secondary).lineLimit(1)
            }
            Text(value).font(.system(size: 17, weight: .semibold, design: .rounded)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.7)
            Text(sub).font(.system(size: 10)).foregroundStyle(.tertiary).lineLimit(1)
        }
        .padding(10).frame(maxWidth: .infinity, minHeight: 74, maxHeight: 74, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 10).fill(DevColor.raised))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(DevColor.line))
    }

    private var insights: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(TraceInsights.insights(r).enumerated()), id: \.offset) { _, i in
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: icon(i.tone)).foregroundStyle(tone(i.tone)).font(.system(size: 12))
                    Text(i.text).font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 10).padding(.vertical, 7)
                .background(RoundedRectangle(cornerRadius: 8).fill(tone(i.tone).opacity(0.09)))
            }
        }
    }

    private func icon(_ t: TraceInsights.Insight.Tone) -> String {
        switch t {
        case .bad: return "exclamationmark.octagon.fill"
        case .warn: return "exclamationmark.triangle.fill"
        case .good: return "checkmark.seal.fill"
        case .info: return "lightbulb.fill"
        }
    }

    private func tone(_ t: TraceInsights.Insight.Tone) -> Color {
        switch t { case .good: return DevColor.good; case .info: return DevColor.you; case .warn: return DevColor.warn; case .bad: return DevColor.bad }
    }

    private var waterfall: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 0) {
                Text("STEP").frame(width: 320, alignment: .leading)
                Axis(total: r.ms)
                Text("TIME").frame(width: 60, alignment: .trailing)
            }
            .font(.system(size: 9.5, weight: .semibold)).foregroundStyle(.tertiary)
            .padding(.horizontal, 8).padding(.bottom, 6)
            ForEach(Array(TraceInsights.steps(r).enumerated()), id: \.offset) { _, s in
                VStack(alignment: .leading, spacing: 0) {
                    if let h = s.header {
                        EventRow(e: r.events[h], index: h, total: r.ms, depth: 0, title: s.title, sel: sel).id(h)
                    } else {
                        Text(s.title.uppercased()).font(.system(size: 9.5, weight: .bold)).foregroundStyle(.tertiary)
                            .padding(.horizontal, 8).padding(.top, 4).padding(.bottom, 2)
                    }
                    ForEach(s.children, id: \.self) { i in
                        EventRow(e: r.events[i], index: i, total: r.ms, depth: s.header == nil ? 0 : 1, title: nil, sel: sel).id(i)
                    }
                }
                .padding(.vertical, 3)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.025)))
                .padding(.bottom, 6)
            }
        }
    }

    private var bottomBar: some View {
        HStack(spacing: 12) {
            Toggle("Include content in exports", isOn: $includeContent).toggleStyle(.checkbox).font(.system(size: 11))
                .help("Off: only tool names, timings and outcomes. On: prompts, inputs and results too — emails, your home folder and keys are still removed.")
            Spacer()
            if let note { Label(note, systemImage: "checkmark").font(.system(size: 11)).foregroundStyle(DevColor.good) }
            Button { copyReport() } label: { Label("Copy for a bug report", systemImage: "ladybug") }
            Button { export() } label: { Label("Export JSON…", systemImage: "square.and.arrow.up") }.buttonStyle(.borderedProminent)
        }
        .controlSize(.small)
        .padding(.horizontal, 16).padding(.vertical, 9)
        .background(DevColor.panel)
        .overlay(alignment: .top) { Rectangle().fill(DevColor.line).frame(height: 1) }
    }

    private func copyReport() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(TraceLogic.reportText(r), forType: .string)
        note = "Copied — no prompts or results"
    }

    private func export() {
        let safe = TraceLogic.redacted(r, content: includeContent)
        let enc = JSONEncoder.traces
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? enc.encode(safe) else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "opennotch-trace-\(r.id.prefix(8)).json"
        if panel.runModal() == .OK, let url = panel.url {
            try? data.write(to: url)
            note = includeContent ? "Saved with content (scrubbed)" : "Saved — no content"
        }
    }
}

/// Tick labels along a timeline.
struct Axis: View {
    let total: Int
    var body: some View {
        GeometryReader { g in
            ForEach(TraceInsights.labelTicks(total: total, width: Double(g.size.width)), id: \.self) { t in
                Text(TraceLogic.seconds(t)).font(.system(size: 9, design: .monospaced))
                    .fixedSize()
                    .position(x: min(g.size.width - 18, max(18, g.size.width * Double(t) / Double(max(1, total)))), y: 6)
            }
        }
        .frame(height: 12)
    }
}

/// You / Model / Tools lanes across the whole turn; click a block to inspect it.
struct Minimap: View {
    let r: TurnRecord
    @ObservedObject var sel: DevSelection

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(TraceInsights.Lane.allCases, id: \.self) { lane in
                HStack(spacing: 8) {
                    Text(lane.rawValue).font(.system(size: 10.5, weight: .medium)).foregroundStyle(.secondary)
                        .frame(width: 44, alignment: .trailing)
                    laneTrack(lane)
                }
            }
            HStack(spacing: 8) { Spacer().frame(width: 44); Axis(total: r.ms) }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(DevColor.raised))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(DevColor.line))
    }

    private func laneTrack(_ lane: TraceInsights.Lane) -> some View {
        let items = r.events.indices.filter { TraceInsights.lane(r.events[$0]) == lane }
        return GeometryReader { g in
            ZStack(alignment: .leading) {
                Rectangle().fill(Color.white.opacity(0.03))
                ForEach(items, id: \.self) { i in block(i, lane: lane, width: g.size.width) }
            }
        }
        .frame(height: 14)
        .clipShape(RoundedRectangle(cornerRadius: 3))
    }

    private func block(_ i: Int, lane: TraceInsights.Lane, width: CGFloat) -> some View {
        let e = r.events[i]
        let b = TraceLogic.bar(e, total: r.ms)
        return RoundedRectangle(cornerRadius: 3)
            .fill(e.ok ? DevColor.of(lane) : DevColor.bad)
            .opacity(sel.event == nil || sel.event == i ? 0.95 : 0.4)
            .frame(width: max(5, width * b.width), height: 12)
            .offset(x: width * b.start)
            .onTapGesture { sel.event = i }
            .help("\(e.name) · \(TraceLogic.seconds(e.ms))")
    }
}

struct EventRow: View {
    let e: TraceEvent
    let index: Int
    let total: Int
    let depth: Int
    let title: String?
    @ObservedObject var sel: DevSelection
    @State private var hover = false

    private var role: (String, Color) {
        switch e.kind {
        case .llm: return ("MODEL", DevColor.model)
        case .decide: return ("PICKER", DevColor.model)
        case .retry: return ("RETRY", DevColor.warn)
        case .tool: return ("TOOL", DevColor.tools)
        case .approval: return ("YOU", DevColor.you)
        case .question: return ("ASKED", DevColor.you)
        case .route: return ("ROUTER", DevColor.route)
        case .info: return ("INFO", DevColor.route)
        }
    }

    private var inline: String {
        if e.kind == .tool {
            let a = (e.args ?? "").replacingOccurrences(of: "\n", with: "  ")
            let res = (e.result ?? e.detail).replacingOccurrences(of: "\n", with: " ")
            return a.isEmpty ? res : a + (res.isEmpty ? "" : "  →  " + res)
        }
        return e.detail
    }

    var body: some View {
        let selected = sel.event == index
        HStack(spacing: 0) {
            label.frame(width: 320, alignment: .leading)
            bar
            Text(TraceLogic.seconds(e.ms)).font(.system(size: 11, design: .monospaced))
                .foregroundStyle(e.ms >= 3000 ? DevColor.warn : .secondary)
                .frame(width: 60, alignment: .trailing)
        }
        .padding(.horizontal, 8).frame(height: 30)
        .background(RoundedRectangle(cornerRadius: 6).fill(selected ? DevColor.you.opacity(0.16) : hover ? Color.white.opacity(0.05) : .clear))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(selected ? DevColor.you.opacity(0.5) : .clear))
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onTapGesture { sel.event = selected ? nil : index }
    }

    private var label: some View {
        HStack(spacing: 7) {
            if depth > 0 { Rectangle().fill(DevColor.line).frame(width: 1, height: 18).padding(.leading, 10).padding(.trailing, 4) }
            Text(role.0).font(.system(size: 9, weight: .bold, design: .monospaced)).foregroundStyle(role.1)
                .padding(.horizontal, 5).padding(.vertical, 2)
                .background(RoundedRectangle(cornerRadius: 4).fill(role.1.opacity(0.15)))
                .frame(width: 58, alignment: .leading)
            if let title { Text(title).font(.system(size: 11.5, weight: .semibold)).foregroundStyle(.secondary) }
            Text(e.name).font(.system(size: 12, weight: .semibold, design: .monospaced)).lineLimit(1)
            if e.parallel { Image(systemName: "arrow.triangle.branch").font(.system(size: 9)).foregroundStyle(DevColor.you).help("Ran side by side") }
            if e.verified { Image(systemName: "checkmark.seal.fill").font(.system(size: 10)).foregroundStyle(DevColor.good).help("Read back to confirm the change") }
            if !e.ok { Image(systemName: "xmark.circle.fill").font(.system(size: 10)).foregroundStyle(DevColor.bad) }
            Text(inline).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
            Spacer(minLength: 4)
        }
    }

    private var bar: some View {
        GeometryReader { g in
            let b = TraceLogic.bar(e, total: total)
            ZStack(alignment: .leading) {
                ForEach(TraceInsights.ticks(total: total), id: \.self) { t in
                    Rectangle().fill(Color.white.opacity(0.04)).frame(width: 1)
                        .offset(x: g.size.width * Double(t) / Double(max(1, total)))
                }
                RoundedRectangle(cornerRadius: 3).fill(DevColor.of(e))
                    .frame(width: max(4, g.size.width * b.width), height: e.kind == .llm ? 10 : 8)
                    .offset(x: g.size.width * b.start)
                if let f = e.first, e.kind == .llm, e.ms > 0 {
                    Rectangle().fill(Color.white.opacity(0.85)).frame(width: 1.5, height: 14)
                        .offset(x: g.size.width * Double(e.at + f) / Double(max(1, total)))
                        .help("First output after \(TraceLogic.seconds(f))")
                }
            }
            .frame(maxHeight: .infinity)
        }
    }
}

// MARK: - Inspector

struct Inspector: View {
    let r: TurnRecord
    @ObservedObject var sel: DevSelection

    var body: some View {
        ScrollView {
            if let i = sel.event, i < r.events.count { detail(r.events[i]) } else { idle }
        }
        .background(DevColor.panel)
    }

    private var idle: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Select a step", systemImage: "cursorarrow.click.2").font(.system(size: 13, weight: .semibold))
            Text("Click any row or lane block to see what was sent, what came back and how long it took.")
                .font(.system(size: 11.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 8) {
                legend(DevColor.model, "Model", "the AI thinking and writing")
                legend(DevColor.tools, "Tools", "calendar, files, the web…")
                legend(DevColor.you, "You", "waiting for your OK or answer")
                legend(DevColor.bad, "Failed", "a step that didn't work")
            }
            VStack(alignment: .leading, spacing: 5) {
                key("⌘F", "search"); key("⌥↑ ⌥↓", "previous / next step"); key("Esc", "close the step")
            }
            .padding(.top, 6)
        }
        .padding(16)
    }

    private func legend(_ c: Color, _ t: String, _ d: String) -> some View {
        HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 2).fill(c).frame(width: 14, height: 6)
            Text(t).font(.system(size: 11.5, weight: .semibold))
            Text(d).font(.system(size: 11)).foregroundStyle(.secondary)
        }
    }

    private func key(_ k: String, _ d: String) -> some View {
        HStack(spacing: 8) {
            Text(k).font(.system(size: 10, design: .monospaced)).padding(.horizontal, 5).padding(.vertical, 2)
                .background(RoundedRectangle(cornerRadius: 4).fill(DevColor.raised))
            Text(d).font(.system(size: 11)).foregroundStyle(.secondary)
        }
    }

    private func detail(_ e: TraceEvent) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 3).fill(DevColor.of(e)).frame(width: 4, height: 30)
                VStack(alignment: .leading, spacing: 2) {
                    Text(e.name).font(.system(size: 15, weight: .semibold, design: .monospaced)).lineLimit(2).textSelection(.enabled)
                    Text(e.kind.rawValue.capitalized + (e.ok ? "" : " · failed")).font(.system(size: 11))
                        .foregroundStyle(e.ok ? Color.secondary : DevColor.bad)
                }
                Spacer()
                Button { sel.event = nil } label: { Image(systemName: "xmark").font(.system(size: 10, weight: .bold)) }
                    .buttonStyle(.plain).foregroundStyle(.secondary).help("Close (Esc)")
            }
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 6) {
                row("Started", "+" + TraceLogic.seconds(e.at))
                row("Took", TraceLogic.seconds(e.ms))
                if let f = e.first { row("First output", TraceLogic.seconds(f)) }
                if e.parallel { row("Ran", "side by side with other lookups") }
                if e.verified { row("Checked", "read back to confirm it happened ✓") }
            }
            .font(.system(size: 11.5))
            if !e.detail.isEmpty { block("Detail", e.detail, mono: false) }
            if let a = e.args { block("Input", a, mono: true) }
            if let res = e.result { block("Output", res, mono: true) }
            if let hint = hint(e) {
                Label(hint, systemImage: "lightbulb.fill").font(.system(size: 11.5)).foregroundStyle(DevColor.warn)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(16)
    }

    private func row(_ k: String, _ v: String) -> some View {
        GridRow {
            Text(k).foregroundStyle(.secondary)
            Text(v).font(.system(size: 11.5, design: .monospaced)).textSelection(.enabled)
        }
    }

    private func block(_ title: String, _ text: String, mono: Bool) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(title.uppercased()).font(.system(size: 9.5, weight: .bold)).foregroundStyle(.tertiary)
                Spacer()
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                } label: { Image(systemName: "doc.on.doc").font(.system(size: 10)) }
                    .buttonStyle(.plain).foregroundStyle(.secondary).help("Copy")
            }
            Text(pretty(text)).font(.system(size: 11, design: mono ? .monospaced : .default)).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.black.opacity(0.35)))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(DevColor.line))
        }
    }

    private func pretty(_ s: String) -> String {
        guard s.first == "{" || s.first == "[", let d = s.data(using: .utf8), let o = try? JSONSerialization.jsonObject(with: d),
              let p = try? JSONSerialization.data(withJSONObject: o, options: [.prettyPrinted, .sortedKeys]),
              let t = String(data: p, encoding: .utf8) else { return s }
        return t
    }

    private func hint(_ e: TraceEvent) -> String? {
        let d = e.detail.lowercased()
        if !e.ok && (d.contains("isn't allowed") || d.contains("access")) { return "Turn this on in OpenNotch Settings › Permissions, then try again." }
        if e.kind == .llm, let f = e.first, f >= 3000 { return "Slow to start. Faster models (Settings › AI) usually answer in under a second." }
        if e.kind == .approval && !e.ok { return "Declined or timed out — nothing was done." }
        return nil
    }
}

struct EmptyTraces: View {
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "waveform.path.ecg.rectangle").font(.system(size: 38)).foregroundStyle(DevColor.model)
            Text("No tasks yet").font(.system(size: 15, weight: .semibold))
            Text("Ask something in the notch — every step it takes shows up here, live.")
                .font(.system(size: 12)).foregroundStyle(.secondary)
        }
    }
}

// MARK: - Overview

struct OverviewPane: View {
    let records: [TurnRecord]

    var body: some View {
        let o = TraceInsights.overview(records, now: Date())
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Last 7 days").font(.system(size: 17, weight: .semibold))
                HStack(spacing: 8) {
                    stat("Tasks", "\(o.tasks)", DevColor.you)
                    stat("Went smoothly", o.tasks == 0 ? "—" : "\(Int((o.okRate * 100).rounded()))%", DevColor.good)
                    stat("Median time", o.tasks == 0 ? "—" : TraceLogic.seconds(o.medianMs), .white)
                    stat("Model starts answering", o.medianFirst.map(TraceLogic.seconds) ?? "—", DevColor.model)
                }
                card("Tasks per day") { dayChart(o) }
                HStack(alignment: .top, spacing: 12) {
                    card("Tools — failing and slow first") { toolTable(o) }
                    card("Models") { modelTable(o) }
                }
                Label("Computed on this Mac from your last \(TraceLogic.keepDays) days of traces.", systemImage: "lock.fill")
                    .font(.system(size: 10.5)).foregroundStyle(.tertiary)
            }
            .padding(20)
        }
    }

    private func dayChart(_ o: TraceInsights.Overview) -> some View {
        Chart {
            ForEach(o.days, id: \.day) { d in
                BarMark(x: .value("Day", d.day, unit: .day), y: .value("Tasks", d.ok))
                    .foregroundStyle(by: .value("Outcome", "Smooth"))
                BarMark(x: .value("Day", d.day, unit: .day), y: .value("Tasks", d.problems))
                    .foregroundStyle(by: .value("Outcome", "Had a problem"))
            }
        }
        .chartForegroundStyleScale(["Smooth": DevColor.good, "Had a problem": DevColor.bad])
        .chartXAxis { AxisMarks(values: .stride(by: .day)) { _ in AxisValueLabel(format: .dateTime.weekday(.abbreviated)) } }
        .frame(height: 150)
    }

    @ViewBuilder private func toolTable(_ o: TraceInsights.Overview) -> some View {
        if o.tools.isEmpty { empty } else {
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 7) {
                GridRow { head("Tool"); head("Calls"); head("Failed"); head("Avg time") }
                ForEach(o.tools.prefix(12), id: \.name) { t in
                    let avg = t.totalMs / max(1, t.calls)
                    GridRow {
                        Text(t.name).font(.system(size: 11.5, design: .monospaced))
                        Text("\(t.calls)").monospacedDigit()
                        Text("\(t.failures)").foregroundStyle(t.failures > 0 ? DevColor.bad : .secondary)
                        Text(TraceLogic.seconds(avg)).foregroundStyle(avg >= 3000 ? DevColor.warn : .secondary)
                    }
                    .font(.system(size: 11.5))
                }
            }
        }
    }

    @ViewBuilder private func modelTable(_ o: TraceInsights.Overview) -> some View {
        if o.models.isEmpty { empty } else {
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 7) {
                GridRow { head("Model"); head("Passes"); head("Starts answering") }
                ForEach(o.models, id: \.name) { m in
                    GridRow {
                        Text(m.name).font(.system(size: 11.5, design: .monospaced)).lineLimit(1)
                        Text("\(m.passes)").monospacedDigit()
                        Text(m.medianFirst.map(TraceLogic.seconds) ?? "—")
                            .foregroundStyle((m.medianFirst ?? 0) >= 3000 ? DevColor.warn : .secondary)
                    }
                    .font(.system(size: 11.5))
                }
            }
        }
    }

    private var empty: some View { Text("Nothing yet").font(.system(size: 11.5)).foregroundStyle(.secondary) }
    private func head(_ t: String) -> some View { Text(t.uppercased()).font(.system(size: 9.5, weight: .bold)).foregroundStyle(.tertiary) }

    private func stat(_ t: String, _ v: String, _ c: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 5) { Circle().fill(c).frame(width: 6, height: 6); Text(t).font(.system(size: 10.5)).foregroundStyle(.secondary) }
            Text(v).font(.system(size: 22, weight: .semibold, design: .rounded)).monospacedDigit()
        }
        .padding(12).frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(DevColor.raised))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(DevColor.line))
    }

    private func card<C: View>(_ t: String, @ViewBuilder _ c: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(t).font(.system(size: 12, weight: .semibold))
            c()
        }
        .padding(14).frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(DevColor.raised))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(DevColor.line))
    }
}

// MARK: - Render (dev)

/// `--render-developer out.png [overview]`: the view with sample turns (a temp store — never the user's traces).
enum DeveloperSheet {
    @MainActor static func render(to path: String, overview: Bool = false) -> Int32 {
        let dir = NSTemporaryDirectory() + "opennotch-devsheet-\(UUID().uuidString)"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let store = TraceStore(dir: dir)
        for s in samples() { store.append(s) }
        let sel = DevSelection()
        sel.id = "sample"
        sel.event = 5
        sel.tab = overview ? .overview : .tasks
        let host = NSHostingView(rootView: DeveloperView(store: store, sel: sel))
        host.frame = NSRect(x: 0, y: 0, width: 1240, height: 760)
        let w = NSWindow(contentRect: host.frame, styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false)
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

    static func samples() -> [TurnRecord] {
        let now = Date()
        var a = TurnRecord(id: "older", chat: nil, started: now.addingTimeInterval(-26 * 3600), prompt: "What's the weather in Tokyo and on my calendar today?",
                           provider: "OpenRouter", model: "openrouter/free")
        a.events = [TraceEvent(kind: .llm, at: 0, ms: 2100, name: "openrouter/free", detail: "in 4154 · out 82", first: 2100),
                    TraceEvent(kind: .tool, at: 2110, ms: 130, name: "calendar_events", parallel: true),
                    TraceEvent(kind: .tool, at: 2112, ms: 1500, name: "weather", parallel: true),
                    TraceEvent(kind: .llm, at: 3630, ms: 2400, name: "openrouter/free", detail: "in 4634 · out 78", first: 1800)]
        a.ms = 6100; a.toolCalls = 2; a.inTokens = 8788; a.outTokens = 160
        var b = TurnRecord(id: "sample", chat: nil, started: now.addingTimeInterval(-300), prompt: "Invite Priya and Sam to a launch sync on Friday at 3 and remind me to prep",
                           provider: "OpenRouter", model: "openrouter/auto")
        b.events = [
            TraceEvent(kind: .route, at: 0, ms: 2, name: "router", detail: "groups calendar, contacts · 28 of 61 tools"),
            TraceEvent(kind: .llm, at: 4, ms: 1850, name: "openrouter/auto", detail: "in 4210 · out 96 · 2 tool calls", first: 640),
            TraceEvent(kind: .tool, at: 1860, ms: 120, name: "contacts_find", args: "name: Priya", result: "Priya Rao — priya@example.com", parallel: true),
            TraceEvent(kind: .tool, at: 1862, ms: 140, name: "contacts_find", args: "name: Sam", result: "Sam Lee — sam@example.com", parallel: true),
            TraceEvent(kind: .llm, at: 2010, ms: 1400, name: "openrouter/auto", detail: "in 4480 · out 70 · 2 tool calls", first: 520),
            TraceEvent(kind: .tool, at: 3420, ms: 260, name: "invite_event", args: "title: Launch sync\nstart: 2026-11-21T15:00\nguests: priya@example.com, sam@example.com",
                       result: "Opened Google Calendar with “Launch sync” on 21 Nov 2026 at 15:00 and 2 guests. NOT sent yet: the user clicks Save there."),
            TraceEvent(kind: .approval, at: 3690, ms: 4200, name: "create_reminder", detail: "allowed"),
            TraceEvent(kind: .tool, at: 7900, ms: 90, name: "create_reminder", args: "title: Prep launch sync\ndue: 2026-11-21T14:30",
                       result: "Reminder added to Reminders: “Prep launch sync” (checked).", verified: true),
            TraceEvent(kind: .llm, at: 8000, ms: 1200, name: "openrouter/auto", detail: "in 4700 · out 120", first: 480),
        ]
        b.ms = 9200; b.inTokens = 13390; b.outTokens = 286; b.toolCalls = 4
        var c = TurnRecord(id: "failed", chat: nil, started: now.addingTimeInterval(-120), prompt: "Add dentist on Tuesday 10am to my calendar",
                           provider: "Apple on-device", model: "Apple Intelligence")
        c.events = [TraceEvent(kind: .llm, at: 0, ms: 900, name: "Apple Intelligence", detail: "in 0 · out 0", first: 700),
                    TraceEvent(kind: .tool, at: 910, ms: 40, name: "create_event", ok: false, detail: "Calendar access isn't allowed — turn it on in Settings › Permissions.")]
        c.ms = 1400; c.toolCalls = 1
        return [a, b, c]
    }
}
