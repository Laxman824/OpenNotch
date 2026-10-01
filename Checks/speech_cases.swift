// SpeechText regression cases. Run: checks/run.sh
var failed = 0
func check(_ name: String, _ got: String, _ want: String) {
    if got != want { failed += 1; print("FAIL \(name)\n  want \(want)\n  got  \(got)") }
}
check("markdown", SpeechText.clean("## Plan\n- **Read** `config.py`\n- Then run [tests](https://x.io)\n```python\nprint(1)\n```\nSaved to /Users/you/Downloads/offer_letter.pdf."),
      "Plan. Read config.py. Then run tests. I've put the code in the notch. Saved to offer letter.pdf.")
check("decimal", SpeechText.clean("It costs 3.5 dollars. Done."), "It costs 3.5 dollars. Done.")
var pending = "", spoken: [String] = []
for chunk in ["Sure. I found three files", " in Downloads. The newest is your offer", " letter from Acme! Want me to", " open it? Version 3", ".5 is out."] {
    pending += chunk
    while let cut = SpeechText.sentenceCut(pending) { spoken.append(String(pending[..<cut])); pending.removeSubrange(..<cut) }
}
check("stream", spoken.joined(separator: "|"), "Sure. I found three files in Downloads. |The newest is your offer letter from Acme! ")
check("tail", pending, "Want me to open it? Version 3.5 is out.")
print(failed == 0 ? "speech: 4/4 pass" : "speech: \(failed) FAILED")
if failed > 0 { exit(1) }
