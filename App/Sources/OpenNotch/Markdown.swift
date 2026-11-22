import AppKit
import SwiftUI

/// Small block-level Markdown renderer: fenced code, headings, bullets,
/// numbered lists, quotes, tables and paragraphs. Inline styling (bold, code, links)
/// goes through AttributedString's own parser.
enum MDBlock: Hashable {
    case code(lang: String, text: String)
    case heading(level: Int, text: String)
    case bullet(indent: Int, text: String)
    case numbered(n: String, text: String)
    case quote(String)
    case paragraph(String)
    case rule
    /// A pipe table: header cells, body rows (padded to the header's width), per-column alignment.
    case table(header: [String], rows: [[String]], align: [MDAlign])
}

enum MDAlign: Hashable { case leading, center, trailing }

/// Pipe-table helpers (GitHub style: a header row, then a `|---|:--:|` separator row).
enum MDTable {
    /// Cells of one row; `\|` stays a literal pipe.
    static func cells(_ line: String) -> [String] {
        var t = line.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "\\|", with: "\u{1}")
        if t.hasPrefix("|") { t.removeFirst() }
        if t.hasSuffix("|") { t.removeLast() }
        return t.components(separatedBy: "|").map {
            $0.replacingOccurrences(of: "\u{1}", with: "|").trimmingCharacters(in: .whitespaces)
        }
    }

    /// The separator row's alignments, or nil if the line isn't one.
    static func separator(_ line: String) -> [MDAlign]? {
        let t = line.trimmingCharacters(in: .whitespaces)
        guard t.contains("-"), t.contains("|") || t.hasPrefix(":") || t.hasPrefix("-") else { return nil }
        var out: [MDAlign] = []
        for c in cells(t) {
            guard c.range(of: #"^:?-{1,}:?$"#, options: .regularExpression) != nil else { return nil }
            out.append(c.hasPrefix(":") && c.hasSuffix(":") ? .center : c.hasSuffix(":") ? .trailing : .leading)
        }
        return out.isEmpty ? nil : out
    }
}

func parseMarkdown(_ src: String) -> [MDBlock] {
    var blocks: [MDBlock] = []
    var para: [String] = []
    var code: [String]? = nil
    var lang = ""

    func flush() {
        if !para.isEmpty { blocks.append(.paragraph(para.joined(separator: "\n"))); para = [] }
    }

    let lines = src.components(separatedBy: "\n")
    var i = 0
    while i < lines.count {
        let line = lines[i]
        i += 1
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
        // A table: a row with pipes followed by a separator row.
        if t.contains("|"), i < lines.count, let align = MDTable.separator(lines[i]) {
            let header = MDTable.cells(t)
            if header.count == align.count || header.count > 1 {
                flush()
                i += 1
                var rows: [[String]] = []
                while i < lines.count {
                    let r = lines[i].trimmingCharacters(in: .whitespaces)
                    guard !r.isEmpty, r.contains("|") else { break }
                    var cells = MDTable.cells(r)
                    if cells.count < header.count { cells += Array(repeating: "", count: header.count - cells.count) }
                    rows.append(Array(cells.prefix(header.count)))
                    i += 1
                }
                let al = (0..<header.count).map { $0 < align.count ? align[$0] : .leading }
                blocks.append(.table(header: header, rows: rows, align: al))
                continue
            }
        }
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
        case let .table(header, rows, align):
            TableBlock(header: header, rows: rows, align: align)
        }
    }
}

/// "Ask about this table": put the table in the composer as an attachment (set by `Transcript`).
private struct AskAboutKey: EnvironmentKey { static let defaultValue: ((String) -> Void)? = nil }
extension EnvironmentValues {
    var askAbout: ((String) -> Void)? {
        get { self[AskAboutKey.self] }
        set { self[AskAboutKey.self] = newValue }
    }
}

/// A Markdown table, made to be used (after ChatGPT's data tables): a bar with the size, Copy (pastes as cells),
/// Save CSV and Ask about this; click a column to sort (numbers as numbers); long tables fold to 8 rows; striped rows;
/// long cells wrap at a column cap and wide tables scroll sideways.
struct TableBlock: View {
    let header: [String]
    let rows: [[String]]
    let align: [MDAlign]
    @Environment(\.askAbout) private var askAbout
    @State private var sort: (column: Int, ascending: Bool)?
    @State private var showAll = false
    @State private var copied = false
    @State private var saved = false

    static let folded = 8

    private var sorted: [[String]] { TableLogic.sorted(rows, column: sort?.column, ascending: sort?.ascending ?? true) }
    private var visible: [[String]] { showAll ? sorted : Array(sorted.prefix(Self.folded)) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            bar
            // Scroll sideways only when the table is wider than the chat.
            ViewThatFits(in: .horizontal) {
                grid.frame(maxWidth: .infinity, alignment: .leading)
                ScrollView(.horizontal, showsIndicators: false) { grid }
            }
            if rows.count > Self.folded {
                Button { withAnimation(.easeOut(duration: 0.18)) { showAll.toggle() } } label: {
                    Text(showAll ? "Show fewer" : "Show all \(rows.count) rows")
                        .font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.secondary)
                        .frame(maxWidth: .infinity).padding(.vertical, 6).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .background(RoundedRectangle(cornerRadius: 9).fill(Color.white.opacity(0.05)))
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(Color.white.opacity(0.08)))
        .clipShape(RoundedRectangle(cornerRadius: 9))
        .contextMenu {
            Button("Copy table") { copyToClipboard(TableLogic.tsv(header, sorted)) }
            Button("Copy as Markdown") { copyToClipboard(TableLogic.markdown(header, sorted, align)) }
            Button("Save as CSV in Downloads") { saveCSV() }
        }
    }

    private var grid: some View {
            Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 0) {
                GridRow {
                    ForEach(header.indices, id: \.self) { c in headerCell(c).gridColumnAlignment(alignment(c)) }
                }
                Divider().overlay(Color.white.opacity(0.18))
                ForEach(Array(visible.enumerated()), id: \.offset) { r, row in
                    GridRow {
                        ForEach(header.indices, id: \.self) { c in
                            cell(c < row.count ? row[c] : "", column: c).font(.system(size: 12))
                                .foregroundStyle(.white.opacity(0.85))
                        }
                    }
                    .background(r % 2 == 1 ? Color.white.opacity(0.035) : .clear)
                }
            }
            .padding(.horizontal, 4).padding(.bottom, 4)
    }

    private var bar: some View {
        HStack(spacing: 10) {
            Image(systemName: "tablecells").font(.system(size: 10, weight: .semibold)).foregroundStyle(.white.opacity(0.45))
            Text("\(rows.count) row\(rows.count == 1 ? "" : "s") · \(header.count) column\(header.count == 1 ? "" : "s")")
                .font(.system(size: 10, weight: .semibold, design: .monospaced)).foregroundStyle(.white.opacity(0.45))
            Spacer()
            barButton(copied ? "Copied" : "Copy", copied ? "checkmark" : "doc.on.doc",
                      help: "Copy — pastes into Numbers, Excel or Sheets as cells") {
                copyToClipboard(TableLogic.tsv(header, sorted)); copied = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { copied = false }
            }
            barButton(saved ? "Saved" : "CSV", saved ? "checkmark" : "arrow.down.doc", help: "Save as CSV in Downloads") { saveCSV() }
            if let askAbout {
                barButton("Ask", "bubble.left", help: "Ask about this table") { askAbout(TableLogic.markdown(header, sorted, align)) }
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 5)
        .background(Color.white.opacity(0.05))
    }

    private func barButton(_ label: String, _ icon: String, help: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(label, systemImage: icon).font(.system(size: 10, weight: .medium)).foregroundStyle(.white.opacity(0.65))
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private func headerCell(_ c: Int) -> some View {
        Button {
            withAnimation(.easeOut(duration: 0.15)) {
                if sort?.column != c { sort = (c, true) } else if sort?.ascending == true { sort = (c, false) } else { sort = nil }
            }
        } label: {
            HStack(spacing: 3) {
                Text(inlineMD(header[c])).font(.system(size: 12, weight: .semibold)).foregroundStyle(.white.opacity(0.92))
                    .multilineTextAlignment(textAlign(c))
                if sort?.column == c {
                    Image(systemName: sort?.ascending == true ? "chevron.up" : "chevron.down")
                        .font(.system(size: 8, weight: .bold)).foregroundStyle(.white.opacity(0.6))
                }
            }
            .frame(maxWidth: 240, alignment: Alignment(horizontal: alignment(c), vertical: .center))
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 8).padding(.vertical, 7)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Sort by \(header[c])")
    }

    private func cell(_ s: String, column: Int) -> some View {
        Text(inlineMD(s)).textSelection(.enabled).monospacedDigit()
            .multilineTextAlignment(textAlign(column))
            .frame(maxWidth: 240, alignment: Alignment(horizontal: alignment(column), vertical: .top))
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 8).padding(.vertical, 6)
    }

    private func saveCSV() {
        let dir = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory())
        let name = "OpenNotch table \(Date().formatted(.iso8601.year().month().day().time(includingFractionalSeconds: false)).replacingOccurrences(of: ":", with: "."))"
        let url = dir.appendingPathComponent(name).appendingPathExtension("csv")
        let csv = TableLogic.csv(header, sorted)
        DispatchQueue.global(qos: .userInitiated).async {          // Downloads is TCC-protected: never on main (rule 13)
            let ok = (try? csv.write(to: url, atomically: true, encoding: .utf8)) != nil
            DispatchQueue.main.async {
                guard ok else { return }
                saved = true
                NSWorkspace.shared.activateFileViewerSelecting([url])
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { saved = false }
            }
        }
    }

    private func alignment(_ c: Int) -> HorizontalAlignment {
        switch align[c] { case .leading: return .leading; case .center: return .center; case .trailing: return .trailing }
    }
    private func textAlign(_ c: Int) -> TextAlignment {
        switch align[c] { case .leading: return .leading; case .center: return .center; case .trailing: return .trailing }
    }
}

/// Table helpers, pure (checked by `--checks`).
enum TableLogic {
    /// A cell as a number when it reads as one: "1,234", "$9.50", "-3°", "45%", "12 ms" (leading number). Else nil.
    static func number(_ s: String) -> Double? {
        let t = s.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: ",", with: "")
            .trimmingCharacters(in: .whitespaces)
        // Up to 3 leading symbols ($, €, ~), the number, then at most a short unit (%, °, ms, kg) — "2026-11-22" isn't one.
        guard t.range(of: #"^[^\d\-+.]{0,3}[-+]?\d*\.?\d+\s?[^\d\s]{0,6}$"#, options: .regularExpression) != nil,
              let r = t.range(of: #"[-+]?\d*\.?\d+"#, options: .regularExpression) else { return nil }
        return Double(t[r])
    }

    /// Rows sorted by a column: numbers numerically when every non-empty cell is one, else text (case/diacritic-blind);
    /// empty cells last; ties keep their order. nil column = as given.
    static func sorted(_ rows: [[String]], column: Int?, ascending: Bool) -> [[String]] {
        guard let c = column else { return rows }
        let vals = rows.map { c < $0.count ? $0[c] : "" }
        let numeric = vals.filter { !$0.isEmpty }.allSatisfy { number($0) != nil }
        let idx = rows.indices.sorted { a, b in
            let x = vals[a], y = vals[b]
            if x.isEmpty != y.isEmpty { return !x.isEmpty }            // empties last either way
            if x.isEmpty { return a < b }
            let order: ComparisonResult = numeric
                ? (number(x)! < number(y)! ? .orderedAscending : number(x)! > number(y)! ? .orderedDescending : .orderedSame)
                : x.compare(y, options: [.caseInsensitive, .diacriticInsensitive, .numeric])
            if order == .orderedSame { return a < b }
            return ascending ? order == .orderedAscending : order == .orderedDescending
        }
        return idx.map { rows[$0] }
    }

    /// Markdown emphasis removed for exports.
    static func plain(_ s: String) -> String {
        s.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "`", with: "")
    }

    static func tsv(_ header: [String], _ rows: [[String]]) -> String {
        ([header] + rows).map { $0.map { plain($0).replacingOccurrences(of: "\t", with: " ") }.joined(separator: "\t") }
            .joined(separator: "\n")
    }

    /// RFC 4180: quote cells with commas, quotes or newlines; double the quotes. Cells starting with = + - @ get a
    /// leading ' so a spreadsheet doesn't run them as formulas.
    static func csv(_ header: [String], _ rows: [[String]]) -> String {
        func field(_ raw: String) -> String {
            var v = plain(raw)
            if let f = v.first, "=+@".contains(f) || (f == "-" && number(v) == nil) { v = "'" + v }
            return v.contains(where: { ",\"\n\r".contains($0) }) ? "\"" + v.replacingOccurrences(of: "\"", with: "\"\"") + "\"" : v
        }
        return ([header] + rows).map { $0.map(field).joined(separator: ",") }.joined(separator: "\r\n") + "\r\n"
    }

    static func markdown(_ header: [String], _ rows: [[String]], _ align: [MDAlign]) -> String {
        func line(_ cells: [String]) -> String { "| " + cells.map { $0.replacingOccurrences(of: "|", with: "\\|") }.joined(separator: " | ") + " |" }
        let sep = "|" + align.map { $0 == .center ? ":---:" : $0 == .trailing ? "---:" : "---" }.joined(separator: "|") + "|"
        return ([line(header), sep] + rows.map(line)).joined(separator: "\n")
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
