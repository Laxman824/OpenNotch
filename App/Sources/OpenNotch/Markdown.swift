import AppKit
import SwiftUI

/// Small block-level Markdown renderer: fenced code, headings, bullets,
/// numbered lists, quotes and paragraphs. Inline styling (bold, code, links)
/// goes through AttributedString's own parser.
enum MDBlock: Hashable {
    case code(lang: String, text: String)
    case heading(level: Int, text: String)
    case bullet(indent: Int, text: String)
    case numbered(n: String, text: String)
    case quote(String)
    case paragraph(String)
    case rule
}

func parseMarkdown(_ src: String) -> [MDBlock] {
    var blocks: [MDBlock] = []
    var para: [String] = []
    var code: [String]? = nil
    var lang = ""

    func flush() {
        if !para.isEmpty { blocks.append(.paragraph(para.joined(separator: "\n"))); para = [] }
    }

    for raw in src.components(separatedBy: "\n") {
        let line = raw
        let t = line.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("```") {
            if let c = code {
                blocks.append(.code(lang: lang, text: c.joined(separator: "\n")))
                code = nil
            } else {
                flush()
                code = []
                lang = String(t.dropFirst(3)).trimmingCharacters(in: .whitespaces)
            }
            continue
        }
        if code != nil { code!.append(line); continue }
        if t.isEmpty { flush(); continue }
        if t == "---" || t == "***" { flush(); blocks.append(.rule); continue }
        if let m = t.firstIndex(where: { $0 != "#" }), t.hasPrefix("#"),
           t[m] == " ", t.distance(from: t.startIndex, to: m) <= 4 {
            flush()
            blocks.append(.heading(level: t.distance(from: t.startIndex, to: m),
                                   text: String(t[m...]).trimmingCharacters(in: .whitespaces)))
            continue
        }
        if t.hasPrefix("- ") || t.hasPrefix("* ") || t.hasPrefix("• ") {
            flush()
            let indent = (line.count - line.drop(while: { $0 == " " }).count) / 2
            blocks.append(.bullet(indent: indent, text: String(t.dropFirst(2))))
            continue
        }
        if let dot = t.firstIndex(of: "."), t[..<dot].allSatisfy(\.isNumber), !t[..<dot].isEmpty,
           t.index(after: dot) < t.endIndex, t[t.index(after: dot)] == " " {
            flush()
            blocks.append(.numbered(n: String(t[..<dot]), text: String(t[t.index(dot, offsetBy: 2)...])))
            continue
        }
        if t.hasPrefix("> ") { flush(); blocks.append(.quote(String(t.dropFirst(2)))); continue }
        para.append(line)
    }
    if let c = code { blocks.append(.code(lang: lang, text: c.joined(separator: "\n"))) }
    flush()
    return blocks
}

func inlineMD(_ s: String) -> AttributedString {
    var a = (try? AttributedString(markdown: s, options: .init(
        interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(s)
    // File paths Ledge mentions become clickable (opens the file).
    let plain = String(a.characters)
    if plain.contains("/") || plain.contains("~"),
       let rx = try? NSRegularExpression(pattern: #"(~|/Users/[^/\s]+)(/[^\s`'"(),;:*]+)+"#) {
        for m in rx.matches(in: plain, range: NSRange(plain.startIndex..., in: plain)) {
            guard let r = Range(m.range, in: plain) else { continue }
            let raw = String(plain[r]).trimmingCharacters(in: CharacterSet(charactersIn: ".]"))
            let path = (raw as NSString).expandingTildeInPath
            guard FileManager.default.fileExists(atPath: path), let ar = a.range(of: raw) else { continue }
            a[ar].link = URL(fileURLWithPath: path)
            a[ar].underlineStyle = .single
        }
    }
    for run in a.runs where run.inlinePresentationIntent?.contains(.code) == true {
        a[run.range].font = .system(size: 12, design: .monospaced)
        a[run.range].backgroundColor = Color.white.opacity(0.10)
        a[run.range].foregroundColor = Color(red: 1.0, green: 0.78, blue: 0.55)
    }
    return a
}

func copyToClipboard(_ s: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(s, forType: .string)
}

struct MarkdownView: View {
    let text: String
    var streaming = false

    var body: some View {
        let blocks = parseMarkdown(text)
        VStack(alignment: .leading, spacing: 7) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { i, b in
                block(b, last: i == blocks.count - 1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func caret(_ last: Bool) -> AttributedString {
        guard last && streaming else { return AttributedString("") }
        var c = AttributedString(" ●")
        c.foregroundColor = Color.white.opacity(0.5)
        c.font = .system(size: 8)
        return c
    }

    @ViewBuilder
    private func block(_ b: MDBlock, last: Bool) -> some View {
        switch b {
        case let .code(lang, code):
            CodeBlock(lang: lang, code: code)
        case let .heading(level, t):
            Text(inlineMD(t) + caret(last))
                .font(.system(size: level <= 1 ? 16 : level == 2 ? 14.5 : 13.5, weight: .bold, design: .rounded))
                .padding(.top, 2)
        case let .bullet(indent, t):
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                Circle().fill(Color.white.opacity(0.45)).frame(width: 4, height: 4)
                    .alignmentGuide(.firstTextBaseline) { $0[.bottom] + 1 }
                Text(inlineMD(t) + caret(last))
            }
            .padding(.leading, CGFloat(indent) * 14 + 2)
        case let .numbered(n, t):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("\(n).").foregroundStyle(.white.opacity(0.5)).monospacedDigit()
                Text(inlineMD(t) + caret(last))
            }
        case let .quote(t):
            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 1).fill(Color.white.opacity(0.25)).frame(width: 3)
                Text(inlineMD(t) + caret(last)).foregroundStyle(.white.opacity(0.7))
            }
        case let .paragraph(t):
            Text(inlineMD(t) + caret(last))
        case .rule:
            Divider().overlay(Color.white.opacity(0.15))
        }
    }
}

struct CodeBlock: View {
    let lang: String
    let code: String
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(lang.isEmpty ? "code" : lang)
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.45))
                Spacer()
                Button {
                    copyToClipboard(code)
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { copied = false }
                } label: {
                    Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(copied ? .green : .white.opacity(0.6))
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(Color.white.opacity(0.05))
            ScrollView(.horizontal, showsIndicators: false) {
                Text(code)
                    .font(.system(size: 11.5, design: .monospaced))
                    .foregroundStyle(Color(red: 0.86, green: 0.9, blue: 1.0))
                    .textSelection(.enabled)
                    .padding(10)
            }
        }
        .background(RoundedRectangle(cornerRadius: 9).fill(Color(white: 0.09)))
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(Color.white.opacity(0.08)))
        .clipShape(RoundedRectangle(cornerRadius: 9))
    }
}
