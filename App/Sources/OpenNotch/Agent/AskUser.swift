import Foundation

/// A choice the model put to the user (`ask_user`): shown as buttons in the notch, spoken in hands-free.
struct Question: Identifiable, Equatable {
    let id: String
    let text: String
    let options: [String]
    var detail: String? = nil
    /// What hands-free says ("Which Sam? Option 1: Sam Lee. Option 2: Sam Park. Or say something else.").
    var spoken: String { AskLogic.spoken(text, options: options) }
}

/// Pure rules for `ask_user`: what a valid question is, how an answer (clicked, typed or said) is read,
/// and what the model is told. Narrow on purpose (rule 9): a spoken answer picks an option only when it
/// *is* that option — a number, an ordinal or the option's own words — never because it shares a word.
enum AskLogic {
    static let maxOptions = 4
    static let maxLabel = 60
    static let maxQuestion = 300
    static let timeout: TimeInterval = 300

    struct Parsed: Equatable { let question: String; let options: [String]; let detail: String? }

    /// Validates the model's arguments: a question, 2–4 distinct short options, optional detail.
    static func parse(_ args: [String: Any]) -> Result<Parsed, ToolError> {
        let q = (args["question"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return .failure(ToolError("question is required")) }
        var opts: [String] = []
        for raw in args["options"] as? [Any] ?? [] {
            guard let s = raw as? String else { continue }
            let o = String(s.trimmingCharacters(in: .whitespacesAndNewlines).prefix(maxLabel))
            if !o.isEmpty && !opts.contains(where: { $0.lowercased() == o.lowercased() }) { opts.append(o) }
        }
        guard opts.count >= 2 else {
            return .failure(ToolError("Give 2 to \(maxOptions) different options. For an open question, just ask it in your answer."))
        }
        guard opts.count <= maxOptions else { return .failure(ToolError("At most \(maxOptions) options — keep the likeliest.")) }
        let detail = (args["detail"] as? String).map { String($0.trimmingCharacters(in: .whitespacesAndNewlines).prefix(600)) }
        return .success(Parsed(question: String(q.prefix(maxQuestion)), options: opts, detail: detail?.isEmpty == true ? nil : detail))
    }

    static func spoken(_ question: String, options: [String]) -> String {
        question + " " + options.enumerated().map { "Option \($0.offset + 1): \($0.element)." }.joined(separator: " ")
            + " Or say something else."
    }

    private static let numbers = [["1", "one", "first"], ["2", "two", "second"], ["3", "three", "third"], ["4", "four", "fourth"]]
    /// "2", "two", "option two", "the second one", "number 2", "I'd like the first one please"
    private static let numberPattern = #"^(?:(?:i'?d like|i would like|let'?s go with|go with|i choose|i pick|pick|choose|number|option|the)\s+)*"#
        + #"(1|one|first|2|two|second|3|three|third|4|four|fourth)(?:\s+(?:one|option|please|thanks))*$"#

    /// The option a spoken or typed answer picks, or nil (then it's taken as the user's own words).
    static func match(_ answer: String, options: [String]) -> String? {
        let a = normalise(answer)
        guard !a.isEmpty else { return nil }
        if let exact = options.first(where: { normalise($0) == a }) { return exact }
        if let rx = try? NSRegularExpression(pattern: numberPattern),
           let m = rx.firstMatch(in: a, range: NSRange(a.startIndex..., in: a)),
           let r = Range(m.range(at: 1), in: a),
           let i = numbers.firstIndex(where: { $0.contains(String(a[r])) }), i < options.count {
            return options[i]
        }
        // One option's own words plus a little filler ("Sam Lee please") — only when exactly one option fits.
        let hits = options.filter { o in
            let n = normalise(o)
            return n.count >= 3 && (a.hasPrefix(n + " ") || a.hasSuffix(" " + n))
                && a.split(separator: " ").count <= n.split(separator: " ").count + 2
        }
        return hits.count == 1 ? hits[0] : nil
    }

    static func normalise(_ s: String) -> String {
        s.lowercased().replacingOccurrences(of: "[^a-z0-9' ]", with: " ", options: .regularExpression)
            .replacingOccurrences(of: " +", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }

    /// What the model gets back.
    static func result(answer: String?, chosen: Bool) -> String {
        guard let answer, !answer.isEmpty else {
            return "The user didn't answer. Don't ask again in this turn: go with the safest choice or say what you need in your reply."
        }
        return chosen ? "The user chose: \(answer)" : "The user answered in their own words: \(answer)"
    }

    static let tool = AgentTool(
        name: "ask_user",
        description: "Ask the user to choose before you continue, when the choice is theirs and you can't tell from context "
            + "(which contact, which file, which of two plans). Shown as buttons; the user can also type or say their own answer. "
            + "2–4 short options, most likely first. Not for permission — risky tools already ask — and not for open questions.",
        schema: #"{"type":"object","properties":{"question":{"type":"string","description":"One short question"},"options":{"type":"array","items":{"type":"string"},"description":"2-4 short answers"},"detail":{"type":"string","description":"Optional context shown under the question"}},"required":["question","options"]}"#,
        risk: .read, verb: "Asking you", detail: { $0.str("question") ?? "" },
        preview: { _ in "" },
        // Only reached outside a chat (background jobs, self-test): AgentCore answers it in a chat.
        run: { _ in .fail("No one is here to answer. Decide with the safest choice, or say what you need in your answer.") })
}

struct ToolError: Error, Equatable {
    let message: String
    init(_ m: String) { message = m }
}
