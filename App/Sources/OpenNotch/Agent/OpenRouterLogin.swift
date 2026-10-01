import AppKit
import CryptoKit
import Foundation
import Network

/// "Sign in with OpenRouter" — OAuth PKCE with a one-shot loopback listener.
/// The browser returns a single-use code to http://localhost:<port>/callback;
/// we trade it (plus the verifier only this app knows) for a user-controlled
/// API key, stored in the Keychain.
@MainActor
final class OpenRouterLogin {
    static let shared = OpenRouterLogin()
    private var listener: NWListener?
    private var verifier = ""
    private var done: ((Result<String, Error>) -> Void)?
    private var timeout: DispatchWorkItem?

    func start(_ completion: @escaping (Result<String, Error>) -> Void) {
        cancel()
        done = completion
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        verifier = Self.b64url(Data(bytes))
        let challenge = Self.b64url(Data(SHA256.hash(data: Data(verifier.utf8))))

        do {
            let l = try NWListener(using: .tcp, on: .any)
            listener = l
            l.newConnectionHandler = { [weak self] conn in
                Task { @MainActor in self?.accept(conn) }
            }
            l.stateUpdateHandler = { [weak self] state in
                Task { @MainActor in
                    guard let self else { return }
                    switch state {
                    case .ready:
                        guard let port = l.port?.rawValue else { return }
                        var c = URLComponents(string: "https://openrouter.ai/auth")!
                        c.queryItems = [
                            .init(name: "callback_url", value: "http://localhost:\(port)/callback"),
                            .init(name: "code_challenge", value: challenge),
                            .init(name: "code_challenge_method", value: "S256"),
                            .init(name: "key_label", value: "OpenNotch"),
                        ]
                        if let url = c.url { NSWorkspace.shared.open(url) }
                    case .failed(let e):
                        self.finish(.failure(ProviderError(message: "Couldn't start the sign-in listener: \(e)")))
                    default: break
                    }
                }
            }
            l.start(queue: .main)
        } catch {
            finish(.failure(error))
            return
        }
        let t = DispatchWorkItem { [weak self] in
            self?.finish(.failure(ProviderError(message: "Sign-in timed out — try again.")))
        }
        timeout = t
        DispatchQueue.main.asyncAfter(deadline: .now() + 300, execute: t)
    }

    func cancel() {
        listener?.cancel()
        listener = nil
        timeout?.cancel()
        done = nil
    }

    private func accept(_ conn: NWConnection) {
        // Only this Mac may answer.
        if case let .hostPort(host, _) = conn.endpoint {
            let h = "\(host)"
            guard h.hasPrefix("127.") || h == "::1" || h.hasPrefix("::ffff:127.") || h.lowercased() == "localhost" else {
                conn.cancel(); return
            }
        }
        conn.start(queue: .main)
        conn.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, _, _ in
            let request = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            let firstLine = request.components(separatedBy: "\r\n").first ?? ""
            let path = firstLine.split(separator: " ").dropFirst().first.map(String.init) ?? ""
            let code = URLComponents(string: "http://x" + path)?.queryItems?.first { $0.name == "code" }?.value
            let ok = code != nil
            let page = """
            <html><body style="font-family:-apple-system;background:#111;color:#eee;text-align:center;padding-top:80px">
            <h2>\(ok ? "You're signed in to OpenNotch ✓" : "Sign-in didn't complete")</h2>
            <p>\(ok ? "You can close this tab." : "Go back to OpenNotch and try again.")</p></body></html>
            """
            let response = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(page.utf8.count)\r\nConnection: close\r\n\r\n" + page
            conn.send(content: Data(response.utf8), completion: .contentProcessed { _ in conn.cancel() })
            Task { @MainActor in
                guard let self else { return }
                if let code { await self.exchange(code) }
            }
        }
    }

    private func exchange(_ code: String) async {
        listener?.cancel()
        listener = nil
        var req = URLRequest(url: URL(string: "https://openrouter.ai/api/v1/auth/keys")!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = HTTP.json(["code": code, "code_verifier": verifier, "code_challenge_method": "S256"])
        do {
            let (data, resp) = try await HTTP.session.data(for: req)
            let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
            guard status == 200, let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let key = obj["key"] as? String, !key.isEmpty else {
                throw ProviderError(message: HTTP.errorMessage(status: status, body: String(data: data, encoding: .utf8) ?? "", provider: "OpenRouter"))
            }
            finish(.success(key))
        } catch {
            finish(.failure(error))
        }
    }

    private func finish(_ r: Result<String, Error>) {
        timeout?.cancel()
        listener?.cancel()
        listener = nil
        let d = done
        done = nil
        d?(r)
    }

    private static func b64url(_ d: Data) -> String {
        d.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
