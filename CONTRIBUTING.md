# Contributing to OpenNotch

Thanks for helping! A few ground rules keep the app fast and crash-free:

1. **No audio or TCC-protected file work on the main thread.** Audio objects live on their own
   serial queues; results hop back with `DispatchQueue.main.async`.
2. **Every AVFoundation node call goes through `avSafe(...)`** — AVFoundation raises Objective-C
   exceptions Swift can't catch.
3. **Before anything that can show a permission dialog, call `notch.yieldForSystemPrompt(...)`** —
   otherwise the notch covers the dialog.
4. **No always-on 60 fps loops, no per-frame blurs or shadows.** Use `AnimationPolicy.shared.fps`.
5. **Narrow fast paths stay narrow.** Adding a pattern to quick capture, voice commands or the music
   fast path? Add a must-NOT case to `Checks/` too.
6. **Tools report failure as failure.** Never tell the model something worked when it didn't.
7. **Agent text is set with `textContent`, never `innerHTML`**, in the desktop web view.

Pure logic goes in a small `enum` so `Checks/run.sh` can compile it with a `*_cases.swift` file.
Run `Checks/run.sh` and `node Desktop/test/sim.mjs` before opening a PR.
