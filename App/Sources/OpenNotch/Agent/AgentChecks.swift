import Foundation

/// `OpenNotch --checks` — in-process assertions for the agent's pure logic
/// (run by Checks/run.sh). No network, no user data.
@MainActor
enum AgentChecks {
    private static var failed = 0, total = 0

    private static func check(_ name: String, _ ok: Bool) {
        total += 1
        if !ok { failed += 1; print("FAIL \(name)") }
    }

    static func run() async -> Int32 {
        // Context window
        var msgs: [ChatMessage] = [ChatMessage(role: .assistant, text: "orphan"), ChatMessage(role: .tool, text: "r", toolCallId: "x")]
        for i in 0..<10 {
            msgs.append(ChatMessage(role: .user, text: "q\(i)", images: ["/tmp/a\(i).png"]))
            msgs.append(ChatMessage(role: .assistant, text: String(repeating: "a", count: 1000)))
        }
        let w = AgentCore.window(msgs, maxChars: 5000)
        check("window starts at a user message", w.first?.role == .user)
        check("window respects the size cap", w.reduce(0) { $0 + $1.text.count } <= 5000)
        check("window keeps images on at most 2 turns", w.filter { $0.images?.isEmpty == false }.count <= 2)
        check("window keeps the latest turn", w.last?.text == msgs.last?.text)

        // Retry delay
        check("retry: body seconds", HTTP.retryDelay(header: nil, body: "Please try again in 11.0025s. Need more") == 11.0025)
        check("retry: header", HTTP.retryDelay(header: "3", body: "") == 3)
        check("retry: default", HTTP.retryDelay(header: nil, body: "overloaded") == 2)

        // Forbidden commands
        for c in ["rm -rf /", "rm -rf ~", "sudo ls", "dd if=x of=/dev/disk2", "diskutil eraseDisk APFS x disk2"] {
            check("blocked: \(c)", ToolKit.isForbidden(c))
        }
        for c in ["rm -rf build", "ls -la ~", "git status", "rm -rf ./node_modules"] {
            check("allowed: \(c)", !ToolKit.isForbidden(c))
        }

        // DuckDuckGo parsing
        let html = """
        <a rel="nofollow" class="result__a" href="//duckduckgo.com/l/?uddg=https%3A%2F%2Fswift.org%2Fdocs&amp;rut=1">Swift &amp; Docs</a>
        <a class="result__snippet" href="x">The <b>Swift</b> language.</a>
        """
        let r = ToolKit.parseDuckDuckGo(html)
        check("ddg: url decoded", r.first?.url == "https://swift.org/docs")
        check("ddg: title cleaned", r.first?.title == "Swift & Docs")
        check("ddg: snippet", r.first?.snippet == "The Swift language.")

        // MCP names
        let n = MCPManager.wireName(server: "my server", tool: "get.thing")
        check("mcp name", n == "mcp__my_server__get_thing")
        check("mcp name length", MCPManager.wireName(server: String(repeating: "s", count: 50), tool: String(repeating: "t", count: 50)).count <= 64)

        // Default models
        check("default anthropic", ProviderKind.pickDefault(.anthropic, from: []) == "claude-opus-5-5")
        check("default openai", ProviderKind.pickDefault(.openai, from: ["gpt-4o", "gpt-5"]) == "gpt-5")
        check("default openrouter", ProviderKind.pickDefault(.openrouter, from: ["x"]) == "openrouter/auto")
        check("default ollama", ProviderKind.pickDefault(.ollama, from: ["llama3.2"]) == "llama3.2")

        // Path policy
        let home = NSHomeDirectory()
        check("path: /etc blocked", PathPolicy.check("/etc/passwd", write: false) != nil)
        check("path: home write ok", PathPolicy.check(home + "/Documents/x.txt", write: true) == nil)
        check("path: ssh blocked", PathPolicy.check(home + "/.ssh/id_ed25519", write: false) != nil)
        check("path: sessions blocked", PathPolicy.check(AppPaths.root + "/sessions/current.json", write: false) != nil)
        check("path: tilde", PathPolicy.resolve("~/x").hasPrefix(home))

        // Read-before-write
        let dir = NSTemporaryDirectory() + "opennotch-checks-\(UUID().uuidString)"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let f = PathPolicy.resolve(dir + "/a.txt")
        try? "one".write(toFile: f, atomically: true, encoding: .utf8)
        await FileState.shared.reset()
        check("rbw: unread file refused", await FileState.shared.problem(f)?.hasPrefix("read_before_write") == true)
        await FileState.shared.record(f)
        check("rbw: read file ok", await FileState.shared.problem(f) == nil)
        try? "one two".write(toFile: f, atomically: true, encoding: .utf8)
        check("rbw: changed file stale", await FileState.shared.problem(f)?.hasPrefix("stale_file") == true)
        check("rbw: new file ok", await FileState.shared.problem(dir + "/new.txt") == nil)
        let edit = await ToolKit.editFile(ToolArgs(json: #"{"path":"\#(f)","old_string":"one","new_string":"1"}"#))
        check("edit refused when stale", !edit.ok)
        _ = await ToolKit.readFile(ToolArgs(json: #"{"path":"\#(f)"}"#))
        let edit2 = await ToolKit.editFile(ToolArgs(json: #"{"path":"\#(f)","old_string":"one","new_string":"1"}"#))
        check("edit after read", edit2.ok && (try? String(contentsOfFile: f, encoding: .utf8)) == "1 two")
        try? FileManager.default.removeItem(atPath: dir)

        // HTML → text
        let t = ToolKit.htmlToText("<html><head><title>Hi &amp; bye</title><script>x()</script></head><body><p>One</p><p>Two</p></body></html>",
                                   url: URL(string: "https://e.com")!)
        check("html: title", t.hasPrefix("# Hi & bye"))
        check("html: no script", !t.contains("x()"))
        check("html: paragraphs", t.contains("One") && t.contains("Two"))

        // OpenAI wire: tool calls echo extra_content (Gemini thought signatures)
        let m = ChatMessage(role: .assistant, text: "", toolCalls: [ToolCall(id: "c1", name: "t", arguments: "{}",
                                                                           extra: #"{"google":{"thought_signature":"sig"}}"#)])
        let wired = OpenAICompatibleProvider.wire(true)(m)
        let calls = wired?["tool_calls"] as? [[String: Any]]
        check("wire: tool call id", calls?.first?["id"] as? String == "c1")
        check("wire: extra echoed", ((calls?.first?["extra_content"] as? [String: Any])?["google"] as? [String: Any])?["thought_signature"] as? String == "sig")
        let tool = OpenAICompatibleProvider.wire(true)(ChatMessage(role: .tool, text: "ok", toolCallId: "c1"))
        check("wire: tool result", tool?["tool_call_id"] as? String == "c1" && tool?["role"] as? String == "tool")

        print(failed == 0 ? "agent: \(total)/\(total) pass" : "agent: \(failed) of \(total) FAILED")
        return failed == 0 ? 0 : 1
    }
}
