import Foundation

// MCP (Model Context Protocol) client. Servers are listed in
// ~/Library/Application Support/OpenNotch/mcp.json, in the common format —
// a local program (stdio) or a web server (Streamable HTTP, MCPTransport.swift):
//
//   { "mcpServers": {
//       "github": { "command": "npx", "args": ["-y", "@modelcontextprotocol/server-github"],
//                   "env": { "GITHUB_PERSONAL_ACCESS_TOKEN": "…" },
//                   "autoApprove": ["search_repositories"] },
//       "docs":   { "url": "https://example.com/mcp", "headers": { "Authorization": "Bearer …" } },
//       "notion": { "url": "https://mcp.notion.com/mcp", "auth": "oauth", "keywords": ["notion"] } } }
//
// Each server's tools join the agent as `mcp__<server>__<tool>`; they ask
// for approval unless listed in autoApprove. "auth": "oauth" = signed in from
// Settings › AI › Connectors (tokens in the Keychain, MCPAuth.swift). A server's
// tools are sent only when a message mentions one of its `keywords` (default: its
// name), it was used in the chat, or the model loads it with more_tools —
// `"routing": "always"` sends them every time.

final class MCPServer: @unchecked Sendable {
    let name: String
    let endpoint: Result<MCPEndpoint, ProviderError>
    let autoApprove: Set<String>
    let usesOAuth: Bool
    private var transport: MCPTransport?

    init(name: String, config: [String: Any]) {
        self.name = name
        endpoint = MCPEndpoint.parse(config)
        autoApprove = Set(config["autoApprove"] as? [String] ?? [])
        usesOAuth = (config["auth"] as? String)?.lowercased() == "oauth"
    }

    var isRemote: Bool { if case .success(.http) = endpoint { return true } else { return false } }

    struct ToolInfo { let name: String; let description: String; let schema: String }

    func start() async throws -> [ToolInfo] {
        let t: MCPTransport
        switch endpoint {
        case .failure(let e): throw e
        case .success(.stdio(let command, let args, let env)): t = StdioTransport(name: name, command: command, args: args, env: env)
        case .success(.http(let url, let headers)):
            var auth: HTTPTransport.TokenProvider?
            if usesOAuth {
                let server = name
                auth = { refresh in try await MCPTokenStore.shared.accessToken(server: server, forceRefresh: refresh) }
            }
            t = HTTPTransport(name: name, url: url, headers: headers, auth: auth)
        }
        transport = t
        try await t.open()
        var tools: [ToolInfo] = []
        var cursor: String?
        repeat {
            let r = try await t.request("tools/list", cursor.map { ["cursor": $0] } ?? [:], timeout: 30)
            for tool in r["tools"] as? [[String: Any]] ?? [] {
                guard let n = tool["name"] as? String else { continue }
                let schema = tool["inputSchema"].flatMap { String(data: HTTP.json($0), encoding: .utf8) } ?? Schema.object([:])
                tools.append(ToolInfo(name: n, description: tool["description"] as? String ?? "", schema: schema))
            }
            cursor = r["nextCursor"] as? String
        } while cursor != nil && tools.count < 500
        return tools
    }

    func call(_ tool: String, argumentsJSON: String) async -> ToolOutcome {
        guard let transport else { return .fail("\(name): not connected") }
        do {
            let r = try await transport.request("tools/call", ["name": tool, "arguments": HTTP.parse(argumentsJSON) ?? [:]], timeout: 180)
            return Self.outcome(r)
        } catch {
            return .fail("\(name): \(error.localizedDescription)")
        }
    }

    /// A tools/call result → text (+ images saved to tmp).
    static func outcome(_ r: [String: Any]) -> ToolOutcome {
        var text: [String] = [], images: [String] = []
        for c in r["content"] as? [[String: Any]] ?? [] {
            switch c["type"] as? String {
            case "text": text.append(c["text"] as? String ?? "")
            case "image":
                if let b64 = c["data"] as? String, let data = Data(base64Encoded: b64) {
                    let ext = (c["mimeType"] as? String ?? "").contains("png") ? "png" : "jpg"
                    let f = opennotchDir("tmp") + "/mcp_\(UUID().uuidString.prefix(8)).\(ext)"
                    if (try? data.write(to: URL(fileURLWithPath: f))) != nil { images.append(f) }
                }
            case "resource":
                if let res = c["resource"] as? [String: Any] { text.append(res["text"] as? String ?? "[resource \(res["uri"] ?? "")]") }
            default: break
            }
        }
        return ToolOutcome(ok: r["isError"] as? Bool != true, text: text.joined(separator: "\n"), images: images)
    }

    func stop() {
        transport?.close()
        transport = nil
    }
}

/// Loads mcp.json, starts servers, and exposes their tools.
@MainActor
final class MCPManager: ObservableObject {
    static let shared = MCPManager()
    static var configPath: String { opennotchDir("") + "/mcp.json" }

    @Published private(set) var status: [(name: String, state: String)] = []
    /// Connectors whose sign-in is missing or expired (Settings shows "Sign in again").
    @Published private(set) var signInNeeded: Set<String> = []
    private(set) var tools: [AgentTool] = []
    /// One router group per server (its keywords → its tools).
    private(set) var groups: [ToolRouter.Group] = []
    private var servers: [MCPServer] = []

    func reload() async {
        servers.forEach { $0.stop() }
        servers = []
        tools = []
        groups = []
        guard let d = FileManager.default.contents(atPath: Self.configPath),
              let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else {
            status = []
            return
        }
        let defs = (obj["mcpServers"] as? [String: [String: Any]]) ?? (obj["servers"] as? [String: [String: Any]]) ?? [:]
        var st: [(String, String)] = []
        var needSignIn: Set<String> = []
        for (name, cfg) in defs.sorted(by: { $0.key < $1.key }) {
            if cfg["disabled"] as? Bool == true { st.append((name, "disabled")); continue }
            let server = MCPServer(name: name, config: cfg)
            do {
                let infos = try await server.start()
                servers.append(server)
                for i in infos {
                    let wire = Self.wireName(server: name, tool: i.name)
                    let auto = server.autoApprove.contains(i.name)
                    let toolName = i.name
                    tools.append(AgentTool(
                        name: wire, description: "[\(name)] " + String(i.description.prefix(900)), schema: i.schema,
                        risk: auto ? .read : .confirm, verb: "\(name): \(toolName)",
                        detail: { _ in "" },
                        preview: { a in "\(name) › \(toolName)\n" + (String(data: HTTP.json(a.dict), encoding: .utf8) ?? "").prefix(600) },
                        run: { a in await server.call(toolName, argumentsJSON: String(data: HTTP.json(a.dict), encoding: .utf8) ?? "{}") }))
                }
                groups.append(Self.group(server: name, config: cfg, tools: infos.map { Self.wireName(server: name, tool: $0.name) }))
                st.append((name, "\(infos.count) tools" + (server.isRemote ? " · web" : "")))
            } catch {
                server.stop()
                let hasToken = server.usesOAuth ? await MCPTokenStore.shared.hasRecord(name) : true
                if error is MCPSignInNeeded || !hasToken {
                    needSignIn.insert(name)
                    st.append((name, "sign in needed"))
                } else {
                    st.append((name, "failed: \(error.localizedDescription)"))
                }
                AppLog.write("mcp \(name): \(error.localizedDescription)")
            }
        }
        status = st
        signInNeeded = needSignIn
    }

    /// The router group for a server: its `keywords` (default: its name) or always.
    static func group(server: String, config: [String: Any], tools: [String]) -> ToolRouter.Group {
        var words = (config["keywords"] as? [String] ?? []).map { $0.lowercased().trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        if words.isEmpty {
            words = [server.lowercased().replacingOccurrences(of: "[-_]+", with: " ", options: .regularExpression)]
        }
        let pattern = "\\b(" + words.map { NSRegularExpression.escapedPattern(for: $0) }.joined(separator: "|") + ")\\b"
        return ToolRouter.Group(name: server, pattern: pattern, tools: tools,
                                always: (config["routing"] as? String)?.lowercased() == "always")
    }

    func stopAll() { servers.forEach { $0.stop() } }

    /// Tool names must match ^[a-zA-Z0-9_-]{1,64}$ for every provider.
    static func wireName(server: String, tool: String) -> String {
        let clean: (String) -> String = { $0.replacingOccurrences(of: "[^a-zA-Z0-9_-]", with: "_", options: .regularExpression) }
        return String("mcp__\(clean(server))__\(clean(tool))".prefix(64))
    }

    /// Writes an example config the first time someone opens it.
    static func ensureConfigFile() {
        guard !FileManager.default.fileExists(atPath: configPath) else { return }
        let example = """
        {
          "mcpServers": {
            "filesystem-example": {
              "disabled": true,
              "command": "npx",
              "args": ["-y", "@modelcontextprotocol/server-filesystem", "\(NSHomeDirectory())/Documents"],
              "autoApprove": ["read_file", "list_directory"]
            },
            "web-example": {
              "disabled": true,
              "url": "https://example.com/mcp",
              "headers": { "Authorization": "Bearer YOUR_KEY" }
            }
          }
        }
        """
        try? example.write(toFile: configPath, atomically: true, encoding: .utf8)
    }
}
