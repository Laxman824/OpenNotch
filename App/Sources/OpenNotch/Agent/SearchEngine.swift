import Foundation

/// Web-search backends for web_search. The default is Parallel (free, no key — `ParallelSearch`);
/// with a key, Brave or Tavily; DuckDuckGo's HTML page is the last resort (it breaks when its markup
/// changes or it rate-limits). Keys live in the Keychain (`search.<engine>`); the choice is
/// `search.engine` (unset = Parallel, "ddg" = DuckDuckGo only). Anything failing falls to the next.
enum SearchEngine: String, CaseIterable, Identifiable, Sendable {
    case brave, tavily
    var id: String { rawValue }

    struct Row: Equatable, Sendable {
        let title: String; let url: String; let snippet: String
        var date: String? = nil
    }

    enum Backend: Equatable, Sendable { case api(SearchEngine), parallel, duckDuckGo }

    var label: String { self == .brave ? "Brave Search" : "Tavily" }
    var keyPage: URL? {
        URL(string: self == .brave ? "https://api-dashboard.search.brave.com/app/keys" : "https://app.tavily.com/home")
    }
    var account: String { "search." + rawValue }
    var key: String? { Keychain.get(account).flatMap { $0.isEmpty ? nil : $0 } }

    static let pref = "search.engine"
    /// "parallel" (also when unset), "ddg", or an API engine's rawValue.
    static var choice: String {
        get { UserDefaults.standard.string(forKey: pref) ?? "parallel" }
        set { UserDefaults.standard.set(newValue, forKey: pref) }
    }

    /// Which backends to try, in order (pure, checked). Picking DuckDuckGo means only DuckDuckGo —
    /// the query then never goes to Parallel.
    static func order(choice: String, keyed: Set<SearchEngine>) -> [Backend] {
        if choice == "ddg" { return [.duckDuckGo] }
        if let e = SearchEngine(rawValue: choice), keyed.contains(e) { return [.api(e), .parallel, .duckDuckGo] }
        return [.parallel, .duckDuckGo]
    }

    func search(_ q: String, key: String) async -> Result<[Row], Error> {
        var req: URLRequest
        switch self {
        case .brave:
            var c = URLComponents(string: "https://api.search.brave.com/res/v1/web/search")!
            c.queryItems = [URLQueryItem(name: "q", value: q), URLQueryItem(name: "count", value: "8")]
            req = URLRequest(url: c.url!)
            req.setValue("application/json", forHTTPHeaderField: "Accept")
            req.setValue(key, forHTTPHeaderField: "X-Subscription-Token")
        case .tavily:
            req = URLRequest(url: URL(string: "https://api.tavily.com/search")!)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
            req.httpBody = HTTP.json(["query": q, "max_results": 8, "search_depth": "basic"])
        }
        req.timeoutInterval = 20
        do {
            let (data, resp) = try await HTTP.session.data(for: req)
            let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
            guard status == 200 else {
                return .failure(ProviderError(message: HTTP.errorMessage(status: status, body: String(data: data, encoding: .utf8) ?? "",
                                                                         provider: label)))
            }
            return .success(parse(data))
        } catch {
            return .failure(error)
        }
    }

    func parse(_ data: Data) -> [Row] {
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return [] }
        let list: [[String: Any]]
        let snippetKey: String
        switch self {
        case .brave: list = ((obj["web"] as? [String: Any])?["results"] as? [[String: Any]]) ?? []; snippetKey = "description"
        case .tavily: list = (obj["results"] as? [[String: Any]]) ?? []; snippetKey = "content"
        }
        return list.compactMap { r in
            guard let url = r["url"] as? String else { return nil }
            func clean(_ s: String) -> String {
                ToolKit.decodeEntities(s.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression))
                    .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
                    .trimmingCharacters(in: .whitespaces)
            }
            return Row(title: clean(r["title"] as? String ?? url), url: url,
                       snippet: String(clean(r[snippetKey] as? String ?? "").prefix(400)))
        }
    }
}

/// Parallel's web search: an MCP server over HTTP (search.parallel.ai/mcp), free for light use with no
/// key; an optional key (Keychain `search.parallel`) raises the limits. It returns excerpts focused on
/// the objective, which usually answer without a fetch. We send only the query, the objective and a
/// random id per app launch (Parallel uses it for free-tier limits) — never the chat, memories or the model.
actor ParallelSearch {
    static let shared = ParallelSearch()
    static let endpoint = URL(string: "https://search.parallel.ai/mcp")!
    static let account = "search.parallel"
    static let keyPage = URL(string: "https://platform.parallel.ai")!
    static let privacy = URL(string: "https://parallel.ai/privacy-policy")!

    private let sessionID = UUID().uuidString
    private var transport: HTTPTransport?
    private var transportKey: String?

    func search(_ query: String, objective: String?) async -> Result<[SearchEngine.Row], Error> {
        let key = Keychain.get(Self.account).flatMap { $0.isEmpty ? nil : $0 }
        do {
            let t = try await connected(key: key)
            let r = try await t.request("tools/call", ["name": "web_search",
                                                       "arguments": Self.arguments(query: query, objective: objective, session: sessionID)],
                                        timeout: 25)
            return .success(try Self.parse(r))
        } catch {
            transport?.close()
            transport = nil
            return .failure(error)
        }
    }

    private func connected(key: String?) async throws -> HTTPTransport {
        if let transport, transportKey == key { return transport }
        transport?.close()
        let t = HTTPTransport(name: "Parallel", url: Self.endpoint,
                              headers: key.map { ["Authorization": "Bearer \($0)"] } ?? [:])
        try await t.open()
        transport = t
        transportKey = key
        return t
    }

    /// Everything that leaves the Mac for a search (rule: nothing from the chat beyond the query).
    static func arguments(query: String, objective: String?, session: String) -> [String: Any] {
        let goal = objective?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return ["objective": String((goal.isEmpty ? query : goal).prefix(500)),
                "search_queries": [String(query.prefix(200))],
                "session_id": session]
    }

    /// A web_search tool result → at most 6 rows with non-empty excerpts (≈ 1.2k chars each).
    static func parse(_ result: [String: Any]) throws -> [SearchEngine.Row] {
        let texts = (result["content"] as? [[String: Any]] ?? []).filter { $0["type"] as? String == "text" }
            .compactMap { $0["text"] as? String }
        if result["isError"] as? Bool == true {
            throw ProviderError(message: "Parallel couldn't search: " + String((texts.first ?? "unknown error").prefix(200)))
        }
        let data = result["structuredContent"] as? [String: Any] ?? texts.first.flatMap(HTTP.parse)
        guard let list = data?["results"] as? [[String: Any]] else {
            throw ProviderError(message: "Parallel returned an unexpected answer.")
        }
        func clean(_ s: String) -> String {
            s.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces)
        }
        var rows: [SearchEngine.Row] = []
        var seen = Set<String>()
        for r in list {
            guard let url = r["url"] as? String, let u = URL(string: url), ["http", "https"].contains(u.scheme?.lowercased() ?? ""),
                  !seen.contains(url) else { continue }
            let excerpt = clean((r["excerpts"] as? [String] ?? []).joined(separator: " … "))
            guard !excerpt.isEmpty else { continue }
            seen.insert(url)
            let title = clean(r["title"] as? String ?? "")
            rows.append(.init(title: title.isEmpty ? url : title, url: url, snippet: String(excerpt.prefix(1200)),
                              date: (r["publish_date"] as? String).flatMap { $0.isEmpty ? nil : $0 }))
            if rows.count == 6 { break }
        }
        return rows
    }
}
