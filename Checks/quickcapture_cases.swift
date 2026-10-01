// Quick-capture regression cases. Run: checks/run.sh
// Expected strings use a fixed "now" of 2026-09-30 11:00 (Wednesday).
let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm"
let now = f.date(from: "2026-09-30 11:00")!
func show(_ i: QuickIntent?) -> String {
    guard let i else { return "agent" }
    switch i {
    case let .reminder(t, d, timed): return "reminder|\(t)|\(d.map { f.string(from: $0) } ?? "-")|\(timed)"
    case let .note(b): return "note|\(b)"
    case let .event(t, s, e): return "event|\(t)|\(f.string(from: s))|\(f.string(from: e))"
    }
}
let cases: [(String, String)] = [
    ("remind me to call HR at 4", "reminder|Call HR|2026-09-30 16:00|true"),
    ("remind me to call HR at 4pm tomorrow", "reminder|Call HR|2026-10-01 16:00|true"),
    ("Hey Ledge, remind me to renew my passport next Monday", "reminder|Renew my passport|2026-10-05 12:00|false"),
    ("remind me in 2 hours to stretch", "reminder|Stretch|2026-09-30 13:00|true"),
    ("remind me to buy milk", "reminder|Buy milk|-|false"),
    ("todo: update resume", "reminder|Update resume|-|false"),
    ("add review Acme offer to my todo list", "reminder|Review Acme offer|-|false"),
    ("note: the rate limiter should use a token bucket", "note|the rate limiter should use a token bucket"),
    ("note that Priya prefers Tuesday calls", "note|Priya prefers Tuesday calls"),
    ("add standup tomorrow at 10am", "event|Standup|2026-10-01 10:00|2026-10-01 10:30"),
    ("schedule a call with Priya on Friday 3pm", "event|Call with Priya|2026-10-02 15:00|2026-10-02 15:30"),
    ("add meeting: design review tomorrow from 2 to 3pm", "event|Design review|2026-10-01 14:00|2026-10-01 15:00"),
    ("add lunch with Ravi to my calendar tomorrow at 1pm", "event|Lunch with Ravi|2026-10-01 13:00|2026-10-01 13:30"),
    // Must reach the agent, never be captured:
    ("add tests for the parser", "agent"),
    ("note how the router works in agent/loop.py and explain it", "agent"),
    ("schedule the script to run nightly", "agent"),
    ("remind me what we discussed yesterday?", "agent"),
    ("add a meeting summary section to the README", "agent"),
    ("what's on my calendar tomorrow", "agent"),
    ("remind me to pay rent yesterday", "agent"),
]
var failed = 0
for (input, want) in cases {
    let got = show(QuickCapture.parse(input, now: now))
    if got != want { failed += 1; print("FAIL  \(input)\n      want \(want)\n      got  \(got)") }
}
print(failed == 0 ? "quickcapture: \(cases.count)/\(cases.count) pass" : "quickcapture: \(failed) FAILED")
if failed > 0 { exit(1) }
