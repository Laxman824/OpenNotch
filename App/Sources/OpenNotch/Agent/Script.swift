import Foundation
import JavaScriptCore

/// `run_script`: the model writes a short JavaScript program that calls several read-only tools in one step
/// ("weather for these 8 cities", "the first lines of every file in this folder") instead of one round trip per call.
///
/// Sandbox: a fresh JavaScriptCore context per run — no network, files, timers or modules of its own; the only way
/// out is `tools.<name>(args)`, and only for read-only, parallel-safe tools (`TurnPolicy.parallelSafe`), so nothing
/// that changes anything or asks for permission can run from a script. Limits: CPU time per run (an endless loop is
/// stopped), wall time, number of tool calls, output size. The result is fenced as external content.
enum ScriptLogic {
    static let maxCalls = 30
    static let cpuSeconds = 5.0
    static let wallSeconds = 60.0
    static let maxSource = 8_000

    /// Tools a script may call: read-only and safe to run side by side.
    static func allowed(_ tools: [AgentTool]) -> [AgentTool] {
        tools.filter { $0.risk == .read && TurnPolicy.parallelSafe.contains($0.name) }
    }

    /// The program runs as the body of an async function, so `await` and `return` work at the top level.
    static func wrap(_ source: String) -> String {
        "(async () => {\n\(source)\n})()"
    }

    /// What the model gets back: the return value (JSON when possible), the logs, and which tools ran.
    static func report(value: String?, logs: [String], calls: [String], error: String?) -> (ok: Bool, text: String) {
        var parts: [String] = []
        if let error { parts.append("Script error: \(error)") }
        if let value, value != "undefined" { parts.append("Returned:\n\(value)") }
        if !logs.isEmpty { parts.append("Logs:\n" + logs.joined(separator: "\n")) }
        var counts: [String: Int] = [:]
        for c in calls { counts[c, default: 0] += 1 }
        parts.append("Tool calls: " + (calls.isEmpty ? "none" : counts.sorted { $0.key < $1.key }.map { "\($0.key) ×\($0.value)" }.joined(separator: ", ")))
        if parts.count == 1 && error == nil { parts.insert("The script returned nothing — `return` the result you need.", at: 0) }
        return (error == nil, parts.joined(separator: "\n\n"))
    }

    static func tool(registry: @escaping @Sendable () -> [AgentTool]) -> AgentTool {
        AgentTool(
            name: "run_script",
            description: "Run a short JavaScript program that calls several read-only tools in one step — use it for many similar "
                + "lookups (weather for 8 cities, the first lines of every file in a folder, comparing several pages) instead "
                + "of one call per step. Inside, `await tools.<name>({…same arguments as the tool…})` returns {ok, text}; "
                + "`log(…)` records a line; `return` a value (objects come back as JSON). Promise.all runs calls together. "
                + "Available tools: \(TurnPolicy.parallelSafe.sorted().joined(separator: ", ")). No network, files or timers "
                + "except through those tools; nothing that changes anything. Max \(maxCalls) tool calls, \(Int(wallSeconds)) s.",
            schema: Schema.object(["code": Schema.string("JavaScript: the body of an async function")], required: ["code"]),
            risk: .read, verb: "Running a script", detail: { a in
                let c = a.str("code") ?? ""
                return "\(c.components(separatedBy: "\n").count) lines"
            },
            preview: { a in a.str("code") ?? "" },
            run: { a in
                guard let code = a.str("code"), !code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    return .fail("code is required")
                }
                guard code.count <= maxSource else { return .fail("Keep scripts under \(maxSource) characters.") }
                let r = await ScriptRunner.run(code, tools: allowed(registry()))
                return ToolOutcome(ok: r.ok, text: r.text)
            })
    }
}

/// Runs one script on its own queue (all JavaScriptCore work stays there). Tool calls run as Swift tasks and resolve
/// their promise back on that queue. Finishes once: the script settles, or the wall clock runs out.
enum ScriptRunner {
    private typealias SetLimit = @convention(c) (JSContextGroupRef, Double,
                                                 (@convention(c) (JSContextRef?, UnsafeMutableRawPointer?) -> Bool)?,
                                                 UnsafeMutableRawPointer?) -> Void

    /// `JSContextGroupSetExecutionTimeLimit` is exported by JavaScriptCore but declared in a private header;
    /// without it a `while(true){}` could hang a thread forever, so scripts refuse to run when it's missing.
    private static let setLimit: SetLimit? = {
        guard let sym = dlsym(dlopen(nil, RTLD_NOW), "JSContextGroupSetExecutionTimeLimit") else { return nil }
        return unsafeBitCast(sym, to: SetLimit.self)
    }()

    static var available: Bool { setLimit != nil }

    private final class State: @unchecked Sendable {
        let lock = NSLock()
        var finished = false
        var logs: [String] = []
        var calls: [String] = []
        var cont: CheckedContinuation<(ok: Bool, text: String), Never>?

        func finish(_ r: (ok: Bool, text: String)) {
            lock.lock()
            guard !finished, let c = cont else { lock.unlock(); return }
            finished = true; cont = nil
            lock.unlock()
            c.resume(returning: r)
        }
        var isFinished: Bool { lock.lock(); defer { lock.unlock() }; return finished }
    }

    static func run(_ code: String, tools: [AgentTool], cpu: Double = ScriptLogic.cpuSeconds) async -> (ok: Bool, text: String) {
        guard let setLimit else { return (false, "Scripts aren't available on this Mac (no execution time limit). Call the tools one by one.") }
        let queue = DispatchQueue(label: "opennotch.script")
        let state = State()
        let byName = Dictionary(tools.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
        return await withCheckedContinuation { c in
            state.cont = c
            DispatchQueue.global().asyncAfter(deadline: .now() + ScriptLogic.wallSeconds) {
                state.finish((false, ScriptLogic.report(value: nil, logs: state.logs, calls: state.calls,
                                                        error: "stopped after \(Int(ScriptLogic.wallSeconds)) s").text))
            }
            queue.async {
                guard let ctx = JSContext() else { state.finish((false, "Couldn't start the script engine.")); return }
                setLimit(JSContextGetGroup(ctx.jsGlobalContextRef), cpu, nil, nil)

                let log: @convention(block) () -> Void = {
                    let parts = (JSContext.currentArguments() as? [JSValue] ?? []).map { v -> String in
                        v.isObject ? (v.context.objectForKeyedSubscript("JSON").invokeMethod("stringify", withArguments: [v])?.toString() ?? "") : (v.toString() ?? "")
                    }
                    state.lock.lock(); if state.logs.count < 200 { state.logs.append(String(parts.joined(separator: " ").prefix(2000))) }; state.lock.unlock()
                }
                ctx.setObject(log, forKeyedSubscript: "log" as NSString)

                let toolsObj = JSValue(newObjectIn: ctx)!
                for (name, tool) in byName {
                    let call: @convention(block) (JSValue?) -> JSValue = { args in
                        let json: String = {
                            guard let a = args, a.isObject else { return "{}" }
                            return a.context.objectForKeyedSubscript("JSON").invokeMethod("stringify", withArguments: [a])?.toString() ?? "{}"
                        }()
                        // JSContext.current(), not `ctx`: capturing the context in a block it owns would leak it.
                        return JSValue(newPromiseIn: JSContext.current()) { resolve, _ in
                            state.lock.lock()
                            let over = state.calls.count >= ScriptLogic.maxCalls
                            if !over { state.calls.append(name) }
                            state.lock.unlock()
                            func settle(_ o: ToolOutcome) {
                                queue.async {
                                    guard !state.isFinished else { return }
                                    resolve?.call(withArguments: [["ok": o.ok, "text": o.text]])
                                }
                            }
                            if over { settle(.fail("Tool budget for this script (\(ScriptLogic.maxCalls) calls) is used up.")); return }
                            guard HTTP.parse(json) != nil else { settle(.fail("Arguments must be an object.")); return }
                            Task.detached { settle(ResultBudget.apply(await tool.run(ToolArgs(json: json)), tool: name, limit: 12_000)) }
                        }
                    }
                    toolsObj.setObject(call, forKeyedSubscript: name as NSString)
                }
                ctx.setObject(toolsObj, forKeyedSubscript: "tools" as NSString)

                ctx.exceptionHandler = { _, e in
                    state.finish(ScriptLogic.report(value: nil, logs: state.logs, calls: state.calls, error: e?.toString() ?? "unknown error"))
                }
                let done: @convention(block) (JSValue?) -> Void = { v in
                    let text: String? = v.flatMap { v in
                        if v.isUndefined { return nil }
                        if v.isString { return v.toString() }
                        return v.context.objectForKeyedSubscript("JSON").invokeMethod("stringify", withArguments: [v, JSValue(nullIn: v.context)!, 2])?.toString()
                    }
                    state.finish(ScriptLogic.report(value: text, logs: state.logs, calls: state.calls, error: nil))
                }
                let failed: @convention(block) (JSValue?) -> Void = { e in
                    state.finish(ScriptLogic.report(value: nil, logs: state.logs, calls: state.calls, error: e?.toString() ?? "rejected"))
                }
                guard let p = ctx.evaluateScript(ScriptLogic.wrap(code)), !state.isFinished else { return }
                p.invokeMethod("then", withArguments: [JSValue(object: done, in: ctx)!, JSValue(object: failed, in: ctx)!])
            }
        }
    }
}
