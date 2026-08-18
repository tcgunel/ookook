# Ookook - feature map

The plan for turning a personal tool into something sellable. Ordered by what
creates value, not by what is easy.

Competitive frame: Solo (soloterm.com) charges $99/yr, free tier capped at 4
projects / 20 processes, closed source, Mac + Windows. Anything below marked
**parity** is table stakes; **edge** is where we can be better rather than equal.

---

## v0.1 - shipped

The core loop works and is verified end to end.

| Feature | Notes |
|---|---|
| `ookook.yml` project config | Committed with the repo, discovered by upward search |
| Real pty terminal per process | SwiftTerm; scrollback survives switching |
| Start / stop / restart / autostart | Per process and all-at-once |
| Crash detection + exponential backoff restart | Capped at 30s |
| Login shell + real environment inheritance | Tooling behaves as in your own terminal |
| Clean teardown, no orphaned children | Verified |
| Grouped sidebar: agents / commands / terminals | Collapsible, with running counts |
| Live activity line per process | Last line of output, in the sidebar |
| **MCP server over HTTP** | `list_processes`, `get_process_output`, `start`/`stop`/`restart` |

Claude Code connects with one command and reports `✔ Connected`.

---

## v0.2 - daily-driver gaps

The things that will annoy you within a week of real use.

- [ ] **Persist per-process state** - remember which process was selected, and sidebar collapse state
- [ ] **Search in scrollback** (`⌘F`) - parity, and painful without
- [ ] **Clickable ports and URLs** in output - parity
- [ ] **Auto-detect the port** a process bound to, instead of declaring it by hand - **edge** (Solo makes you configure it)
- [ ] **Desktop notification on crash** - parity
- [ ] **App icon + proper About panel**
- [ ] **`⌘1..9`** to jump between processes
- [ ] **Copy/paste and font-size keybindings** in the terminal

## v0.3 - the agent story

This is the actual product. Solo's own pitch is "agents flying blind"; every item
here makes an agent more useful, and this is where a buyer's money goes.

- [ ] **`wait_for_port`** MCP tool - agents stop polling log lines to know a server is up - parity
- [ ] **Agent working/idle detection** - know when Claude Code is waiting on you - parity
- [ ] **Attention state in the sidebar** + one keystroke to jump to whoever needs you - parity
- [ ] **`send_input`** - let an agent answer a prompt in another process - parity
- [ ] **Shared todos / scratchpads / locks** across agents - parity (Solo's differentiator)
- [ ] **Structured crash reports over MCP** - "it died with exit 137 and these last 40 lines", pre-digested rather than raw log dump - **edge**
- [ ] **Log-diff since last check** - an agent asks "what changed since I last looked", instead of re-reading 500 lines - **edge**, and materially cheaper in tokens

## v0.4 - multi-project

- [ ] **Multiple projects in one window**, collapsible per project (Solo's top-level grouping)
- [ ] **Per-process CPU / memory** in the sidebar - parity
- [ ] **Orphan recovery** after a crash of the app itself - parity
- [ ] **Local process definitions** not committed to the repo - parity
- [ ] **Git worktree awareness** - shared state across checkouts - parity

## v0.5 - sellable

- [ ] **Developer ID cert + notarization** (not yet in the keychain - only App Store and Development certs exist)
- [ ] **Sparkle** for auto-updates
- [ ] **Licensing** - Lemon Squeezy or Paddle, offline grace period
- [ ] **Themes and font choices** - parity
- [ ] **Landing page + changelog**

---

## Positioning

**Not** the App Store. A sandboxed app cannot spawn arbitrary user binaries,
which is the whole program - SwiftTerm's own docs say to disable the sandbox
entirely. iTerm2, Warp, Ghostty and Solo are all direct-download for this
reason. Distribution is Developer ID + notarization + Sparkle.

Where we can genuinely beat Solo, rather than clone it:

1. **Native, not Tauri.** Solo leans on "not Electron"; we are a step further -
   real AppKit text rendering, no webview at all. Cheaper to make feel fast.
2. **Token-efficient agent tools.** Solo hands agents raw logs. Log-diffs,
   pre-digested crash reports and port detection make each agent turn cheaper
   and more accurate. That is a real, demonstrable advantage to sell on.
3. **Price.** Solo is $99/yr with a capped free tier. A one-time price, or a
   materially cheaper subscription with no project cap, is a straightforward
   wedge against an incumbent that has already set the anchor.

Honest risks:

- Solo is further along, has Windows, and Aaron Francis has a large audience.
  Beating it on features is unlikely; beating it on price and agent ergonomics
  for Claude Code specifically is plausible.
- Mac-only halves the market.
- Terminal emulators have a long tail of correctness bugs (mouse, wide chars,
  ligatures, reflow). SwiftTerm absorbs most of that, but not all of it.
