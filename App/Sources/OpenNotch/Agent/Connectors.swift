import Foundation

/// Services in Settings › AI › Connectors that sign in with one click (their MCP servers let apps
/// register themselves — checked 2026-10-05). Figma refuses unapproved apps; Gmail (Google), GitHub,
/// Slack, Asana, Box and HubSpot need an OAuth app registered by the maintainer — later.
struct ConnectorInfo: Identifiable, Equatable, Sendable {
    let id: String                 // the server name in mcp.json
    let name: String
    let url: String
    let blurb: String
    let keywords: [String]
    let color: UInt32              // monogram badge
}

enum ConnectorCatalog {
    static let all: [ConnectorInfo] = [
        .init(id: "notion", name: "Notion", url: "https://mcp.notion.com/mcp", blurb: "Pages, docs and databases",
              keywords: ["notion"], color: 0x2F2F2F),
        .init(id: "linear", name: "Linear", url: "https://mcp.linear.app/mcp", blurb: "Issues and projects",
              keywords: ["linear"], color: 0x5E6AD2),
        .init(id: "todoist", name: "Todoist", url: "https://ai.todoist.net/mcp", blurb: "Tasks and projects",
              keywords: ["todoist"], color: 0xE44332),
        .init(id: "zapier", name: "Zapier", url: "https://mcp.zapier.com/api/mcp/mcp",
              blurb: "Gmail, Sheets, Slack & 8,000 apps — pick actions in Zapier",
              keywords: ["zapier", "gmail", "google sheets", "google docs", "google drive", "slack", "trello", "hubspot"],
              color: 0xFF4F00),
        .init(id: "atlassian", name: "Atlassian", url: "https://mcp.atlassian.com/v1/mcp", blurb: "Jira and Confluence",
              keywords: ["atlassian", "jira", "confluence"], color: 0x0052CC),
        .init(id: "airtable", name: "Airtable", url: "https://mcp.airtable.com/mcp", blurb: "Bases and records",
              keywords: ["airtable"], color: 0x18BFFF),
        .init(id: "dropbox", name: "Dropbox", url: "https://mcp.dropbox.com/mcp", blurb: "Files and sharing",
              keywords: ["dropbox"], color: 0x0061FF),
        .init(id: "granola", name: "Granola", url: "https://mcp.granola.ai/mcp", blurb: "Your meeting notes",
              keywords: ["granola"], color: 0x5E8C3A),
        .init(id: "clickup", name: "ClickUp", url: "https://mcp.clickup.com/mcp", blurb: "Tasks and docs",
              keywords: ["clickup", "click up"], color: 0x7B68EE),
        // Not "monday" — that's a weekday (router must-NOT check).
        .init(id: "monday", name: "monday.com", url: "https://mcp.monday.com/mcp", blurb: "Boards and items",
              keywords: ["monday.com", "monday board", "monday boards"], color: 0xFF3D57),
        .init(id: "canva", name: "Canva", url: "https://mcp.canva.com/mcp", blurb: "Designs and brand kits",
              keywords: ["canva"], color: 0x00C4CC),
    ]

    /// A server name for a pasted URL: "https://mcp.acme.io/mcp" → "acme" (unique among `existing`).
    static func serverName(for url: URL, existing: Set<String>) -> String {
        var parts = (url.host ?? "server").lowercased().split(separator: ".").map(String.init)
        while parts.count > 1, ["mcp", "api", "www", "ai", "app"].contains(parts[0]) { parts.removeFirst() }
        if parts.count > 1 { parts.removeLast() }
        var base = (parts.last ?? "server").replacingOccurrences(of: "[^a-z0-9-]", with: "", options: .regularExpression)
        if base.isEmpty { base = "server" }
        var name = base, n = 2
        while existing.contains(name) { name = "\(base)-\(n)"; n += 1 }
        return name
    }
}

extension MCPManager {
    static func readConfig() -> [String: Any] {
        guard let d = FileManager.default.contents(atPath: configPath),
              let obj = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] else { return [:] }
        return obj
    }

    static var serverNames: Set<String> {
        let obj = readConfig()
        return Set(((obj["mcpServers"] as? [String: Any]) ?? (obj["servers"] as? [String: Any]) ?? [:]).keys)
    }

    /// Adds, replaces (or with nil removes) one server in mcp.json, keeping everything else.
    static func writeServer(_ name: String, _ config: [String: Any]?) throws {
        var obj = readConfig()
        let key = obj["mcpServers"] == nil && obj["servers"] != nil ? "servers" : "mcpServers"
        var servers = obj[key] as? [String: Any] ?? [:]
        servers[name] = config
        obj[key] = servers
        let data = try JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try data.write(to: URL(fileURLWithPath: configPath), options: .atomic)
    }

    /// Connect a web MCP server: sign in through the browser if it asks for it, save it to mcp.json,
    /// reload. Only ever called from a click in Settings.
    func connect(name: String, url: URL, keywords: [String] = []) async throws {
        guard MCPEndpoint.allowed(url) else { throw ProviderError(message: "Use an https address.") }
        let auth = try await MCPAuth.discover(server: url)
        if let auth { try await MCPSignIn.run(server: name, url: url, auth: auth) }
        var cfg: [String: Any] = ["url": url.absoluteString]
        if auth != nil { cfg["auth"] = "oauth" }
        if !keywords.isEmpty { cfg["keywords"] = keywords }
        try Self.writeServer(name, cfg)
        await reload()
    }

    /// Sign in again with the server's saved URL.
    func signInAgain(_ name: String) async throws {
        let servers = (Self.readConfig()["mcpServers"] as? [String: [String: Any]]) ?? (Self.readConfig()["servers"] as? [String: [String: Any]]) ?? [:]
        guard let raw = servers[name]?["url"] as? String, let url = URL(string: raw) else {
            throw ProviderError(message: "\(name) has no URL in mcp.json.")
        }
        guard let auth = try await MCPAuth.discover(server: url) else { await reload(); return }
        try await MCPSignIn.run(server: name, url: url, auth: auth)
        await reload()
    }

    /// Forget the tokens and remove the server from mcp.json.
    func disconnect(_ name: String) async throws {
        await MCPTokenStore.shared.remove(name)
        try Self.writeServer(name, nil)
        await reload()
    }
}
