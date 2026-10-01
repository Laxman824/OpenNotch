import AppKit
import SwiftUI

// ⌘K command palette in the open notch, and the one-tap suggestions shown
// after you drop something onto it. Pure logic first (checked by
// app/checks/palette_cases.swift), views after.

enum PaletteLogic {
    /// Fuzzy match: every query character in order. Higher is better; nil = no match.
    /// Rewards a prefix, word starts and consecutive runs; penalises gaps.
    static func score(_ query: String, _ text: String) -> Int? {
        let q = Array(query.lowercased().filter { !$0.isWhitespace })
        guard !q.isEmpty else { return 0 }
        let t = Array(text.lowercased())
        var qi = 0, score = 0, run = 0, lastHit = -1
        for (i, c) in t.enumerated() where qi < q.count {
            guard c == q[qi] else { continue }
            let wordStart = i == 0 || !t[i - 1].isLetter
            score += 10 + (wordStart ? 8 : 0) + (i == 0 ? 12 : 0)
            run = lastHit == i - 1 ? run + 1 : 0
            score += run * 5
            if lastHit >= 0 { score -= min(6, i - lastHit - 1) }
            lastHit = i
            qi += 1
        }
        return qi == q.count ? score - t.count / 8 : nil
    }

    /// What to offer after something lands in the composer. `items` are
    /// (kind, value) with kind file | screenshot | clipboard | selection | web.
    static func suggestions(for items: [(kind: String, value: String)]) -> [String] {
        guard let first = items.first else { return [] }
        let files = items.filter { $0.kind == "file" }
        if files.count > 1 { return ["Compare these", "Summarise each one", "What do these have in common?"] }
        switch first.kind {
        case "screenshot": return ["Explain what's on screen", "What's wrong here?", "Extract the text"]
        case "web": return ["Summarise this page", "Key takeaways", "Is this legit?"]
        case "clipboard", "selection": return ["Summarise this", "Improve the writing", "Explain it simply"]
        default: break
        }
        let ext = (first.value as NSString).pathExtension.lowercased()
        switch ext {
        case "pdf", "doc", "docx", "txt", "md", "rtf", "pages":
            return ["Summarise this", "Key points & action items", "Explain it simply"]
        case "png", "jpg", "jpeg", "heic", "gif", "webp", "tiff":
            return ["Describe this image", "Extract the text", "What's wrong here?"]
        case "py", "swift", "js", "ts", "tsx", "jsx", "java", "kt", "go", "rs", "c", "cpp", "h", "rb", "sh", "sql":
            return ["Explain this code", "Review it for bugs", "Write tests for it"]
        case "json", "yaml", "yml", "toml", "xml", "plist":
            return ["Explain this config", "Find problems in it"]
        case "csv", "xlsx", "xls", "numbers":
            return ["Summarise the data", "Find trends", "Chart the key numbers"]
        case "eml", "msg":
            return ["Summarise this email", "Draft a reply"]
        case "mp3", "m4a", "wav", "mov", "mp4":
            return ["Transcribe this", "Summarise it"]
        default:
            return ["What is this?", "Summarise it"]
        }
    }
}

// MARK: - Palette

struct PaletteItem: Identifiable {
    enum Group: String { case action = "Actions", module = "Modules", quick = "Quick actions", recent = "Recent prompts", file = "Files", ask = "Ask" }
    let id: String
    let group: Group
    let icon: String
    let title: String
    var subtitle: String? = nil
    var keywords = ""
    let run: () -> Void
}

struct CommandPalette: View {
    let items: [PaletteItem]
    let onAsk: (String) -> Void
    let onAttachFile: (String) -> Void
    let close: () -> Void
    @State private var query = ""
    @State private var selected = 0
    @State private var files: [String] = []
    @State private var fileSearch: DispatchWorkItem?
    @FocusState private var focused: Bool

    private var results: [PaletteItem] {
        var out: [(Int, PaletteItem)] = []
        for (i, it) in items.enumerated() {
            if query.isEmpty {
                out.append((-i, it))                        // as given: actions first
            } else if let s = PaletteLogic.score(query, it.title + " " + it.keywords) {
                out.append((s - i / 50, it))
            }
        }
        var list = out.sorted { $0.0 > $1.0 }.map(\.1)
        if query.isEmpty { list = Array(list.prefix(12)) }
        list += files.map { path in
            PaletteItem(id: "file:" + path, group: .file, icon: "doc", title: (path as NSString).lastPathComponent,
                        subtitle: (path as NSString).deletingLastPathComponent.replacingOccurrences(of: NSHomeDirectory(), with: "~")) {
                onAttachFile(path)
            }
        }
        if !query.trimmingCharacters(in: .whitespaces).isEmpty {
            let q = query
            list.append(PaletteItem(id: "ask", group: .ask, icon: "sparkles", title: "Ask Ledge: “\(q)”") { onAsk(q) })
        }
        return list
    }

    var body: some View {
        let list = results
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").foregroundStyle(Theme.secondary).accessibilityHidden(true)
                TextField("Search actions, modules, files — or ask", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 15))
                    .focused($focused)
                    .onSubmit { activate(list) }
                    .onKeyPress(.downArrow) { move(1, list.count); return .handled }
                    .onKeyPress(.upArrow) { move(-1, list.count); return .handled }
                    .onKeyPress(.escape) { close(); return .handled }
                    .accessibilityLabel("Command palette search")
                Text("esc").font(.system(size: 10, weight: .semibold, design: .rounded))
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(RoundedRectangle(cornerRadius: 5).fill(Color.white.opacity(0.1)))
                    .foregroundStyle(Theme.tertiary)
            }
            .padding(.horizontal, 16).padding(.vertical, 13)
            Divider().overlay(Theme.hairline)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(Array(list.enumerated()), id: \.element.id) { i, it in
                            if i == 0 || list[i - 1].group != it.group {
                                Text(it.group.rawValue.uppercased())
                                    .font(.system(size: 9.5, weight: .heavy, design: .rounded)).tracking(0.7)
                                    .foregroundStyle(Theme.tertiary)
                                    .padding(.horizontal, 12).padding(.top, i == 0 ? 6 : 10).padding(.bottom, 3)
                            }
                            row(it, on: i == selected)
                                .id(it.id)
                                .onTapGesture { selected = i; activate(list) }
                        }
                    }
                    .padding(6)
                }
                .onChange(of: selected) { _, i in
                    if list.indices.contains(i) { withAnimation(.easeOut(duration: 0.1)) { proxy.scrollTo(list[i].id) } }
                }
            }
            .frame(maxHeight: 300)
        }
        .frame(width: 520)
        .background(RoundedRectangle(cornerRadius: 18).fill(Color(white: 0.09)))
        .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(Color.white.opacity(0.12)))
        .shadow(color: .black.opacity(0.5), radius: 30, y: 12)
        .onAppear { DispatchQueue.main.async { focused = true } }
        .onChange(of: query) { _, q in
            selected = 0
            searchFiles(q)
        }
    }

    private func row(_ it: PaletteItem, on: Bool) -> some View {
        HStack(spacing: 11) {
            Image(systemName: it.icon).font(.system(size: 13, weight: .medium))
                .frame(width: 22).foregroundStyle(on ? .white : Theme.glow[0])
            VStack(alignment: .leading, spacing: 1) {
                Text(it.title).font(.system(size: 13, weight: .medium)).lineLimit(1)
                if let s = it.subtitle { Text(s).font(.system(size: 10.5)).foregroundStyle(Theme.secondary).lineLimit(1) }
            }
            Spacer()
            if on { Image(systemName: "return").font(.system(size: 10, weight: .bold)).foregroundStyle(Theme.secondary) }
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 9).fill(on ? AnyShapeStyle(Theme.userBubble.opacity(0.55)) : AnyShapeStyle(Color.clear)))
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }

    private func move(_ d: Int, _ n: Int) {
        guard n > 0 else { return }
        selected = (selected + d + n) % n
    }

    private func activate(_ list: [PaletteItem]) {
        guard list.indices.contains(selected) else { return }
        close()
        list[selected].run()
    }

    /// Spotlight file names, off the main thread (rule §5.16), debounced.
    private func searchFiles(_ q: String) {
        fileSearch?.cancel()
        let term = q.trimmingCharacters(in: .whitespaces)
        guard term.count >= 3 else { files = []; return }
        let work = DispatchWorkItem {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/mdfind")
            p.arguments = ["-onlyin", NSHomeDirectory(), "-name", term]
            let pipe = Pipe()
            p.standardOutput = pipe
            p.standardError = FileHandle.nullDevice
            guard (try? p.run()) != nil else { return }
            let deadline = DispatchTime.now() + 2
            DispatchQueue.global().asyncAfter(deadline: deadline) { if p.isRunning { p.terminate() } }
            let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            let hits = out.split(separator: "\n").map(String.init)
                .filter { !$0.contains("/Library/") && !$0.contains("/.") && !$0.contains("/node_modules/") }
                .prefix(6)
            DispatchQueue.main.async { if q == query { files = Array(hits) } }
        }
        fileSearch = work
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 0.25, execute: work)
    }
}

// MARK: - Drop suggestions

/// One-tap prompts for whatever was just attached.
struct AttachmentSuggestions: View {
    @ObservedObject var backend: Backend

    var body: some View {
        let items = backend.attachments.map { a -> (kind: String, value: String) in
            let k: String
            switch a.kind {
            case .file: k = "file"
            case .screenshot: k = "screenshot"
            case .clipboard: k = "clipboard"
            case .selection: k = "selection"
            case .web: k = "web"
            }
            return (k, a.value)
        }
        let chips = PaletteLogic.suggestions(for: items)
        if !chips.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    Image(systemName: "sparkles").font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Theme.glow[1]).accessibilityHidden(true)
                    ForEach(chips, id: \.self) { c in
                        Button { backend.send(c) } label: {
                            Text(c).font(.system(size: 11.5, weight: .medium))
                                .padding(.horizontal, 10).padding(.vertical, 5)
                                .background(Capsule().fill(Theme.userBubble.opacity(0.35)))
                                .overlay(Capsule().strokeBorder(Color.white.opacity(0.14)))
                        }
                        .buttonStyle(HoverLift())
                    }
                }
                .padding(.horizontal, 2)
            }
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }
}
