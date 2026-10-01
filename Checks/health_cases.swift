// HealthLogic: CPU maths, ps parsing, keep-awake label. Run: checks/run.sh
var failed = 0, total = 0
func check(_ name: String, _ ok: Bool) { total += 1; if !ok { failed += 1; print("FAIL \(name)") } }
let u = HealthLogic.cpuUsage(prev: [100, 50, 800, 50], now: [400, 150, 900, 150])!
check("usage 500/600 busy", abs(u - 500.0 / 600.0) < 1e-9)
check("idle only", HealthLogic.cpuUsage(prev: [0, 0, 0, 0], now: [0, 0, 100, 0]) == 0)
check("no ticks", HealthLogic.cpuUsage(prev: [1, 1, 1, 1], now: [1, 1, 1, 1]) == nil)
check("wraparound", HealthLogic.cpuUsage(prev: [UInt32.max - 9, 0, 0, 0], now: [10, 0, 20, 0]).map { abs($0 - 0.5) < 1e-9 } == true)
check("bad input", HealthLogic.cpuUsage(prev: [1], now: [2]) == nil)
let ps = """
 %CPU COMM
187.3 node
 45,0 Google Chrome Helper
"""
let top = HealthLogic.topProcess(ps)
check("top cpu", top?.0 == 187.3 && top?.1 == "node")
check("skips ps itself", HealthLogic.topProcess("  RSS COMM\n 900 ps\n 812000 Xcode\n")?.1 == "Xcode")
check("name with spaces", HealthLogic.topProcess(" %CPU COMM\n 45,0 Google Chrome Helper\n")?.1 == "Google Chrome Helper")
check("empty", HealthLogic.topProcess("") == nil)
let now = Date(timeIntervalSince1970: 1_000_000)
check("awake off", HealthLogic.awakeLabel(until: nil, now: now) == "")
check("awake forever", HealthLogic.awakeLabel(until: .distantFuture, now: now) == "∞")
check("awake 42m", HealthLogic.awakeLabel(until: now.addingTimeInterval(41 * 60 + 5), now: now) == "42m")
check("awake 1:05h", HealthLogic.awakeLabel(until: now.addingTimeInterval(65 * 60), now: now) == "1:05h")
check("awake last seconds", HealthLogic.awakeLabel(until: now.addingTimeInterval(3), now: now) == "1m")
print(failed == 0 ? "health: \(total)/\(total) pass" : "health: \(failed) FAILED")
if failed > 0 { exit(1) }
