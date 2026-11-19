import Foundation
import PDFKit
import Vision
import AppKit

// search_documents — "when does my lease renew?", "what did the offer letter say about notice?": Spotlight finds
// documents containing the words, then the best-matching passages are pulled out with file and page, so the answer
// can quote and cite them in one step. Everything runs on the Mac (Spotlight's own index; no new index, no uploads).
// Passages are someone else's words (contracts, letters…): fenced like web results.

/// Pure rules (checked in AgentChecks).
enum DocSearchLogic {
    static let stop: Set<String> = ["the", "and", "for", "with", "that", "this", "what", "when", "where", "which", "who", "how",
                                    "does", "did", "say", "says", "about", "from", "into", "my", "our", "your", "are", "was",
                                    "were", "is", "of", "to", "in", "on", "at", "a", "an", "it", "be", "do", "me", "i", "find",
                                    "tell", "show", "document", "documents", "file", "files", "doc", "docs", "pdf", "any", "there"]

    /// Search words: lowercase, ≥ 3 letters (or digits), no filler, unique, at most 6.
    static func terms(_ query: String) -> [String] {
        var out: [String] = []
        for w in query.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted) {
            guard w.count >= 3 || (w.count >= 2 && w.allSatisfy(\.isNumber)), !stop.contains(w), !out.contains(w) else { continue }
            out.append(w)
            if out.count == 6 { break }
        }
        return out
    }

    /// Readable document types (UTIs) Spotlight should look in.
    static let types = ["com.adobe.pdf", "org.openxmlformats.wordprocessingml.document", "public.plain-text",
                        "net.daringfireball.markdown", "public.rtf",
                        "public.image"]                      // screenshots, scanned receipts: Spotlight indexes their text (Live Text)

    /// All words (`any` false) or any word, inside readable documents. Words are sanitised (no quotes/wildcards).
    static func spotlightQuery(_ terms: [String], any: Bool) -> String? {
        let safe = terms.map { $0.filter { $0.isLetter || $0.isNumber } }.filter { !$0.isEmpty }
        guard !safe.isEmpty else { return nil }
        let words = safe.map { "kMDItemTextContent == \"\($0)\"cdw" }.joined(separator: any ? " || " : " && ")
        let kinds = types.map { "kMDItemContentTypeTree == \"\($0)\"" }.joined(separator: " || ")
        return "(\(words)) && (\(kinds))"
    }

    struct Passage: Equatable {
        let page: Int?          // 1-based for PDFs
        let text: String
        let score: Int
    }

    /// The best passages of one document: paragraphs (or ~500-char windows) scored by distinct query words,
    /// then total hits. `pages`: one string per page (PDF) or the whole text as one page (page = nil).
    static func passages(pages: [String], terms: [String], paged: Bool, max: Int = 2) -> [Passage] {
        guard !terms.isEmpty else { return [] }
        var found: [Passage] = []
        for (i, page) in pages.enumerated() {
            for chunk in chunks(page) {
                let low = chunk.lowercased()
                let distinct = terms.filter { low.contains($0) }.count
                guard distinct > 0 else { continue }
                let hits = terms.reduce(0) { $0 + low.components(separatedBy: $1).count - 1 }
                found.append(Passage(page: paged ? i + 1 : nil, text: chunk, score: distinct * 100 + min(hits, 99)))
            }
        }
        return Array(found.sorted { $0.score > $1.score }.prefix(max))
    }

    /// Paragraphs, long ones cut into ~500-char pieces on sentence ends; whitespace tidied.
    static func chunks(_ text: String) -> [String] {
        let paras = text.components(separatedBy: "\n\n").flatMap { p -> [String] in
            let t = p.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces)
            guard t.count > 600 else { return t.count >= 20 ? [t] : [] }
            var out: [String] = [], cur = ""
            for s in t.components(separatedBy: ". ") {
                if cur.count + s.count > 500, !cur.isEmpty { out.append(cur); cur = "" }
                cur += (cur.isEmpty ? "" : ". ") + s
            }
            if cur.count >= 20 { out.append(cur) }
            return out
        }
        return paras.isEmpty && text.count >= 20 ? [String(text.prefix(500))] : paras
    }

    static let imageExts: Set<String> = ["png", "jpg", "jpeg", "heic", "tiff", "tif", "gif", "webp", "bmp"]
    static func isImage(_ path: String) -> Bool { imageExts.contains((path as NSString).pathExtension.lowercased()) }

    static func format(file: String, passages: [Passage]) -> String {
        passages.map { p in
            "\((file as NSString).lastPathComponent)" + (p.page.map { ", page \($0)" } ?? "") + ": “" + String(p.text.prefix(600)) + "”"
        }.joined(separator: "\n")
    }
}

enum DocSearch {
    static func all() -> [AgentTool] { [tool] }

    static let tool = AgentTool(
        name: "search_documents",
        description: "Answer questions from the user's own documents (PDF, Word, RTF, text, Markdown) and images with text "
            + "in them (screenshots, photographed receipts and letters) — \"when does my lease renew\", \"what's the notice period "
            + "in my offer letter\", \"the receipt for my headphones\". Finds them with Spotlight and returns the best "
            + "passages with file and page; quote them and cite \"file, page\". Use spotlight_search to just find files.",
        schema: Schema.object(["query": Schema.string("The question or key words, e.g. 'lease renewal date'"),
                               "days": Schema.integer("Only documents changed in the last N days (optional)"),
                               "folder": Schema.string("Only inside this folder (optional, default: home)")],
                              required: ["query"]),
        risk: .read, verb: "Searching your documents", detail: { $0.str("query") ?? "" }, preview: { _ in "" },
        run: { a in await run(a) })

    static func run(_ a: ToolArgs) async -> ToolOutcome {
        let terms = DocSearchLogic.terms(a.str("query") ?? "")
        guard !terms.isEmpty else { return .fail("Give a few key words to look for (e.g. 'lease renewal date').") }
        var dir = PathPolicy.home
        if let f = a.str("folder") {
            let p = PathPolicy.resolve(f)
            if let problem = PathPolicy.check(p, write: false) { return .fail(problem) }
            dir = p
        }
        var files: [String] = []
        for any in [false, true] {                                    // every word first, then any word
            guard var q = DocSearchLogic.spotlightQuery(terms, any: any) else { break }
            if let d = a.int("days"), d > 0 { q += " && kMDItemContentModificationDate >= $time.today(-\(min(d, 3650)))" }
            let r = Proc.run("/usr/bin/mdfind", ["-onlyin", dir, q], timeout: 20)
            files = r.out.split(separator: "\n").map(String.init).filter { MacToolLogic.keep($0, kind: .document) }
            if !files.isEmpty || terms.count == 1 { break }
        }
        if files.isEmpty { return ToolOutcome(ok: true, text: "No documents on this Mac mention \(terms.joined(separator: ", ")).") }
        let fm = FileManager.default
        // At most 3 images among the 8 read (each needs on-device text recognition).
        var images = 0
        files = files.filter { f in
            guard DocSearchLogic.isImage(f) else { return true }
            images += 1
            return images <= 3
        }
        let newest = files.prefix(200).map { p in (p, (try? fm.attributesOfItem(atPath: p))?[.modificationDate] as? Date ?? .distantPast) }
            .sorted { $0.1 > $1.1 }.prefix(8).map(\.0)
        let deadline = Date().addingTimeInterval(12)
        var scored: [(file: String, passages: [DocSearchLogic.Passage])] = []
        for f in newest where Date() < deadline {
            let (pages, paged) = text(of: f)
            let ps = DocSearchLogic.passages(pages: pages, terms: terms, paged: paged)
            if !ps.isEmpty { scored.append((f, ps)) }
        }
        guard !scored.isEmpty else {
            return ToolOutcome(ok: true, text: "Spotlight matched \(files.count) document(s) but I couldn't read matching text in the newest ones:\n"
                               + newest.joined(separator: "\n"))
        }
        let ranked = scored.sorted { ($0.passages.first?.score ?? 0) > ($1.passages.first?.score ?? 0) }.prefix(4)
        return ToolOutcome(ok: true, text: "\(files.count) document(s) match; best passages:\n"
                           + ranked.map { "\($0.file)\n" + DocSearchLogic.format(file: $0.file, passages: $0.passages) }.joined(separator: "\n\n"))
    }

    /// A document's text: PDFs page by page (≤ 80 pages), Word/RTF/text as one block (≤ 300k chars).
    static func text(of path: String) -> (pages: [String], paged: Bool) {
        let ext = (path as NSString).pathExtension.lowercased()
        if DocSearchLogic.isImage(path) { return ([ocr(path)], false) }
        if ext == "pdf", let doc = PDFDocument(url: URL(fileURLWithPath: path)) {
            return ((0..<min(doc.pageCount, 80)).compactMap { doc.page(at: $0)?.string }, true)
        }
        var s = ""
        switch ext {
        case "docx":
            let r = Proc.run("/usr/bin/unzip", ["-p", path, "word/document.xml"], timeout: 10)
            s = ToolKit.decodeEntities(r.out.replacingOccurrences(of: "</w:p>", with: "\n\n")
                .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression))
        case "rtf":
            let r = Proc.run("/usr/bin/textutil", ["-convert", "txt", "-stdout", path], timeout: 10)
            s = r.out
        default:
            if let d = FileManager.default.contents(atPath: path), d.count < 5_000_000, !d.prefix(4000).contains(0) {
                s = String(decoding: d, as: UTF8.self)
            }
        }
        return ([String(s.prefix(300_000))], false)
    }

    /// Text in an image, recognised on the Mac (Vision), lines joined into paragraphs.
    static func ocr(_ path: String) -> String {
        guard let img = NSImage(contentsOfFile: path)?.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return "" }
        let req = VNRecognizeTextRequest()
        req.recognitionLevel = .accurate
        req.usesLanguageCorrection = true
        try? VNImageRequestHandler(cgImage: img).perform([req])
        let lines = (req.results ?? []).compactMap { $0.topCandidates(1).first?.string }
        return MacToolLogic.joinLines(lines)
    }
}
