import Foundation

/// Optional web-search APIs for web_search. DuckDuckGo's HTML page needs no key
/// but breaks when its markup changes or it rate-limits; with a key, Brave or
/// Tavily give stable results. Keys live in the Keychain (`search.<engine>`);
/// the choice is `search.engine`. Anything failing falls back to DuckDuckGo.
enum SearchEngine: String, CaseIterable, Identifiable, Sendable {
    case brave, tavily
    var id: String { rawValue }

    struct Row: Equatable, Sendable { let title: String; let url: String; let snippet: String }

    var label: String { self == .brave ? "Brave Search" : "Tavily" }
    var keyPage: URL? {
        URL(string: self == .brave ? "https://api-dashboard.search.brave.com/app/keys" : "https://app.tavily.com/home")
    }
    var account: String { "search." + rawValue }
    var key: String? { Keychain.get(account).flatMap { $0.isEmpty ? nil : $0 } }

    static let pref = "search.engine"
    /// The chosen engine, if it has a key.
    static var active: SearchEngine? {
        get { UserDefaults.standard.string(forKey: pref).flatMap(SearchEngine.init(rawValue:)) }
        set { UserDefaults.standard.set(newValue?.rawValue, forKey: pref) }
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
