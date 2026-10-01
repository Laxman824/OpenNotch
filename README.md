# OpenNotch

**An open-source AI assistant that lives in your MacBook's notch — with Ledge, a little 3D companion who walks your screen.**

Hover the notch (or press ⌥Space) and ask anything. Music, timers, clipboard, notes, calendar,
captures and a dozen more tools live there too, Dynamic-Island style. Everything runs on your Mac:
your chats are stored locally, and the only network traffic goes to the AI you choose.

> **Status: early (0.1).** Works today: the notch, modules, pop-ups, the desktop companion, and the
> AI agent with tools. See [docs/ROADMAP.md](docs/ROADMAP.md) for what's next.

## Connect an AI

Open **Settings › AI** (notch menu › Settings…) and pick one:

| Option | What you need |
|---|---|
| **Sign in with OpenRouter** | An OpenRouter account — one login gives you Claude, GPT, Gemini and free models, with your own spending limit |
| **Paste an API key** | A key from OpenAI, Anthropic, Google Gemini (free tier available) or Groq — stored in your Keychain |
| **Ollama / LM Studio** | Either app running with a model downloaded — fully local and free |
| **Apple on-device** | macOS 26 with Apple Intelligence turned on — no setup, offline |
| Sign in with ChatGPT | Coming once OpenAI issues OpenNotch its client ID |

The assistant can read and edit files, run shell commands, search and read the web, open apps and
links, control music, look at your screen, check your calendar, add events and reminders, set timers,
keep notes, remember preferences and plan multi-step work. **Anything risky — shell commands, file
changes, calendar edits — shows an Approve button first.**

### Connectors (MCP)

Add more tools (GitHub, Gmail, Slack, a browser…) with any [MCP](https://modelcontextprotocol.io)
server: **Settings › AI › Edit mcp.json**, using the common `mcpServers` format. Connector tools ask for
approval unless you list them under `"autoApprove"`.

## Features

- **Ask from the notch** — streaming answers, Markdown, one-tap suggestions for anything you drop on it, and a ⌘K command palette.
- **Hands-free voice** — talk, hear the answer, interrupt any time. Speech recognition runs on device.
- **Live activities** — album art and a Siri-style wave for music (with a hover player and scrubbing), progress rings for timers, and quick pop-ups for volume, AirPods, charging, keep-awake and system health.
- **Ledge, the desktop companion** — a 3D character who walks on your windows, dances to your music, points at the notch when the assistant needs your OK, and dozes late at night. Three looks to pick from.
- **Modules** — find files, clipboard history, shelf, notes, timers, calendar & reminders, music, system stats, screen time, image converter, AI-usage heatmap, screenshots with annotation, camera mirror.
- **Private by design** — no account, no telemetry. Chats live in `~/Library/Application Support/OpenNotch`.

## Install

Download the latest `OpenNotch.dmg` from [Releases](../../releases), open it, and drag OpenNotch to Applications.

**First launch:** builds are not yet notarised by Apple, so macOS will say it can't verify the app.
Open **System Settings › Privacy & Security**, scroll down and click **Open Anyway**. You only do this once.

Requires macOS 14 Sonoma or later on a Mac with a notch (it also works on other Macs with a virtual notch).

## Build from source

```bash
git clone https://github.com/Laxman824/OpenNotch && cd OpenNotch
scripts/signing.sh          # once: a free local signing identity so permissions survive rebuilds
scripts/build.sh --install --open
```

Needs the Xcode Command Line Tools (`xcode-select --install`). Tests:

```bash
Checks/run.sh               # Swift logic checks + agent checks (no network)
node Desktop/test/sim.mjs   # desktop companion simulation

# One real agent turn against a provider (key from the environment, never stored):
OPENNOTCH_KEY=… App/.build/debug/OpenNotch --selftest groq        # or openai, anthropic, gemini, openrouter, ollama …
```

## Command line

```bash
cli/opennotch "what's on my calendar?"     # ask
git diff | cli/opennotch "review this"     # pipe context in
cli/opennotch -t 25   ·   cli/opennotch --awake 60   ·   cli/opennotch -m mirror
```

## Contributing

Issues and pull requests are welcome — see [CONTRIBUTING.md](CONTRIBUTING.md).

## License

[MIT](LICENSE). Bundles [three.js](https://threejs.org) (MIT).
