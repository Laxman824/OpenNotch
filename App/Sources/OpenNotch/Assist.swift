import AppKit
import SwiftUI

/// "Ask about this" + writing tools state: what was on screen when the notch
/// opened, and the current rewrite (if any).
@MainActor
final class ContextModel: ObservableObject {
    enum Writing: Equatable {
        case idle
        case working(String)                         // tool label
        case result(tool: String, instruction: String, text: String)
        case failed(String)
    }

    @Published private(set) var ctx = WorkContext()
    @Published var writing: Writing = .idle
    @Published var accessibilityHintDismissed = false

    weak var backend: Backend?
    weak var clipboard: ClipboardStore?
    weak var notch: NotchController?
    weak var captures: CaptureStore?

    var selection: String? { ctx.selectedText }

    /// Called whenever the notch opens.
    func refresh() {
        ContextGrabber.capture { [weak self] c in
            MainActor.assumeIsolated { self?.apply(c) }
        }
    }

    private func apply(_ c: WorkContext) {
        guard let backend else { return }
        // A new selection replaces the old auto-attached one; context from the
        // previous opening shouldn't leak into this question.
        backend.attachments.removeAll { $0.kind == .selection }
        if c.selectedText != ctx.selectedText { writing = .idle }
        ctx = c
        if let sel = c.selectedText {
            backend.attachments.insert(Attachment(kind: .selection, value: sel), at: 0)
            backend.selectionSource = c.appName
        }
    }

    // MARK: writing tools

    struct Tool: Identifiable {
        let id: String
        let icon: String
        let instruction: String
    }

    static let tools: [Tool] = [
        Tool(id: "Rewrite", icon: "wand.and.stars", instruction: "Rewrite this so it reads better. Keep the meaning and roughly the same length."),
        Tool(id: "Shorten", icon: "arrow.down.right.and.arrow.up.left", instruction: "Make this about half as long without losing anything important."),
        Tool(id: "Fix grammar", icon: "checkmark.seal", instruction: "Fix spelling, grammar and punctuation only. Change nothing else."),
        Tool(id: "Professional", icon: "briefcase", instruction: "Rewrite this in a clear, professional tone."),
        Tool(id: "Friendly", icon: "face.smiling", instruction: "Rewrite this in a warm, friendly tone."),
    ]
    static let languages = ["English", "Hindi", "Telugu", "Tamil", "Spanish", "French", "German", "Japanese"]

    func run(_ label: String, instruction: String) {
        guard let text = selection, let backend else { return }
        writing = .working(label)
        backend.transform(text, instruction: instruction) { [weak self] r in
            guard let self, case .working(let l) = self.writing, l == label else { return }   // superseded
            switch r {
            case .success(let t): self.writing = .result(tool: label, instruction: instruction, text: t)
            case .failure(let m): self.writing = .failed(m)
            }
        }
    }

    func retry() {
        if case let .result(tool, instruction, _) = writing { run(tool, instruction: instruction) }
    }

    func replace() {
        guard case let .result(_, _, text) = writing else { return }
        let pid = ctx.pid, app = ctx.appName
        notch?.collapse()
        TextInserter.replaceSelection(in: pid, with: text, clipboard: clipboard) { [weak self] result in
            guard let self else { return }
            switch result {
            case .replaced:
                self.notch?.showAlert(.info(icon: "checkmark.circle", text: "Replaced in \(app)"), for: 2.5)
                self.writing = .idle
                self.ctx.selectedText = text            // what's selected there now
            case .copiedOnly(let msg):
                self.notch?.showAlert(.info(icon: "doc.on.clipboard", text: msg), for: 4)
            }
        }
    }

    func copyResult() {
        guard case let .result(_, _, text) = writing else { return }
        clipboard?.suppressNextChange()
        copyToClipboard(text)
    }

    /// Ask a question about the selection in chat (Explain / Reply).
    func ask(_ prompt: String) {
        backend?.send(prompt)
        writing = .idle
    }

    // MARK: web / finder

    func attachPage() {
        guard let p = ctx.page else { return }
        backend?.attach(Attachment(kind: .web, value: p.title + "\n" + p.url))
    }

    func attachFinder() {
        ctx.finderPaths.forEach { backend?.attach(Attachment(kind: .file, value: $0)) }
    }

    func allowAutomation() {
        guard let name = ctx.needsAutomationFor else { return }
        let bid = ctx.bundleID
        notch?.yieldForSystemPrompt("OpenNotch to read \(name)")
        ContextGrabber.requestAutomation(bundleID: bid) { _ in }
    }
}

// MARK: - Views

/// Chips above the composer: what's on screen, one tap to use it.
struct ContextSuggestions: View {
    @ObservedObject var model: ContextModel
    @ObservedObject var backend: Backend
    @EnvironmentObject var hub: Hub

    var body: some View {
        let c = model.ctx
        let pageAttached = backend.attachments.contains { $0.kind == .web }
        HStack(spacing: 6) {
            if let page = c.page, !pageAttached {
                chip(icon: "safari", text: String(page.title.prefix(34)), subtle: true) { model.attachPage() }
                chip(icon: "text.append", text: "Summarize page") {
                    model.attachPage(); backend.send("Summarize this page in 5 bullets.")
                }
            } else if !c.finderPaths.isEmpty, !backend.attachments.contains(where: { $0.kind == .file }) {
                chip(icon: "folder", text: "\(c.finderPaths.count) selected in Finder", subtle: true) { model.attachFinder() }
            } else if let name = c.needsAutomationFor {
                chip(icon: "lock.open", text: "Let Ledge read \(name)") { model.allowAutomation() }
            } else if c.selectedText == nil, !AXIsProcessTrusted(), !model.accessibilityHintDismissed,
                      !c.appName.isEmpty {
                chip(icon: "hand.raised", text: "Allow Accessibility to use selected text") {
                    model.notch?.yieldForSystemPrompt("Accessibility for OpenNotch")
                    model.captures?.requestTrust()
                }
                Button { model.accessibilityHintDismissed = true } label: {
                    Image(systemName: "xmark").font(.system(size: 8, weight: .bold)).foregroundStyle(Theme.tertiary)
                }.buttonStyle(.plain)
            }
            Spacer(minLength: 0)
        }
        .frame(height: hasAny(c, pageAttached) ? 24 : 0)
        .opacity(hasAny(c, pageAttached) ? 1 : 0)
        .animation(.easeOut(duration: 0.2), value: c)
    }

    private func hasAny(_ c: WorkContext, _ pageAttached: Bool) -> Bool {
        (c.page != nil && !pageAttached) || !c.finderPaths.isEmpty || c.needsAutomationFor != nil
            || (c.selectedText == nil && !AXIsProcessTrusted() && !model.accessibilityHintDismissed && !c.appName.isEmpty)
    }

    private func chip(icon: String, text: String, subtle: Bool = false, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: subtle ? "plus" : icon).font(.system(size: 9, weight: .bold))
                if subtle { Image(systemName: icon).font(.system(size: 10)) }
                Text(text).font(.system(size: 11, weight: .medium)).lineLimit(1)
            }
            .foregroundStyle(subtle ? Theme.secondary : .white)
            .padding(.horizontal, 9).padding(.vertical, 4)
            .background(Capsule().fill(subtle ? AnyShapeStyle(Color.white.opacity(0.06)) : AnyShapeStyle(Theme.userBubble.opacity(0.8))))
            .overlay(Capsule().stroke(Theme.hairline))
        }
        .buttonStyle(HoverLift())
    }
}

/// Writing tools for the current selection — shown in the chat while text is
/// selected and nothing is running.
struct WritingToolsCard: View {
    @ObservedObject var model: ContextModel
    @State private var custom = ""

    var body: some View {
        if let sel = model.selection {
            VStack(alignment: .leading, spacing: 9) {
                HStack(spacing: 6) {
                    Image(systemName: "text.cursor").font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Theme.glow[0])
                    Text("Selected in \(model.ctx.appName.isEmpty ? "your app" : model.ctx.appName)")
                        .font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.secondary)
                    Text("· \(sel.count) chars").font(.system(size: 10)).foregroundStyle(Theme.tertiary)
                    Spacer()
                }
                switch model.writing {
                case .idle, .failed:
                    toolGrid
                    if case .failed(let msg) = model.writing {
                        Text(msg).font(.system(size: 11)).foregroundStyle(.orange)
                    }
                case .working(let label):
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("\(label)…").font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.secondary)
                        Spacer()
                        Button("Cancel") { model.writing = .idle }.buttonStyle(.plain)
                            .font(.system(size: 11)).foregroundStyle(Theme.tertiary)
                    }
                    .frame(height: 28)
                case let .result(tool, _, text):
                    resultView(tool: tool, text: text)
                }
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 14).fill(.white.opacity(0.045)))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(Theme.hairline))
            .padding(.horizontal, 14).padding(.top, 6)
            .transition(.opacity.combined(with: .move(edge: .bottom)))
        }
    }

    private var toolGrid: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                ForEach(ContextModel.tools) { t in
                    toolButton(t.id, icon: t.icon) { model.run(t.id, instruction: t.instruction) }
                }
                Menu {
                    ForEach(ContextModel.languages, id: \.self) { lang in
                        Button(lang) { model.run("Translate", instruction: "Translate this into \(lang).") }
                    }
                } label: {
                    Label("Translate", systemImage: "globe").font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white.opacity(0.85))
                }
                .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
                .padding(.horizontal, 9).padding(.vertical, 5)
                .background(Capsule().fill(.white.opacity(0.07)))
            }
            HStack(spacing: 6) {
                toolButton("Explain", icon: "questionmark.bubble") { model.ask("Explain the selected text simply.") }
                toolButton("Draft reply", icon: "arrowshape.turn.up.left") {
                    model.ask("Draft a reply to the selected message, in my voice. Keep it short.")
                }
                HStack(spacing: 5) {
                    Image(systemName: "sparkles").font(.system(size: 10)).foregroundStyle(Theme.tertiary)
                    TextField("Make it…", text: $custom).textFieldStyle(.plain).font(.system(size: 11.5))
                        .onSubmit {
                            let c = custom.trimmingCharacters(in: .whitespaces)
                            guard !c.isEmpty else { return }
                            model.run("Custom", instruction: c)
                            custom = ""
                        }
                }
                .padding(.horizontal, 9).padding(.vertical, 5)
                .background(Capsule().fill(.white.opacity(0.07)))
            }
        }
    }

    private func toolButton(_ label: String, icon: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(label, systemImage: icon).font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white.opacity(0.85))
                .padding(.horizontal, 9).padding(.vertical, 5)
                .background(Capsule().fill(.white.opacity(0.07)))
        }
        .buttonStyle(HoverLift())
    }

    private func resultView(tool: String, text: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ScrollView {
                Text(text).font(.system(size: 12.5)).foregroundStyle(.white.opacity(0.95))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 130)
            .padding(9)
            .background(RoundedRectangle(cornerRadius: 9).fill(.black.opacity(0.35)))
            HStack(spacing: 8) {
                Text(tool).font(.system(size: 10, weight: .semibold)).foregroundStyle(Theme.tertiary)
                Spacer()
                Button("Discard") { model.writing = .idle }.buttonStyle(.plain)
                    .font(.system(size: 11)).foregroundStyle(Theme.tertiary)
                Button { model.retry() } label: { Label("Try again", systemImage: "arrow.clockwise") }
                    .buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(Theme.secondary)
                Button { model.copyResult() } label: { Label("Copy", systemImage: "doc.on.doc") }
                    .buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(Theme.secondary)
                PillButton(label: "Replace", icon: "checkmark", primary: true) { model.replace() }
                    .help("Put this in place of your selection in \(model.ctx.appName)")
            }
        }
    }
}
