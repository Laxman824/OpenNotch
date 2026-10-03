// MediaIntent: the no-model music fast path (ported from the Python tests). Run: Checks/run.sh
var failed = 0, total = 0
func check(_ name: String, _ got: MediaIntent.Command?, _ want: MediaIntent.Command?) {
    total += 1
    if got != want { failed += 1; print("FAIL \(name): want \(String(describing: want)) got \(String(describing: got))") }
}
typealias C = MediaIntent.Command
let yes: [(String, C)] = [
    ("play some music", C(action: "play")), ("turn on music", C(action: "play")), ("Pause", C(action: "pause")),
    ("Hey Ledge, pause the music.", C(action: "pause")), ("next song", C(action: "next")), ("skip", C(action: "next")),
    ("previous track", C(action: "previous")), ("what's playing?", C(action: "now_playing")),
    ("volume 40", C(action: "volume", level: 40)), ("play arijit singh", C(action: "play_query", query: "arijit singh")),
    // Seen live: this became a Spotify search for "some music for me on music app".
    ("Play some music for me on music app", C(action: "play")), ("play music on spotify please", C(action: "play")),
    ("play arijit singh on spotify", C(action: "play_query", query: "arijit singh")),
    ("play lofi beats for me", C(action: "play_query", query: "lofi beats")),
]
for (t, c) in yes { check(t, MediaIntent.parse(t), c) }
for t in ["play around with the parser", "play with the new API and tell me what breaks", "run the tests",
          "explain how the Spotify web API works", "stop the dev server and restart it with the new flags please",
          "play the video file in downloads", "play around with the music app settings for me",
          "play with the spotify api in the music app", "now", ""] {
    check("agent: \(t)", MediaIntent.parse(t), nil)
}
check("custom name", MediaIntent.parse("ok nova, next song", assistantName: "Nova"), C(action: "next"))
print(failed == 0 ? "media: \(total)/\(total) pass" : "media: \(failed) FAILED")
if failed > 0 { exit(1) }
