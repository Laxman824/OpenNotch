// PaletteLogic: fuzzy scoring and drop suggestions. Run: checks/run.sh
var failed = 0, total = 0
func check(_ name: String, _ ok: Bool) { total += 1; if !ok { failed += 1; print("FAIL \(name)") } }
let S = PaletteLogic.score
check("empty query matches", S("", "New chat") == 0)
check("subsequence", S("nc", "New chat") != nil)
check("out of order fails", S("cn", "New chat") == nil)
check("missing char fails", S("nwz", "New chat") == nil)
check("prefix beats middle", S("tim", "Timers")! > S("tim", "Start a timer")!)
check("word starts beat scattered", S("hf", "Hands-free")! > S("hf", "Shelf")!)
check("case/space insensitive", S("Ne W", "new chat") != nil)
func sug(_ items: [(kind: String, value: String)]) -> String { PaletteLogic.suggestions(for: items).first ?? "" }
check("pdf", sug([("file", "/x/offer.PDF")]) == "Summarise this")
check("image", sug([("file", "/x/a.heic")]) == "Describe this image")
check("code", sug([("file", "/x/app.swift")]) == "Explain this code")
check("csv", sug([("file", "/x/d.csv")]) == "Summarise the data")
check("two files", sug([("file", "/a.pdf"), ("file", "/b.pdf")]) == "Compare these")
check("screenshot", sug([("screenshot", "/tmp/s.png")]) == "Explain what's on screen")
check("web", sug([("web", "Title\nhttps://x.com")]) == "Summarise this page")
check("unknown ext", sug([("file", "/x/thing.bin")]) == "What is this?")
check("nothing", PaletteLogic.suggestions(for: []).isEmpty)
print(failed == 0 ? "palette: \(total)/\(total) pass" : "palette: \(failed) FAILED")
if failed > 0 { exit(1) }
