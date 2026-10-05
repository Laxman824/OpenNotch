import AppKit
import CryptoKit
import Foundation
import Network

// Sign-in for web MCP servers (MCP authorization spec, OAuth 2.1): the server answers 401 →
// its protected-resource metadata names the login server → that server's metadata gives the
// endpoints → OpenNotch registers itself (dynamic client registration) with a loopback redirect →
// PKCE (S256) login in the browser → code → tokens. Tokens live in ONE Keychain item ("mcp.oauth",
// a JSON map by server name — one Keychain prompt after an update, not one per connector), are sent
// only to their own server (`resource`), and are refreshed when they expire. Sign-in only ever starts
// from a click in Settings — never in the middle of a chat.

struct MCPOAuthRecord: Codable, Sendable, Equatable {
    var accessToken: String
    var refreshToken: String?
    var expiresAt: Date?
    var tokenEndpoint: String
    var clientID: String
    var clientSecret: String?
    var authMethod: String                 // none | client_secret_post | client_secret_basic
    var resource: String
    var scope: String?
}

/// The server needs the user to sign in (again) — shown as the connector's status, reported as a failure.
struct MCPSignInNeeded: LocalizedError {
    let server: String
    var errorDescription: String? { "\(server) needs you to sign in again — Settings › AI › Connectors." }
}

/// What discovery found: where to log in and what to ask for.
struct MCPAuthServer: Sendable, Equatable {
    let authorizationEndpoint: URL
    let tokenEndpoint: URL
    let registrationEndpoint: URL?
    let authMethods: [String]?
    let resource: String
    let scope: String?
}

/// Pure pieces of the flow (checked in AgentChecks).
enum MCPAuthLogic {
    /// `Bearer realm="x", resource_metadata="https://…", scope="read write"` → ["realm": "x", …].
    static func challengeParams(_ header: String) -> [String: String] {
        guard let re = try? NSRegularExpression(pattern: #"([A-Za-z_]+)\s*=\s*(?:"([^"]*)"|([^,\s]+))"#) else { return [:] }
        var out: [String: String] = [:]
        let ns = header as NSString
        for m in re.matches(in: header, range: NSRange(location: 0, length: ns.length)) {
            let key = ns.substring(with: m.range(at: 1)).lowercased()
            let value = m.range(at: 2).location != NSNotFound ? ns.substring(with: m.range(at: 2)) : ns.substring(with: m.range(at: 3))
            if out[key] == nil { out[key] = value }
        }
        return out
    }

    /// https anywhere, plain http only on this Mac (same rule as MCP server URLs).
    static func secure(_ s: String?) -> URL? {
        guard let s, let u = URL(string: s), MCPEndpoint.allowed(u) else { return nil }
        return u
    }

    private static func origin(_ u: URL) -> String {
        "\(u.scheme ?? "https")://\(u.host ?? "")" + (u.port.map { ":\($0)" } ?? "")
    }

    private static func path(_ u: URL) -> String {
        let p = u.path
        return p == "/" ? "" : (p.hasSuffix("/") ? String(p.dropLast()) : p)
    }

    /// Where the protected-resource metadata may be: the 401's `resource_metadata`, then the
    /// well-known URL with the server's path, then at the root.
    static func resourceMetadataCandidates(server: URL, header: String?) -> [URL] {
        var out: [URL] = []
        if let h = header, let u = secure(challengeParams(h)["resource_metadata"]) { out.append(u) }
        let p = path(server)
        if !p.isEmpty, let u = URL(string: origin(server) + "/.well-known/oauth-protected-resource" + p) { out.append(u) }
        if let u = URL(string: origin(server) + "/.well-known/oauth-protected-resource") { out.append(u) }
        return out.reduce(into: []) { if !$0.contains($1) { $0.append($1) } }
    }

    /// RFC 8414 and OpenID discovery URLs for a login server (issuer), path-aware.
    static func authServerCandidates(issuer: URL) -> [URL] {
        let o = origin(issuer), p = path(issuer)
        let list = p.isEmpty
            ? [o + "/.well-known/oauth-authorization-server", o + "/.well-known/openid-configuration"]
            : [o + "/.well-known/oauth-authorization-server" + p, o + "/.well-known/openid-configuration" + p,
               o + p + "/.well-known/openid-configuration"]
        return list.compactMap(URL.init(string:))
    }

    /// The `resource` the tokens are bound to: the metadata's, if it's this server (or a parent of it).
    static func resource(server: URL, advertised: String?) -> String {
        let own = origin(server).lowercased() + path(server)
        if let a = advertised, let u = secure(a) {
            let adv = origin(u).lowercased() + path(u)
            if own == adv || own.hasPrefix(adv + "/") { return adv }
        }
        return own
    }

    /// Prefer a public client (no secret); else what the login server accepts.
    static func authMethod(supported: [String]?) -> String {
        guard let s = supported, !s.isEmpty else { return "client_secret_basic" }   // RFC 8414 default
        for m in ["none", "client_secret_post", "client_secret_basic"] where s.contains(m) { return m }
        return "none"
    }

    /// The 401's `scope`, else everything the server lists, else nothing.
    static func scope(header: String?, supported: [String]?) -> String? {
        if let h = header, let s = challengeParams(h)["scope"], !s.isEmpty { return s }
        guard let s = supported, !s.isEmpty else { return nil }
        return s.joined(separator: " ")
    }

    static func challenge(for verifier: String) -> String { b64url(Data(SHA256.hash(data: Data(verifier.utf8)))) }

    static func randomToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return b64url(Data(bytes))
    }

    static func b64url(_ d: Data) -> String {
        d.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func authorizeURL(_ s: MCPAuthServer, clientID: String, redirect: String, challenge: String, state: String) -> URL? {
        guard var c = URLComponents(url: s.authorizationEndpoint, resolvingAgainstBaseURL: false) else { return nil }
        var q = c.queryItems ?? []
        q += [.init(name: "response_type", value: "code"), .init(name: "client_id", value: clientID),
              .init(name: "redirect_uri", value: redirect), .init(name: "code_challenge", value: challenge),
              .init(name: "code_challenge_method", value: "S256"), .init(name: "state", value: state),
              .init(name: "resource", value: s.resource)]
        if let scope = s.scope { q.append(.init(name: "scope", value: scope)) }
        c.queryItems = q
        // URLComponents leaves "+" alone; a login server would read it as a space.
        c.percentEncodedQuery = c.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        return c.url
    }

    /// The browser's return: `/callback?code=…&state=…` → the code, if the state is ours.
    static func callbackCode(path: String, state: String) -> Result<String, ProviderError> {
        guard let c = URLComponents(string: "http://127.0.0.1" + path), c.path == "/callback" else {
            return .failure(ProviderError(message: "not the sign-in page"))
        }
        let q = Dictionary((c.queryItems ?? []).map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { a, _ in a })
        guard q["state"] == state else { return .failure(ProviderError(message: "The sign-in answer didn't match — try again.")) }
        if let e = q["error"] {
            let why = q["error_description"].map { ": \($0)" } ?? ""
            return .failure(ProviderError(message: e == "access_denied" ? "Sign-in was cancelled." : "Sign-in failed (\(e)\(why))."))
        }
        guard let code = q["code"], !code.isEmpty else { return .failure(ProviderError(message: "The login server sent no code.")) }
        return .success(code)
    }

    /// Refresh a minute before expiry.
    static func needsRefresh(_ r: MCPOAuthRecord, now: Date = Date()) -> Bool {
        guard let e = r.expiresAt else { return false }
        return now >= e.addingTimeInterval(-60)
    }

    static func formEncode(_ fields: [String: String]) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return fields.sorted { $0.key < $1.key }.map { k, v in
            "\(k.addingPercentEncoding(withAllowedCharacters: allowed) ?? k)=\(v.addingPercentEncoding(withAllowedCharacters: allowed) ?? v)"
        }.joined(separator: "&")
    }

    /// A token-endpoint request with the client authenticated the way it registered.
    static func tokenRequest(_ endpoint: URL, fields: [String: String], clientID: String, secret: String?, method: String) -> URLRequest {
        var f = fields
        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.timeoutInterval = 30
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        if method == "client_secret_basic", let secret {
            let enc: (String) -> String = { $0.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? $0 }
            req.setValue("Basic " + Data("\(enc(clientID)):\(enc(secret))".utf8).base64EncodedString(), forHTTPHeaderField: "Authorization")
        } else {
            f["client_id"] = clientID
            if method == "client_secret_post", let secret { f["client_secret"] = secret }
        }
        req.httpBody = Data(formEncode(f).utf8)
        return req
    }

    /// A token response → the stored record (a refresh may omit the refresh token: keep the old one).
    static func record(from obj: [String: Any], base: MCPOAuthRecord, now: Date = Date()) -> MCPOAuthRecord? {
        guard let access = obj["access_token"] as? String, !access.isEmpty else { return nil }
        var r = base
        r.accessToken = access
        if let refresh = obj["refresh_token"] as? String, !refresh.isEmpty { r.refreshToken = refresh }
        let secs = (obj["expires_in"] as? NSNumber)?.doubleValue ?? Double(obj["expires_in"] as? String ?? "")
        r.expiresAt = secs.map { now.addingTimeInterval($0) }
        if let s = obj["scope"] as? String { r.scope = s }
        return r
    }
}

// MARK: - Discovery + registration (network)

enum MCPAuth {
    private static func get(_ url: URL) async -> [String: Any]? {
        var req = URLRequest(url: url)
        req.timeoutInterval = 15
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        guard let (data, resp) = try? await HTTP.session.data(for: req), (resp as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    /// nil when the server answers without a sign-in; else where and how to log in.
    static func discover(server: URL) async throws -> MCPAuthServer? {
        var req = URLRequest(url: server)
        req.httpMethod = "POST"
        req.timeoutInterval = 20
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        req.httpBody = HTTP.json(["jsonrpc": "2.0", "id": 1, "method": "initialize", "params": MCPWire.initializeParams])
        let (_, resp) = try await HTTP.session.data(for: req)
        let http = resp as? HTTPURLResponse
        let status = http?.statusCode ?? 0
        if (200..<300).contains(status) { return nil }
        guard status == 401 || status == 403 else {
            throw ProviderError(message: HTTP.errorMessage(status: status, body: "", provider: server.host ?? "server"))
        }
        let header = http?.value(forHTTPHeaderField: "WWW-Authenticate")

        var prm: [String: Any]?
        for u in MCPAuthLogic.resourceMetadataCandidates(server: server, header: header) {
            if let d = await get(u) { prm = d; break }
        }
        let issuer = (prm?["authorization_servers"] as? [String])?.lazy.compactMap(MCPAuthLogic.secure).first
            ?? URL(string: "\(server.scheme ?? "https")://\(server.host ?? "")" + (server.port.map { ":\($0)" } ?? ""))
        guard let issuer else { throw ProviderError(message: "Couldn't find where to sign in.") }
        var meta: [String: Any]?
        for u in MCPAuthLogic.authServerCandidates(issuer: issuer) {
            if let d = await get(u), d["authorization_endpoint"] != nil { meta = d; break }
        }
        guard let meta, let auth = MCPAuthLogic.secure(meta["authorization_endpoint"] as? String),
              let token = MCPAuthLogic.secure(meta["token_endpoint"] as? String) else {
            throw ProviderError(message: "\(server.host ?? "This server") doesn't publish a standard sign-in.")
        }
        // The spec requires PKCE; a server that doesn't say it supports S256 isn't safe to log in to.
        guard (meta["code_challenge_methods_supported"] as? [String] ?? []).contains("S256") else {
            throw ProviderError(message: "\(server.host ?? "This server")'s sign-in doesn't support PKCE — OpenNotch won't use it.")
        }
        return MCPAuthServer(
            authorizationEndpoint: auth, tokenEndpoint: token,
            registrationEndpoint: MCPAuthLogic.secure(meta["registration_endpoint"] as? String),
            authMethods: meta["token_endpoint_auth_methods_supported"] as? [String],
            resource: MCPAuthLogic.resource(server: server, advertised: prm?["resource"] as? String),
            scope: MCPAuthLogic.scope(header: header, supported: prm?["scopes_supported"] as? [String]))
    }

    /// Dynamic client registration for this sign-in's loopback address.
    static func register(_ s: MCPAuthServer, redirect: String) async throws -> (id: String, secret: String?, method: String) {
        guard let endpoint = s.registrationEndpoint else {
            throw ProviderError(message: "This server doesn't let apps register themselves, so OpenNotch can't sign in to it yet.")
        }
        let method = MCPAuthLogic.authMethod(supported: s.authMethods)
        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.timeoutInterval = 20
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = HTTP.json(["client_name": "OpenNotch", "client_uri": "https://github.com/Laxman824/OpenNotch",
                                  "redirect_uris": [redirect], "grant_types": ["authorization_code", "refresh_token"],
                                  "response_types": ["code"], "token_endpoint_auth_method": method])
        let (data, resp) = try await HTTP.session.data(for: req)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status), let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let id = obj["client_id"] as? String, !id.isEmpty else {
            throw ProviderError(message: status == 403 ? "This service only lets approved apps connect — OpenNotch isn't one yet."
                                : HTTP.errorMessage(status: status, body: String(data: data, encoding: .utf8) ?? "", provider: "Registration"))
        }
        return (id, obj["client_secret"] as? String, obj["token_endpoint_auth_method"] as? String ?? method)
    }
}

// MARK: - Tokens (Keychain)

actor MCPTokenStore {
    static let shared = MCPTokenStore()
    static let account = "mcp.oauth"

    private var cache: [String: MCPOAuthRecord]?
    private var refreshing: [String: Task<MCPOAuthRecord, Error>] = [:]

    private func all() -> [String: MCPOAuthRecord] {
        if let cache { return cache }
        let loaded = Keychain.get(Self.account).flatMap { try? JSONDecoder().decode([String: MCPOAuthRecord].self, from: Data($0.utf8)) } ?? [:]
        cache = loaded
        return loaded
    }

    private func write(_ map: [String: MCPOAuthRecord]) {
        cache = map
        if map.isEmpty { Keychain.delete(Self.account); return }
        if let d = try? JSONEncoder().encode(map), let s = String(data: d, encoding: .utf8) { Keychain.set(s, for: Self.account) }
    }

    func hasRecord(_ server: String) -> Bool { all()[server] != nil }
    func save(_ r: MCPOAuthRecord, for server: String) { var m = all(); m[server] = r; write(m) }
    func remove(_ server: String) { var m = all(); m[server] = nil; write(m) }

    /// A usable access token; refreshes when it's (nearly) expired or the server just refused it.
    func accessToken(server: String, forceRefresh: Bool) async throws -> String {
        guard let r = all()[server] else { throw MCPSignInNeeded(server: server) }
        guard forceRefresh || MCPAuthLogic.needsRefresh(r) else { return r.accessToken }
        if let running = refreshing[server] { return try await running.value.accessToken }
        let task = Task { try await Self.refresh(r, server: server) }
        refreshing[server] = task
        defer { refreshing[server] = nil }
        do {
            let fresh = try await task.value
            save(fresh, for: server)
            return fresh.accessToken
        } catch let e as MCPSignInNeeded {
            remove(server)
            throw e
        }
    }

    private static func refresh(_ r: MCPOAuthRecord, server: String) async throws -> MCPOAuthRecord {
        guard let refresh = r.refreshToken, let endpoint = URL(string: r.tokenEndpoint) else { throw MCPSignInNeeded(server: server) }
        let req = MCPAuthLogic.tokenRequest(endpoint, fields: ["grant_type": "refresh_token", "refresh_token": refresh,
                                                               "resource": r.resource],
                                            clientID: r.clientID, secret: r.clientSecret, method: r.authMethod)
        let (data, resp) = try await HTTP.session.data(for: req)            // offline → a normal error; tokens kept
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        if status == 400 || status == 401 { throw MCPSignInNeeded(server: server) }   // invalid_grant: revoked or expired
        guard status == 200, let fresh = MCPAuthLogic.record(from: obj, base: r) else {
            throw ProviderError(message: HTTP.errorMessage(status: status, body: String(data: data, encoding: .utf8) ?? "", provider: server))
        }
        return fresh
    }
}

// MARK: - Browser sign-in

/// One-shot loopback listener bound to 127.0.0.1 for the browser's return.
@MainActor
final class LoopbackCallback {
    private var listener: NWListener?
    private var portWaiter: CheckedContinuation<UInt16, Error>?
    private var callbackWaiter: CheckedContinuation<String, Error>?
    private var judge: (String) -> Bool = { _ in true }

    func start() async throws -> UInt16 {
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let l = try NWListener(using: params)
        listener = l
        l.newConnectionHandler = { [weak self] conn in Task { @MainActor in self?.accept(conn) } }
        return try await withCheckedThrowingContinuation { c in
            portWaiter = c
            l.stateUpdateHandler = { [weak self] state in
                Task { @MainActor in
                    guard let self else { return }
                    switch state {
                    case .ready: if let p = l.port?.rawValue { self.portWaiter?.resume(returning: p); self.portWaiter = nil }
                    case .failed(let e):
                        self.portWaiter?.resume(throwing: ProviderError(message: "Couldn't start the sign-in listener: \(e)"))
                        self.portWaiter = nil
                    default: break
                    }
                }
            }
            l.start(queue: .main)
        }
    }

    /// Waits for `/callback…`; `isSuccess` decides which page the browser shows.
    func waitForCallback(timeout: TimeInterval, isSuccess: @escaping (String) -> Bool) async throws -> String {
        judge = isSuccess
        let t = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            self?.fail(ProviderError(message: "Sign-in timed out — try again."))
        }
        defer { t.cancel() }
        return try await withCheckedThrowingContinuation { callbackWaiter = $0 }
    }

    func stop() {
        listener?.cancel()
        listener = nil
        fail(CancellationError())
    }

    private func fail(_ e: Error) {
        callbackWaiter?.resume(throwing: e)
        callbackWaiter = nil
    }

    private func accept(_ conn: NWConnection) {
        if case let .hostPort(host, _) = conn.endpoint {                  // only this Mac may answer
            let h = "\(host)"
            guard h.hasPrefix("127.") || h == "::1" || h.hasPrefix("::ffff:127.") else { conn.cancel(); return }
        }
        conn.start(queue: .main)
        conn.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, _, _ in
            let request = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            let path = (request.components(separatedBy: "\r\n").first ?? "").split(separator: " ").dropFirst().first.map(String.init) ?? ""
            Task { @MainActor in
                guard let self else { conn.cancel(); return }
                guard path.hasPrefix("/callback") else {                 // favicon etc.
                    conn.send(content: Data("HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8),
                              completion: .contentProcessed { _ in conn.cancel() })
                    return
                }
                let ok = self.judge(path)
                let page = """
                <html><body style="font-family:-apple-system;background:#111;color:#eee;text-align:center;padding-top:80px">
                <h2>\(ok ? "Connected to OpenNotch ✓" : "Sign-in didn't complete")</h2>
                <p>\(ok ? "You can close this tab." : "Go back to OpenNotch and try again.")</p></body></html>
                """
                let response = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(page.utf8.count)\r\nConnection: close\r\n\r\n" + page
                conn.send(content: Data(response.utf8), completion: .contentProcessed { _ in conn.cancel() })
                self.callbackWaiter?.resume(returning: path)
                self.callbackWaiter = nil
            }
        }
    }
}

@MainActor
enum MCPSignIn {
    private static var active: LoopbackCallback?

    /// The whole browser sign-in for one server; saves the tokens. Throws with a readable message.
    static func run(server name: String, url: URL, auth s: MCPAuthServer) async throws {
        active?.stop()
        let loop = LoopbackCallback()
        active = loop
        defer { loop.stop(); if active === loop { active = nil } }

        let port = try await loop.start()
        let redirect = "http://127.0.0.1:\(port)/callback"
        let client = try await MCPAuth.register(s, redirect: redirect)
        let verifier = MCPAuthLogic.randomToken(), state = MCPAuthLogic.randomToken()
        guard let authURL = MCPAuthLogic.authorizeURL(s, clientID: client.id, redirect: redirect,
                                                     challenge: MCPAuthLogic.challenge(for: verifier), state: state) else {
            throw ProviderError(message: "Couldn't build the sign-in link.")
        }
        NSWorkspace.shared.open(authURL)
        let path = try await loop.waitForCallback(timeout: 300) {
            if case .success = MCPAuthLogic.callbackCode(path: $0, state: state) { return true }
            return false
        }
        let code = try MCPAuthLogic.callbackCode(path: path, state: state).get()

        let base = MCPOAuthRecord(accessToken: "", refreshToken: nil, expiresAt: nil, tokenEndpoint: s.tokenEndpoint.absoluteString,
                                  clientID: client.id, clientSecret: client.secret, authMethod: client.method,
                                  resource: s.resource, scope: s.scope)
        let req = MCPAuthLogic.tokenRequest(s.tokenEndpoint, fields: ["grant_type": "authorization_code", "code": code,
                                                                      "redirect_uri": redirect, "code_verifier": verifier,
                                                                      "resource": s.resource],
                                            clientID: client.id, secret: client.secret, method: client.method)
        let (data, resp) = try await HTTP.session.data(for: req)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200, let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let record = MCPAuthLogic.record(from: obj, base: base) else {
            throw ProviderError(message: HTTP.errorMessage(status: status, body: String(data: data, encoding: .utf8) ?? "", provider: name))
        }
        await MCPTokenStore.shared.save(record, for: name)
        AppLog.write("mcp \(name): signed in (\(s.resource))")
    }
}
