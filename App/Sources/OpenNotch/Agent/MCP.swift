import Foundation

// MCP (Model Context Protocol) client over stdio. Servers are listed in
// ~/Library/Application Support/OpenNotch/mcp.json, in the common format:
//
//   { "mcpServers": {
//       "github": { "command": "npx", "args": ["-y", "@modelcontextprotocol/server-github"],
//                   "env": { "GITHUB_PERSONAL_ACCESS_TOKEN": "…" },
//                   "autoApprove": ["search_repositories"] } } }
//
// Each server's tools join the agent as `mcp__<server>__<tool>`; they ask
// for approval unless listed in autoApprove.

final class MCPServer: @unchecked Sendable {
    let name: String
    private let command: String
    private let args: [String]
    private let env: [String: String]
    let autoApprove: Set<String>

    private var process: Process?
    private var stdin: FileHandle?
    private let lock = NSLock()
    private var nextId = 1
    private var pending: [Int: CheckedContinuation<[String: Any], Error>] = [:]
    private var buffer = Data()

    init(name: String, config: [String: Any]) {
        self.name = name
        command = config["command"] as? String ?? ""
        args = config["args"] as? [String] ?? []
        env = config["env"] as? [String: String] ?? [:]
        autoApprove = Set(config["autoApprove"] as? [String] ?? [])
    }

    struct ToolInfo { let name: String; let description: String; let schema: String }

    func start() async throws -> [ToolInfo] {
        guard !command.isEmpty else { throw ProviderError(message: "no command") }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = [command] + args
        var e = ProcessInfo.processInfo.environment
        e["PATH"] = "/opt/homebrew/bin:/usr/local/bin:" + (e["PATH"] ?? "/usr/bin:/bin")
        for (k, v) in env { e[k] = v }
        p.environment = e
        let inPipe = Pipe(), outPipe = Pipe()
        p.standardInput = inPipe
        p.standardOutput = outPipe
        p.standardError = FileHandle.nullDevice
        outPipe.fileHandleForReading.readabilityHandler = { [weak self] h in
            let d = h.availableData
            if d.isEmpty { h.readabilityHandler = nil; self?.failAll("server exited"); return }
            self?.received(d)
        }
        p.terminationHandler = { [weak self] _ in self?.failAll("server exited") }
        try p.run()
        process = p
        stdin = inPipe.fileHandleForWriting

        _ = try await request("initialize", ["protocolVersion": "2025-06-18", "capabilities": [:],
                                              "clientInfo": ["name": "OpenNotch", "version": "0.1"]], timeout: 30)
        notify("notifications/initialized")
        var tools: [ToolInfo] = []
        var cursor: String?
        repeat {
            let r = try await request("tools/list", cursor.map { ["cursor": $0] } ?? [:], timeout: 30)
            for t in r["tools"] as? [[String: Any]] ?? [] {
                guard let n = t["name"] as? String else { continue }
                let schema = t["inputSchema"].flatMap { String(data: HTTP.json($0), encoding: .utf8) } ?? Schema.object([:])
                tools.append(ToolInfo(name: n, description: t["description"] as? String ?? "", schema: schema))
            }
            cursor = r["nextCursor"] as? String
        } while cursor != nil && tools.count < 500
        return tools
    }

    func call(_ tool: String, argumentsJSON: String) async -> ToolOutcome {
        do {
            let r = try await request("tools/call", ["name": tool, "arguments": HTTP.parse(argumentsJSON) ?? [:]], timeout: 180)
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
        } catch {
            return .fail("\(name): \(error.localizedDescription)")
        }
    }

    func stop() {
        process?.terminate()
        process = nil
        failAll("stopped")
    }

    // MARK: JSON-RPC

    private func request(_ method: String, _ params: [String: Any], timeout: TimeInterval) async throws -> [String: Any] {
        let id = allocateID()
        let msg: [String: Any] = ["jsonrpc": "2.0", "id": id, "method": method, "params": params]
        return try await withCheckedThrowingContinuation { c in
            lock.lock(); pending[id] = c; lock.unlock()
            send(msg)
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [weak self] in
                self?.resolve(id, .failure(ProviderError(message: "\(method) timed out")))
            }
        }
    }

    private func allocateID() -> Int {
        lock.lock(); defer { lock.unlock() }
        nextId += 1
        return nextId - 1
    }

    private func notify(_ method: String) { send(["jsonrpc": "2.0", "method": method]) }

    private func send(_ msg: [String: Any]) {
        var d = HTTP.json(msg)
        d.append(0x0A)
        try? stdin?.write(contentsOf: d)
    }

    private func received(_ d: Data) {
        lock.lock()
        buffer.append(d)
        var lines: [Data] = []
        while let nl = buffer.firstIndex(of: 0x0A) {
            lines.append(buffer[buffer.startIndex..<nl])
            buffer.removeSubrange(buffer.startIndex...nl)
        }
        lock.unlock()
        for line in lines {
            guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }
            if let id = obj["id"] as? Int, obj["method"] == nil {
                if let err = obj["error"] as? [String: Any] {
                    resolve(id, .failure(ProviderError(message: err["message"] as? String ?? "MCP error")))
                } else {
                    resolve(id, .success(obj["result"] as? [String: Any] ?? [:]))
                }
            } else if let id = obj["id"], let method = obj["method"] as? String {
                // A request from the server (ping, roots/list …): answer politely.
                if method == "ping" { send(["jsonrpc": "2.0", "id": id, "result": [:]]) }
                else { send(["jsonrpc": "2.0", "id": id, "error": ["code": -32601, "message": "not supported"]]) }
            }
        }
    }

    private func resolve(_ id: Int, _ r: Result<[String: Any], Error>) {
        lock.lock()
        let c = pending.removeValue(forKey: id)
        lock.unlock()
        c?.resume(with: r)
    }

    private func failAll(_ why: String) {
        lock.lock()
        let all = pending
        pending = [:]
        lock.unlock()
        for c in all.values { c.resume(throwing: ProviderError(message: "\(name): \(why)")) }
    }
}

/// Loads mcp.json, starts servers, and exposes their tools.
@MainActor
final class MCPManager: ObservableObject {
    static let shared = MCPManager()
    static var configPath: String { opennotchDir("") + "/mcp.json" }

    @Published private(set) var status: [(name: String, state: String)] = []
    private(set) var tools: [AgentTool] = []
    private var servers: [MCPServer] = []

    func reload() async {
        servers.forEach { $0.stop() }
        servers = []
        tools = []
        guard let d = FileManager.default.contents(atPath: Self.configPath),
              let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else {
            status = []
            return
        }
        let defs = (obj["mcpServers"] as? [String: [String: Any]]) ?? (obj["servers"] as? [String: [String: Any]]) ?? [:]
        var st: [(String, String)] = []
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
                st.append((name, "\(infos.count) tools"))
            } catch {
                server.stop()
                st.append((name, "failed: \(error.localizedDescription)"))
                AppLog.write("mcp \(name): \(error.localizedDescription)")
            }
        }
        status = st
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
            }
          }
        }
        """
        try? example.write(toFile: configPath, atomically: true, encoding: .utf8)
    }
}
