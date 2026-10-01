// VoiceTurn regression cases. Run: checks/run.sh
var vfailed = 0
func vcheck(_ name: String, _ ok: Bool) { if !ok { vfailed += 1; print("FAIL \(name)") } }
vcheck("trailing and", VoiceTurn.silenceNeeded("remind me to call mom and") > 2)
vcheck("trailing um", VoiceTurn.silenceNeeded("what's on my calendar um") > 2)
vcheck("comma", VoiceTurn.silenceNeeded("first check my mail,") > 2)
vcheck("question", VoiceTurn.silenceNeeded("what's the weather in Hyderabad today?") < 1)
vcheck("plain", VoiceTurn.silenceNeeded("open my offer letter from Acme") <= 1.2)
vcheck("short", VoiceTurn.silenceNeeded("what's") >= 1.5)
vcheck("exit", VoiceTurn.command("Okay, goodbye.") == .exit)
vcheck("exit2", VoiceTurn.command("Go to sleep Ledge") == .exit)
vcheck("repeat", VoiceTurn.command("Say that again?") == .repeatLast)
vcheck("slower", VoiceTurn.command("slow down please") == .slower)
vcheck("stop", VoiceTurn.command("Stop.") == .stopTalking)
vcheck("show", VoiceTurn.command("show me") == .show)
vcheck("new", VoiceTurn.command("Ledge, new chat") == .newChat)
// Must NOT be commands — these are requests for Ledge.
vcheck("not: stop server", VoiceTurn.command("stop the dev server") == nil)
vcheck("not: repeat test", VoiceTurn.command("repeat that test with verbose output") == nil)
vcheck("not: show files", VoiceTurn.command("show me my downloads") == nil)
vcheck("not: bye mention", VoiceTurn.command("draft a goodbye email to my team") == nil)
vcheck("tool mail", VoiceTurn.toolPhrase("gmail_search") == "Checking your email.")
vcheck("tool quiet", VoiceTurn.toolPhrase("media_control") == nil)
vcheck("tool unknown", VoiceTurn.toolPhrase("todo_write") == nil)
vcheck("slow none", VoiceTurn.slowNotice(elapsed: 12, tool: "") == nil)
vcheck("slow 1", VoiceTurn.slowNotice(elapsed: 25, tool: "gmail_search")?.level == 1
       && VoiceTurn.slowNotice(elapsed: 25, tool: "gmail_search")!.text.contains("longer than expected")
       && VoiceTurn.slowNotice(elapsed: 25, tool: "gmail_search")!.text.contains("gmail search"))
vcheck("slow 2", VoiceTurn.slowNotice(elapsed: 75, tool: "")?.level == 2)
vcheck("slow 3", VoiceTurn.slowNotice(elapsed: 130, tool: "")?.text.contains("2 minutes") == true)
print(vfailed == 0 ? "voiceturn: 24/24 pass" : "voiceturn: \(vfailed) FAILED")
if vfailed > 0 { exit(1) }
