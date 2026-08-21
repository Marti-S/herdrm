<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset=".github/assets/herdrm-banner.png" />
    <source media="(prefers-color-scheme: light)" srcset=".github/assets/herdrm-banner-light.png" />
    <img src=".github/assets/herdrm-banner.png" alt="herdrm — every coding agent, every machine, one native terminal" />
  </picture>
</p>

<p align="center">
  The native macOS console for <a href="https://herdr.dev">herdr</a> — see Claude Code, Codex,
  Gemini, Grok and OpenCode across your Mac and every SSH box you own, and jump into any one
  of them at full-TUI fidelity.
</p>

<p align="center">
  <a href="https://github.com/missuo/herdrm/releases/latest"><img src="https://img.shields.io/github/v/release/missuo/herdrm" alt="Latest release" /></a>
  <a href="#-requirements"><img src="https://img.shields.io/badge/macOS-14%2B-brightgreen" alt="macOS 14+" /></a>
  <a href="https://github.com/missuo/herdrm/releases"><img src="https://img.shields.io/github/downloads/missuo/herdrm/total" alt="Downloads" /></a>
  <a href="#-status"><img src="https://img.shields.io/badge/status-early--stage-f59e0b" alt="Status: early stage" /></a>
  <a href="#-contributing"><img src="https://img.shields.io/badge/PRs-welcome-brightgreen" alt="PRs welcome" /></a>
</p>

<p align="center">
  <a href="#-what-it-does">What it does</a> ·
  <a href="#-why-herdrm">Why herdrm?</a> ·
  <a href="#-install">Install</a> ·
  <a href="#-quick-start">Quick Start</a> ·
  <a href="#-architecture">Architecture</a>
</p>

---

<p align="center">
  <img src=".github/assets/screenshot.png" alt="herdrm — device switcher and a live claude terminal" />
</p>

## ✨ What it does

[herdr](https://herdr.dev) is the runtime your coding agents live on — a background server that
owns their terminals and knows which one is working, blocked, or done. **herdrm** is a native
macOS window on top of it, and it's grown well past "attach to a terminal":

| | |
|---|---|
| 🖥️ **Every device** | Local + remote over SSH — keys, Tailscale, or a Keychain password — with auto-reconnect |
| 🧭 **Live status** | Spaces & Agents sorted by urgency: blocked → done → working → idle |
| ⌨️ **Real terminal** | Full PTY attach, not a chat wrapper — native selection, legible fonts, resilient sessions |
| 📎 **Paste anything** | Files and images land straight in the agent's pane, locally or over SSH |
| 🔔 **Notifications** | A system alert the moment an agent needs you — click it to jump right there |
| 🔍 **⌘K search** | Every agent, on every device, one keystroke away |

<details>
<summary><strong>See the full feature list</strong></summary>

### Every machine, one sidebar
- **All your devices, in parallel** — remote sockets forwarded over `ssh -L`, each on its own
  reconnect loop (1s → 30s backoff). The sidebar aggregates every device with a tinted OS badge;
  the bottom-left switcher filters by device.
- **Flexible SSH targets** — `user@host`, `user@host:port`, `ssh://` URIs, and `~/.ssh/config`
  aliases. Auth falls back OpenSSH keys/agent → **Tailscale SSH** (1.98.0+) → an in-app password
  prompt stored in the **macOS login Keychain**, never in a file.
- **Diagnosable failures** — "herdr isn't running on `<host>`", a misconfigured
  `AllowStreamLocalForwarding`, or *why* a disconnected device is unreachable — never a bare
  "not connected".

### Spaces & Agents, always current
- **Spaces & Agents sidebar** — every workspace and agent (claude, codex, gemini, grok,
  opencode, …), same canonical order the ⌘K palette uses.
- **New Agent / New Space** — the picker only lists CLIs actually installed on that device
  (NVM and user-level installs included), and enables each agent's bypass-permissions flag by
  default. **⌘N** for a new agent, **⇧⌘N** for a new space. New Space includes an inline
  directory browser that works over SSH.
- Spaces rename straight from the sidebar's context menu.

### A real terminal, not a chat wrapper
- **Live terminal** — attaches directly to the agent's PTY (`herdr agent attach`); grabs
  keyboard focus the moment you jump in from ⌘K, the sidebar, or a notification.
- **Native text selection** — drag to select, no Shift needed; right-click for Copy/Paste/Select
  All plus link actions (⌘-click opens a URL).
- **Legibility controls** — Thin strokes, font Weight, and Line spacing settings.
- **Shift+Enter** inserts a line break instead of submitting; colors adapt correctly in Light
  mode instead of washing out.
- **Resilient sessions** — a dropped connection or a takeover shows a Reconnect button instead
  of freezing on the last frame; mixed-version `herdr` binaries no longer break attach.

### Files, search, and staying in the loop
- **Paste files and images** into Claude Code, Codex, or Copilot. Local pastes forward as
  Ctrl+V; remote pastes stream over SSH into a self-pruning cache (7-day retention, 50 MB cap).
- **Search** — ⌘K across every device, ordered by urgency, scrolling to follow your selection.
- **Notifications** — a sound and a system alert when any agent finishes or needs input;
  clicking jumps straight to it. Agents you're already watching stay quiet.

### Built like a native Mac app
- **Universal binary** — Apple Silicon and Intel, one download.
- **Light & dark**, auto-updates via [Sparkle](https://sparkle-project.org), signed and
  notarized.
- **HerdrKit** — the socket-RPC/SSH/device layer ships as its own, independently testable Swift
  package (`Packages/HerdrKit`).

</details>

## 🤔 Why herdrm?

If you run more than one coding agent, or one agent on more than one machine, you know the
friction: a grid of terminal tabs with no shared sense of who's blocked, a chat UI that can't
show you the actual TUI, and no way to know an agent finished until you tab back over.

- **One console, every machine.** Laptop, dev box, home server — all rows in the same sidebar.
- **The real terminal, not a summary of it.** herdrm attaches to the agent's actual PTY.
- **You stop polling.** Status lives in the sidebar and in notifications, not in your head.
- **It gets out of the way.** ⌘K, ⌘N, paste-to-attach — no new mental model to learn.

## 📋 Requirements

- macOS 14+
- [herdr](https://herdr.dev) installed locally (herdrm starts it if it isn't running) and on
  your remote machines
- For remote devices: OpenSSH access, Tailscale SSH (1.98.0+), or a Keychain-stored password

## 📦 Install

**Homebrew**
```sh
brew install owo-network/brew/herdrm
```

**Manual** — download `herdrm-x.y.z.zip` from [Releases](https://github.com/missuo/herdrm/releases),
unzip, drag `herdrm.app` into `/Applications`. Either way it self-updates from then on — **HerdrM
→ Check for Updates…**, or **HerdrM → About HerdrM** for the version you're running.

## ⚡ Quick Start

```text
1. Launch herdrm            → no local herdr running? herdrm starts it for you
2. Add a device (optional)  → you@dev-box · you@dev-box:2222 · a Tailscale machine
3. ⌘N                       → pick a device + a CLI, you're attached to its live terminal
4. ⌘K                       → jump to any agent on any device, any time
```

## 🏗️ Architecture

```mermaid
flowchart LR
    A(["🖥️ herdr<br/>background server, owns the PTYs"]) -->|"Unix-socket RPC +<br/>herdr agent attach"| B[["Packages/HerdrKit<br/>RPC client · SSH tunnel · device store"]]
    B -->|SwiftUI bindings| C(["Sources/HerdrM<br/>sidebar · terminal · search · notifications"])
    style A fill:#161b22,stroke:#E2795B,color:#e6edf3
    style B fill:#1f2630,stroke:#3B82F6,color:#e6edf3
    style C fill:#161b22,stroke:#2FA35F,color:#e6edf3
```

- **[herdr](https://herdr.dev)** — the daemon: owns every agent's PTY, persists spaces, answers
  over a local Unix socket.
- **`Packages/HerdrKit`** — transport and domain layer, UI-independent and unit-tested on its
  own (`make kit-test`).
- **`Sources/HerdrM`** — the SwiftUI shell built on
  [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm).

## 🔨 Build from source

```sh
brew install xcodegen
make build   # xcodegen + xcodebuild → build/Build/Products/Debug/herdrm.app
make run
make kit-test  # HerdrKit integration tests (needs a running local herdr)
```

## 🤝 Contributing

Early-stage software, PRs genuinely welcome — small and single-purpose lands fastest.

- **Bug?** [Open an issue](https://github.com/missuo/herdrm/issues/new) with your macOS
  version, `herdr --version`, and repro steps.
- **Feature idea?** Open an issue first for anything beyond a small PR.
- **Sending a PR:** `make build` + `make kit-test` locally (no CI gate yet — this is the bar),
  plus a line under `## [Unreleased]` in `CHANGELOG.md` (release automation requires it).

## 🙏 Credits

- [herdr](https://herdr.dev) — the agent runtime this app is a console for.
- [Heeler](https://github.com/ZingerLittleBee/Heeler) — iOS herdr client; domain model and
  transport patterns.
- [waku](https://github.com/egoist/waku) — sidebar design reference.
- [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm) — terminal emulation.
- [Sparkle](https://sparkle-project.org) — auto-updates.
- [Lobe Icons](https://github.com/lobehub/lobe-icons) / [Simple Icons](https://simpleicons.org) — brand icons.

## <a name="-status"></a>⚠️ Status

**Early stage**, without full test coverage — expect bugs. Issues and PRs are very welcome.

## ⭐ Star History

<p align="center">
  <a href="https://star-history.com/#missuo/herdrm&Date">
    <picture>
      <source media="(prefers-color-scheme: dark)" srcset="https://api.star-history.com/svg?repos=missuo/herdrm&type=Date&theme=dark" />
      <source media="(prefers-color-scheme: light)" srcset="https://api.star-history.com/svg?repos=missuo/herdrm&type=Date" />
      <img src="https://api.star-history.com/svg?repos=missuo/herdrm&type=Date" width="600" alt="Star History Chart for missuo/herdrm" />
    </picture>
  </a>
</p>
