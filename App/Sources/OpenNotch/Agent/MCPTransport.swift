import Foundation

// How OpenNotch talks to an MCP server: a local program over stdio, or a web
// server over Streamable HTTP (MCP 2025-06-18). Both do the initialize
// handshake in `open()`; `MCPServer` (MCP.swift) lists and calls tools on top.

protocol MCPTransport: AnyObject, Sendable {
    /// Connects and completes the initialize handshake.
    func open() async throws
    func request(_ method: String, _ params: [String: Any], timeout: TimeInterval) async throws -> [String: Any]
    func close()
}

/// Where mcp.json says a server lives.
enum MCPEndpoint: Equatable, Sendable {
    case stdio(command: String, args: [String], env: [String: String])
    case http(URL, headers: [String: String])

    /// `url` → HTTP (the format Claude Desktop, Cursor and VS Code use); `command` → stdio.
    static func parse(_ config: [String: Any]) -> Result<MCPEndpoint, ProviderError> {
        let type = (config["type"] as? String)?.lowercased()
        if type == "sse" {
            return .failure(ProviderError(message: "the old SSE transport isn't supported — use the server's Streamable HTTP URL"))
        }
        if let raw = (config["url"] as? String) ?? (config["serverUrl"] as? String) {
            guard let url = URL(string: raw.trimmingCharacters(in: .whitespaces)), allowed(url) else {
                return .failure(ProviderError(message: "url must be https (plain http only on localhost)"))
            }
            return .success(.http(url, headers: config["headers"] as? [String: String] ?? [:]))
        }
        if let type, type != "stdio" { return .failure(ProviderError(message: "a \(type) server needs a url")) }
        guard let command = config["command"] as? String, !command.isEmpty else {
            return .failure(ProviderError(message: "needs a command or a url"))
        }
        return .success(.stdio(command: command, args: config["args"] as? [String] ?? [],
                               env: config["env"] as? [String: String] ?? [:]))
    }

    /// Keys and chats go over this connection: https only, except a server on this Mac.
    static func allowed(_ url: URL) -> Bool {
        switch url.scheme?.lowercased() {
        case "https": return !(url.host ?? "").isEmpty
        case "http": return ["localhost", "127.0.0.1", "::1"].contains(url.host?.lowercased() ?? "")
        default: return false
        }
    }
}

/// JSON-RPC pieces shared by both transports (pure, checked).
enum MCPWire {
    static let protocolVersion = "2025-06-18"
    static var initializeParams: [String: Any] {
        ["protocolVersion": protocolVersion, "capabilities": [String: Any](),
         "clientInfo": ["name": "OpenNotch", "version": "0.1"]]
    }

    enum Incoming {
        case result(id: Int, [String: Any])
        case error(id: Int, String)
        case serverRequest(id: Any, method: String)
        case other
    }

    static func classify(_ obj: [String: Any]) -> Incoming {
        if let method = obj["method"] as? String {
            if let id = obj["id"] { return .serverRequest(id: id, method: method) }
            return .other                                                      // a notification
        }
        guard let id = obj["id"] as? Int else { return .other }
        if let err = obj["error"] as? [String: Any] { return .error(id: id, err["message"] as? String ?? "MCP error") }
        return .result(id: id, obj["result"] as? [String: Any] ?? [:])
    }

    /// We answer pings and politely refuse everything else (roots, sampling …).
    static func reply(id: Any, method: String) -> [String: Any] {
        method == "ping" ? ["jsonrpc": "2.0", "id": id, "result": [String: Any]()]
            : ["jsonrpc": "2.0", "id": id, "error": ["code": -32601, "message": "not supported"]]
    }

    /// One or many JSON-RPC messages from a JSON body (a batch is an array).
    static func messages(_ text: String) -> [[String: Any]] {
        guard let d = text.data(using: .utf8), let obj = try? JSONSerialization.jsonObject(with: d) else { return [] }
        if let one = obj as? [String: Any] { return [one] }
        return obj as? [[String: Any]] ?? []
    }
}

/// Reads an MCP event stream line by line. `URLSession.AsyncBytes.lines` drops blank lines (the SSE event
/// boundary), so a message is complete as soon as its `data:` lines parse as JSON.
struct MCPStreamParser {
    private var buffer = ""

    mutating func feed(_ line: String) -> [[String: Any]] {
        guard line.hasPrefix("data:") else {
            if !line.hasPrefix(":") && !line.isEmpty { buffer = "" }           // event:/id:/retry: start afresh
            return []
        }
        var chunk = String(line.dropFirst(5))
        if chunk.hasPrefix(" ") { chunk.removeFirst() }
        buffer += buffer.isEmpty ? chunk : "\n" + chunk
        let msgs = MCPWire.messages(buffer)
        if !msgs.isEmpty { buffer = "" }
        return msgs
    }
}

// MARK: - stdio

final class StdioTransport: MCPTransport, @unchecked Sendable {
    private let name: String
    private let command: String
    private let args: [String]
    private let env: [String: String]

    private var process: Process?
    private var stdin: FileHandle?
    private let lock = NSLock()
    private var nextId = 1
    private var pending: [Int: CheckedContinuation<[String: Any], Error>] = [:]
    private var buffer = Data()

    init(name: String, command: String, args: [String], env: [String: String]) {
        self.name = name
        self.command = command
        self.args = args
        self.env = env
    }

    func open() async throws {
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

        _ = try await request("initialize", MCPWire.initializeParams, timeout: 30)
        send(["jsonrpc": "2.0", "method": "notifications/initialized"])
    }

    func request(_ method: String, _ params: [String: Any], timeout: TimeInterval) async throws -> [String: Any] {
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

    func close() {
        process?.terminate()
        process = nil
        failAll("stopped")
    }

    private func allocateID() -> Int {
        lock.lock(); defer { lock.unlock() }
        nextId += 1
        return nextId - 1
    }

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
            switch MCPWire.classify(obj) {
            case .result(let id, let r): resolve(id, .success(r))
            case .error(let id, let m): resolve(id, .failure(ProviderError(message: m)))
            case .serverRequest(let id, let method): send(MCPWire.reply(id: id, method: method))
            case .other: break
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

// MARK: - Streamable HTTP

/// Each message is a POST; the answer is a JSON body or an event stream that carries it. The server's
/// `Mcp-Session-Id` is sent back on every request; a 404 means the session expired → handshake again once.
/// With `auth` (a signed-in connector, MCPAuth.swift) every request carries its token; a 401 refreshes it once.
final class HTTPTransport: MCPTransport, @unchecked Sendable {
    typealias TokenProvider = @Sendable (_ forceRefresh: Bool) async throws -> String

    let url: URL
    private let name: String
    private let headers: [String: String]
    private let auth: TokenProvider?
    private let lock = NSLock()
    private var sessionID: String?
    private var version: String?
    private var nextId = 1

    private struct SessionExpired: Error {}
    private struct Unauthorized: Error {}
    /// Carries a JSON object out of a task group (Swift 6 wants Sendable results).
    private struct Box: @unchecked Sendable { let value: [String: Any] }

    init(name: String, url: URL, headers: [String: String], auth: TokenProvider? = nil) {
        self.name = name
        self.url = url
        self.headers = headers
        self.auth = auth
    }

    func open() async throws {
        setSession(nil, version: nil)
        let r = try await post(message("initialize", MCPWire.initializeParams), timeout: 30)
        setSession(currentSession(), version: r["protocolVersion"] as? String ?? MCPWire.protocolVersion)
        _ = try await post(["jsonrpc": "2.0", "method": "notifications/initialized"], timeout: 15)
    }

    func request(_ method: String, _ params: [String: Any], timeout: TimeInterval) async throws -> [String: Any] {
        do {
            return try await post(message(method, params), timeout: timeout)
        } catch is SessionExpired {
            try await open()
            return try await post(message(method, params), timeout: timeout)
        }
    }

    func close() {
        guard let sid = currentSession() else { return }
        setSession(nil, version: nil)
        var req = URLRequest(url: url)
        req.httpMethod = "DELETE"
        req.timeoutInterval = 5
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        req.setValue(sid, forHTTPHeaderField: "Mcp-Session-Id")
        Task.detached { _ = try? await HTTP.session.data(for: req) }
    }

    // MARK: Plumbing

    private func message(_ method: String, _ params: [String: Any]) -> [String: Any] {
        ["jsonrpc": "2.0", "id": allocateID(), "method": method, "params": params]
    }

    private func allocateID() -> Int {
        lock.lock(); defer { lock.unlock() }
        nextId += 1
        return nextId - 1
    }

    private func currentSession() -> String? {
        lock.lock(); defer { lock.unlock() }
        return sessionID
    }

    private func setSession(_ sid: String?, version v: String?) {
        lock.lock(); defer { lock.unlock() }
        sessionID = sid
        version = v
    }

    private func adoptSession(_ sid: String) {
        lock.lock(); defer { lock.unlock() }
        sessionID = sid
    }

    private func makeRequest(_ msg: [String: Any], timeout: TimeInterval, token: String? = nil) -> URLRequest {
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = timeout
        req.httpBody = HTTP.json(msg)
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        lock.lock()
        let sid = sessionID, v = version
        lock.unlock()
        if let sid { req.setValue(sid, forHTTPHeaderField: "Mcp-Session-Id") }
        if let v { req.setValue(v, forHTTPHeaderField: "MCP-Protocol-Version") }
        if let token { req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        return req
    }

    /// Sends one message with the current token; a 401 refreshes the token once (a signed-in connector)
    /// or says how to connect (a server that wants sign-in but has none).
    private func post(_ msg: [String: Any], timeout: TimeInterval) async throws -> [String: Any] {
        let token = try await auth?(false)
        do {
            return try await send(msg, timeout: timeout, token: token)
        } catch is Unauthorized {
            guard let auth else {
                throw ProviderError(message: "\(name) needs you to sign in — connect it in Settings › AI › Connectors.")
            }
            let fresh = try await auth(true)
            do { return try await send(msg, timeout: timeout, token: fresh) } catch is Unauthorized { throw MCPSignInNeeded(server: name) }
        }
    }

    /// Sends one message; for a request, waits (≤ timeout in total) for the answer with its id.
    private func send(_ msg: [String: Any], timeout: TimeInterval, token: String?) async throws -> [String: Any] {
        let id = msg["id"] as? Int
        let req = makeRequest(msg, timeout: timeout, token: token)
        let label = "\(name): \(msg["method"] as? String ?? "request")"
        let box = try await withThrowingTaskGroup(of: Box.self) { g in
            g.addTask { Box(value: try await self.exchange(req, id: id)) }
            g.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                throw ProviderError(message: "\(label) timed out")
            }
            defer { g.cancelAll() }
            guard let first = try await g.next() else { throw ProviderError(message: "\(label) failed") }
            return first
        }
        return box.value
    }

    private func exchange(_ req: URLRequest, id: Int?) async throws -> [String: Any] {
        let (bytes, resp) = try await HTTP.session.bytes(for: req)
        let http = resp as? HTTPURLResponse
        let status = http?.statusCode ?? 0
        if status == 404, req.value(forHTTPHeaderField: "Mcp-Session-Id") != nil { throw SessionExpired() }
        if status == 401 { throw Unauthorized() }
        guard (200..<300).contains(status) else {
            var body = ""
            for try await line in bytes.lines { body += line; if body.count > 4000 { break } }
            throw ProviderError(message: HTTP.errorMessage(status: status, body: body, provider: name))
        }
        if let sid = http?.value(forHTTPHeaderField: "Mcp-Session-Id"), !sid.isEmpty { adoptSession(sid) }
        guard let id else { return [:] }                                   // a notification: 202, no body

        let stream = (http?.value(forHTTPHeaderField: "Content-Type") ?? "").lowercased().contains("text/event-stream")
        var parser = MCPStreamParser()
        var body = ""
        for try await line in bytes.lines {
            if stream {
                for obj in parser.feed(line) { if let r = try answer(obj, id: id, authorization: req.value(forHTTPHeaderField: "Authorization")) { return r } }
            } else {
                body += line + "\n"
                if body.count > 20_000_000 { break }
            }
        }
        for obj in MCPWire.messages(body) { if let r = try answer(obj, id: id, authorization: req.value(forHTTPHeaderField: "Authorization")) { return r } }
        throw ProviderError(message: "\(name): no answer from the server")
    }

    private func answer(_ obj: [String: Any], id: Int, authorization: String?) throws -> [String: Any]? {
        switch MCPWire.classify(obj) {
        case .result(let rid, let r) where rid == id: return r
        case .error(let rid, let m) where rid == id: throw ProviderError(message: "\(name): \(m)")
        case .serverRequest(let sid, let method):
            var reply = makeRequest(MCPWire.reply(id: sid, method: method), timeout: 10)
            if let authorization { reply.setValue(authorization, forHTTPHeaderField: "Authorization") }
            Task.detached { _ = try? await HTTP.session.data(for: reply) }
            return nil
        default: return nil
        }
    }
}
