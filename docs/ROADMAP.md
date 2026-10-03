# Roadmap

## Phase 1 — Foundation ✅ (this commit)
- Standalone repo, MIT, generic identifiers (`dev.opennotch.*`), data in `~/Library/Application Support/OpenNotch`.
- In-process `AgentCore` (Swift) replaces the old Python server; same event vocabulary as before.
- Native music control (`MediaControl`, `MediaIntent` fast path), local chat sessions (`SessionStore`).
- Settings › AI placeholder; scripts for build, local signing, DMG.

## Phase 2 — AI connections ✅
- Providers: OpenAI-compatible (OpenAI, OpenRouter, Groq, Gemini, Ollama, LM Studio), Anthropic
  Messages (streaming, tool use, raw block replay, prompt caching, refusal fallback), Apple on-device.
- Keys in the Keychain; **Sign in with OpenRouter** (OAuth PKCE, loopback); local auto-detect;
  live connection test + model list; model picker; Settings › AI.
- Rate limits: waits as the server suggests (≤ 20 s) and retries twice before any output.
- **Pending:** Sign in with ChatGPT — needs an OpenAI-issued client ID (open-source apps apply via
  OpenAI's Sign in with ChatGPT interest form). Anthropic path not yet tested with a live key.

## Phase 3 — Agent ✅ (core)
- Tool loop: approvals (Approve card, 5-min timeout = deny), Stop, 40 tools per message, repeat
  bounce at 3, INVALID_JSON handling, result budget (40k chars, full text spilled to a file),
  read-before-write + staleness, plan (todo_write), memory (local JSON), traces for the usage heatmap,
  context window (≤ 300k chars, ≤ 2 image turns).
- 26 tools: read_file (text/PDF/Word/images), list_directory, search_text, find_files, write_file,
  edit_file, run_command, fetch_url, web_search, open, media_control, clipboard, screenshot,
  system_info, timer, keep_awake, notes, calendar_events, create_event, create_reminder, remember,
  forget, todo_write.
- MCP client (stdio, `mcpServers` config, autoApprove).
- `--selftest` (one live turn) and `--checks` (42 in-process assertions).

## Phase 3c — smarter agent ✅ (checks; not yet live)
- Time-aware messages, parallel read-only tools, external-content fence, allow-for-chat approvals.
- Memory: suggested facts (approve to save), `recall`, Settings › AI › Memory; `search_chats`; long-chat summaries.
- Brave/Tavily web search, main-content page text, context-aware router, Apple on-device read-only tools.
- Follow-up chips, "Ready" ear, tool-using morning brief, Mail.app inbox check, `--eval` set (24 cases).

## Phase 3b — next
- Computer use (click/type in apps, with the cursor-courtesy rules from the original).
- Personal document search (SQLite FTS5), meeting transcription.
- Background jobs that keep running while you start another chat (today a new chat stops the turn).
- Grow the eval set from real traces; track scores per model.

## Phase 4 — Onboarding & avatars
- First-run flow: ✅ in-notch welcome → AI → try one (permissions on first use). Next: companion picker with live 3D previews.
- More avatars; **VRM** support (the open avatar format VRoid Studio exports) — needs a three.js upgrade.

## Phase 5 — Release
- Free: sign every release with one maintainer "OpenNotch Local Signing" certificate (back it up —
  users keep their permissions across updates), DMG on GitHub Releases, "Open Anyway" guide.
- Later ($99/yr Developer ID): notarisation (`scripts/build.sh` switches automatically), Sparkle
  auto-updates, official Homebrew cask, landing page.

## Open questions
- Default desktop avatar: the "Ledge" hoodie character was modelled on the maintainer — keep, or
  make a new default look?
