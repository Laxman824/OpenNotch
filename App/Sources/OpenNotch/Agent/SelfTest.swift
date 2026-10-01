import Foundation

/// `OpenNotch --selftest <provider> [model]` — one real agent turn from the
/// terminal, for contributors and CI. The key comes from $OPENNOTCH_KEY and is
/// never stored; nothing is loaded from or saved to your chats; anything that
/// needs approval is declined automatically. Prompt: $OPENNOTCH_PROMPT.
@MainActor
enum SelfTest {
    static func start() {
        Task { @MainActor in
            let code = await run()
            exit(code)
        }
    }

    static func run() async -> Int32 {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--selftest"), i + 1 < args.count,
              let kind = ProviderKind(rawValue: args[i + 1]) else {
            print("usage: OpenNotch --selftest <\(ProviderKind.allCases.map(\.rawValue).joined(separator: "|"))> [model]")
            return 2
        }
        let key = ProcessInfo.processInfo.environment["OPENNOTCH_KEY"]
        var model = i + 2 < args.count ? args[i + 2] : nil
        do {
            let models = try await ProviderStore.test(kind, key: key)
            print("✓ \(kind.label): \(models.count) models available")
            if model == nil { model = ProviderKind.pickDefault(kind, from: models) }
        } catch {
            print("✗ connection test failed: \(error.localizedDescription)")
            return 1
        }
        guard let provider = ProviderStore.make(kind, model: model, key: key) else {
            print("✗ couldn't build the provider (missing key or model)")
            return 1
        }
        print("model: \(provider.model)")
        let prompt = ProcessInfo.processInfo.environment["OPENNOTCH_PROMPT"]
            ?? "What is 17 × 23? Then use the system_info tool and tell me which macOS version I'm on, in one line."
        let core = AgentCore(ephemeral: provider)
        var failed = false
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            core.emit = { ev in
                switch ev["type"] as? String ?? "" {
                case "text": print(ev["delta"] as? String ?? "", terminator: ""); fflush(stdout)
                case "tool": print("\n  [tool \(ev["state"] ?? "")] \(ev["verb"] ?? "") \(ev["detail"] ?? "")\(ev["error"].map { " — \($0)" } ?? "")")
                case "approval":
                    print("\n  [approval requested: \(ev["tool"] ?? "") — auto-declined in self-test]")
                    core.approve(id: ev["id"] as? String ?? "", allow: false)
                case "error": failed = true; print("\n  [error] \(ev["text"] ?? "")")
                case "info": print("\n  [info] \(ev["text"] ?? "")")
                case "done":
                    print("\n✓ done in \(ev["ms"] ?? 0) ms · \(ev["toolCalls"] ?? 0) tool calls · \(ev["inTokens"] ?? 0) in / \(ev["outTokens"] ?? 0) out tokens")
                    done.resume()
                default: break
                }
            }
            print("> \(prompt)\n")
            core.send(prompt, display: nil)
        }
        return failed ? 1 : 0
    }
}
