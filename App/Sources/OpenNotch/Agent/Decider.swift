import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Pure parts of the routing decider: which engine runs, exactly what it's sent, how answers are read.
///
/// The keyword router (`ToolRouter`) misses requests phrased in ways its patterns don't know. Before each
/// turn a small, fast model can name the tool groups the message needs. It only ever **adds** groups to
/// what the keywords found — never removes — so the worst case is a few extra tool schemas.
/// Engines: Apple on-device (free, private, the default where available) or Jev (TypeSafe's decision
/// model through OpenRouter; paid per input token, opt-in only). Approvals don't change either way.
enum DecisionLogic {
    enum Engine: String { case off, apple, jev }

    static let pref = "router.decider"
    static let maxGroups = 4
    static let maxMessageChars = 1000
    static let jevThreshold = 0.6
    static let timeout: Double = 1.5
    static let jevModel = "typesafe/jev-1.13"
    static let jevURL = URL(string: "https://openrouter.ai/api/alpha/decisions")!

    /// What each built-in group is for, in words a small model can match against.
    static let blurbs: [String: String] = [
        "files": "change, create or edit files and code, or search inside files",
        "mail": "read, check, draft, reply to or send email",
        "calendar": "calendar events, meetings, the day's plan, reminders and to-dos",
        "notes_app": "Apple Notes: find, read or create a note",
        "contacts": "look up a person's phone number, email address or birthday",
        "weather": "weather, rain, temperature or the forecast",
        "browser": "the web page or tab open in the browser",
        "schedule": "do something automatically at a time or repeatedly (every day, every Monday at 9)",
        "music": "play, pause or change music, songs or volume",
        "awake": "keep the Mac awake or stop it sleeping",
        "shortcuts": "run the user's Apple Shortcuts, Focus or Do Not Disturb, smart-home scenes, send a message",
        "screen": "the text of what's on screen or in the window the user is looking at (this email, this document)",
        "routines": "save, run or export a named routine, or turn something into an Apple Shortcut or Siri command",
        "watch": "keep checking something in the background and tell the user when it happens (\"let me know when …\")",
        "find": "find a document, PDF, photo or file on the Mac by content, kind, person or date",
    ]

    static func blurb(_ g: ToolRouter.Group) -> String {
        blurbs[g.name] ?? "the connected service \(g.name)"
    }

    /// The engine to use, or nil for keywords only. Jev runs only when the user picked it (never as a
    /// fallback — it sends text to another company and costs money); Apple is the default where available.
    static func engine(pref: String?, appleReady: Bool, hasOpenRouterKey: Bool) -> Engine? {
        switch Engine(rawValue: pref ?? Engine.apple.rawValue) ?? .apple {
        case .off: return nil
        case .apple: return appleReady ? .apple : nil
        case .jev: return hasOpenRouterKey ? .jev : nil
        }
    }

    static func shouldDecide(keywordGroups: Set<String>) -> Bool { keywordGroups.isEmpty }

    /// Groups the decider may add: everything the router knows except connectors already sent every time.
    static func candidates(connectors: [ToolRouter.Group]) -> [ToolRouter.Group] {
        (ToolRouter.groups + connectors).filter { !$0.always }
    }

    /// Only what the user typed in the last two messages — never attached page text, clipboard, files,
    /// memories, the time stamp or earlier answers — capped at `maxMessageChars` (newest text kept).
    static func message(_ conversation: [ChatMessage]) -> String {
        let typed = conversation.filter { $0.role == .user && $0.toolCallId == nil }.suffix(2)
            .map { ($0.text.components(separatedBy: AgentCore.contextMarker).first ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
        return String(typed.suffix(maxMessageChars))
    }

    // MARK: Jev (OpenRouter decisions API)

    /// One yes/no question per group, keyed g0, g1, … (names may hold characters the API won't take as keys).
    static func jevBody(message: String, groups: [ToolRouter.Group]) -> [String: Any] {
        var questions: [String: Any] = [:]
        for (i, g) in groups.enumerated() {
            questions["g\(i)"] = [
                "type": "noul",
                "instructions": "Would an assistant need tools for this to handle the user's message: \(blurb(g))?",
                "criteria": ["true": "The message asks for or clearly needs this", "false": "The message is about something else"],
            ] as [String: Any]
        }
        return ["model": jevModel, "state": ["user_message": message], "questions": questions]
    }

    /// Groups whose yes-probability reaches the threshold, most likely first, at most `maxGroups`.
    static func parseJev(_ obj: [String: Any], groups: [ToolRouter.Group]) -> [String] {
        guard let answers = obj["answers"] as? [String: Any] else { return [] }
        let scored: [(String, Double)] = groups.enumerated().compactMap { i, g in
            guard let a = answers["g\(i)"] as? [String: Any], let p = (a["noul"] as? NSNumber)?.doubleValue,
                  p >= jevThreshold else { return nil }
            return (g.name, p)
        }
        return scored.sorted { $0.1 > $1.1 }.prefix(maxGroups).map(\.0)
    }

    // MARK: Apple on-device (guided generation)

    static let none = "none"

    static let appleInstructions = """
        You route requests for a Mac assistant. Pick the tool groups the user's message needs, or "none". \
        Answer "none" when general knowledge, maths, translation, writing, memory, timers, web search, reading \
        web pages, files or shell commands are enough — those are always available. \
        Never pick a group just because a word looks similar (a weekday is not a service).
        """

    static func applePrompt(message: String, groups: [ToolRouter.Group]) -> String {
        "Tool groups:\n" + groups.map { "- \($0.name): \(blurb($0))" }.joined(separator: "\n")
            + "\n- none: the message needs none of these"
            + "\n\nUser's message:\n\(message)\n\nWhich groups does it need (at most \(maxGroups))?"
    }

    /// The generated `{"groups": [...]}` → known names only, in order, no repeats, at most `maxGroups`.
    static func parseApple(json: String, groups: [ToolRouter.Group]) -> [String] {
        let known = Set(groups.map(\.name))
        var out: [String] = []
        for n in HTTP.parse(json)?["groups"] as? [String] ?? [] where known.contains(n) && !out.contains(n) { out.append(n) }
        return Array(out.prefix(maxGroups))
    }
}

/// Runs the chosen engine before a turn, within `DecisionLogic.timeout`; on timeout or error the turn
/// goes ahead with the keywords alone. Logs the engine, the groups and the time — never the message.
enum Decider {
    static var engine: DecisionLogic.Engine? {
        DecisionLogic.engine(pref: UserDefaults.standard.string(forKey: DecisionLogic.pref),
                             appleReady: AppleOnDeviceProvider.availability == nil,
                             hasOpenRouterKey: !(ProviderStore.key(for: .openrouter) ?? "").isEmpty)
    }

    @MainActor private static var lastPrewarm = Date.distantPast

    /// Loads Apple's model ahead of the first message (cold, the first decision took 5–9 s and missed the cap).
    /// Called when the notch opens; at most once a minute; does nothing for other engines.
    @MainActor static func prewarm() {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            guard engine == .apple, Date().timeIntervalSince(lastPrewarm) > 60 else { return }
            lastPrewarm = Date()
            LanguageModelSession(instructions: DecisionLogic.appleInstructions).prewarm()
        }
        #endif
    }

    static func groups(conversation: [ChatMessage], connectors: [ToolRouter.Group]) async -> Set<String> {
        guard !UserDefaults.standard.bool(forKey: "agent.allTools"), let engine else { return [] }
        // Only when the keywords found nothing: every win in the live probe was such a message, and this skips
        // the ≈ 1 s wait on everyday requests the keywords already understand.
        guard DecisionLogic.shouldDecide(keywordGroups: ToolRouter.keywordGroups(conversation, connectors: connectors)) else { return [] }
        let message = DecisionLogic.message(conversation)
        guard !message.isEmpty else { return [] }
        let started = Date()
        let r = await decide(engine, message: message, groups: DecisionLogic.candidates(connectors: connectors))
        let ms = Int(Date().timeIntervalSince(started) * 1000)
        switch r {
        case .success(let g): AppLog.write("decider: \(engine.rawValue) → \(g.isEmpty ? "none" : g.joined(separator: ", ")) in \(ms) ms")
        case .failure(let e): AppLog.write("decider: \(engine.rawValue) skipped after \(ms) ms — \(e.localizedDescription)")
        }
        return Set((try? r.get()) ?? [])
    }

    /// One decision with the timeout — also used by `--probe-decide`.
    static func decide(_ engine: DecisionLogic.Engine, message: String, groups: [ToolRouter.Group],
                       timeout: Double = DecisionLogic.timeout) async -> Result<[String], Error> {
        await withTaskGroup(of: Result<[String], Error>.self) { g in
            g.addTask {
                do {
                    switch engine {
                    case .off: return .success([])
                    case .apple: return .success(try await apple(message: message, groups: groups))
                    case .jev: return .success(try await jev(message: message, groups: groups))
                    }
                } catch { return .failure(error) }
            }
            g.addTask {
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                return .failure(ProviderError(message: "timed out after \(timeout) s"))
            }
            let first = await g.next() ?? .failure(ProviderError(message: "no answer"))
            g.cancelAll()
            return first
        }
    }

    static func jev(message: String, groups: [ToolRouter.Group]) async throws -> [String] {
        guard let key = ProviderStore.key(for: .openrouter), !key.isEmpty else {
            throw ProviderError(message: "Jev needs an OpenRouter key (Settings › AI)")
        }
        var req = URLRequest(url: DecisionLogic.jevURL, timeoutInterval: 5)
        req.httpMethod = "POST"
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = HTTP.json(DecisionLogic.jevBody(message: message, groups: groups))
        let (data, resp) = try await URLSession.shared.data(for: req)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        let body = String(data: data, encoding: .utf8) ?? ""
        guard status == 200, let obj = HTTP.parse(body) else {
            throw ProviderError(message: HTTP.errorMessage(status: status, body: body, provider: "Jev"))
        }
        if let cost = (obj["usage"] as? [String: Any])?["cost"] as? NSNumber {
            AppLog.write("decider: jev cost $\(cost)")
        }
        return DecisionLogic.parseJev(obj, groups: groups)
    }

    static func apple(message: String, groups: [ToolRouter.Group]) async throws -> [String] {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            guard !groups.isEmpty else { return [] }
            // An explicit "none": without it the model always picks something (seen live: maths → calendar).
            let item = DynamicGenerationSchema(name: "group", anyOf: [DecisionLogic.none] + groups.map(\.name))
            let list = DynamicGenerationSchema(arrayOf: item, minimumElements: 1, maximumElements: DecisionLogic.maxGroups)
            let root = DynamicGenerationSchema(name: "routing", properties: [
                .init(name: "groups", description: "Tool groups the message needs", schema: list),
            ])
            let schema = try GenerationSchema(root: root, dependencies: [])
            let session = LanguageModelSession(instructions: DecisionLogic.appleInstructions)
            let r = try await session.respond(to: DecisionLogic.applePrompt(message: message, groups: groups),
                                              schema: schema, options: GenerationOptions(temperature: 0))
            return DecisionLogic.parseApple(json: r.content.jsonString, groups: groups)
        }
        #endif
        throw ProviderError(message: AppleOnDeviceProvider.availability ?? "Apple on-device model unavailable")
    }
}
