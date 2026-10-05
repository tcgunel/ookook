# Ookook

A native macOS workspace for running your dev stack and your AI coding agents in
one window, instead of a dozen terminal tabs.

Declare your processes in `ookook.yml`, commit it, and Ookook starts them,
watches them, and restarts the ones that fall over.

## Status

Milestone 1 (core supervisor) is working:

- [x] `ookook.yml` config, discovered by searching upward from the project directory
- [x] One real pty-backed terminal per process, with full scrollback preserved
      across sidebar switches
- [x] Start / stop / restart, autostart, crash detection with exponential backoff
- [x] Children inherit your real environment and run under your login shell
- [x] No orphaned processes when the app quits
- [x] MCP server, so Claude Code, Codex and opencode can see process status and
      logs (milestone 2)
- [ ] Log search, split panes, per-process env, icon, updater (milestone 3)

## Build

No Xcode project - it is plain SwiftPM, like a CLI tool.

```bash
./build.sh                                  # produces ./Ookook.app
open -a "$PWD/Ookook.app" --args ~/myproject
```

`swift build && .build/debug/Ookook ~/myproject` works too, for fast iteration.

## Configuration

`ookook.yml`, in your project root:

```yaml
name: My Project
processes:
  - name: dev
    command: npm run dev
    autostart: true
    autorestart: true      # respawn on non-zero exit, with backoff

  - name: claude
    command: claude
    autostart: false

  - name: codex
    command: codex
    type: agent
    autostart: false

  - name: opencode
    command: opencode
    type: agent
    autostart: false

  - name: api
    command: php artisan serve
    cwd: ./backend         # relative to this file, or absolute

  - name: shell
    command: exec $SHELL -i -l
```

Every command runs through your login shell (`$SHELL -l -c`), so `nvm`, `asdf`,
`pyenv` and friends resolve exactly as they do in your own terminal.

Note the `-i` in the `shell` example: a non-interactive shell exits immediately
even on a pty, so an interactive shell needs it explicitly.

## Agents

Give a process `type: agent` and Ookook recognises the provider from the
command - `claude`, `codex` or `opencode`. Agents get a working indicator in
the sidebar (Claude Code and opencode animate their own spinner, everything
else a breathing dot) and a Resume menu with the project's recent sessions:
`claude --resume`, `codex resume`, `opencode --session`. opencode's session
history is read read-only from its own SQLite database.

Ookook also starts agents unattended by default, appending each provider's own
flag: `--dangerously-skip-permissions` for Claude Code, `--yolo` for Codex and
`--auto` for opencode. Turn any of them off under Settings › Ookook.

Every agent can connect to Ookook's MCP server; the copy button in the sidebar
footer has the exact command for whichever one you use.

## Distribution note

Ookook **cannot ship on the Mac App Store**. A sandboxed app is not permitted to
spawn arbitrary user binaries, which is the entire point of this program - and
SwiftTerm's own documentation says the same. Every serious terminal (iTerm2,
Warp, Ghostty, Solo) is direct-download for this reason.

The distribution path is therefore Developer ID signing + notarization + Sparkle
for updates. That needs a **Developer ID Application** certificate, which is not
yet in this keychain (only App Store and Development certs are).

## Built on

- [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm) - terminal emulator and pty handling
- [Yams](https://github.com/jpsim/Yams) - YAML parsing

## Tickets (WhatsApp → DeepSeek → GitHub Issues)

Ookook can read a local WhatsApp client's message database - the official
desktop app, ZapFast, or whichever one is actually current - classify new
messages from chosen coworkers with DeepSeek, and file them as GitHub issues
on a label-based board: `triage` (needs your approval) → `todo` → `in-progress`
→ closed. Follow-ups and "fixed it" messages in chat land as comments on the
matching issue. Everything is redacted before it leaves the machine.

The message source is per project: **Automatic** reads from whichever client
has the fresher database (ZapFast wins ties, since it receives the same
conversations), falling back per chat when one client has not synced a
conversation yet. Pin WhatsApp or ZapFast in Settings › Tickets when the guess
needs a correction. The two clients are independent companions of the same
phone, so either database holds the same incoming messages while linked; the
auto mode exists so uninstalling one of them never strands the pipeline.

The official app's Core Data store needs **Full Disk Access**; the pane has a
button for it. ZapFast 0.13+ stores its archive as an encrypted SQLCipher
database and keeps the key in the login keychain: the first read shows one
Keychain prompt for Ookook (choose Always Allow, like any other signed app).
Full Disk Access is not needed for ZapFast. The settings header shows the
readability of both clients and a button to re-check.

Configure the rest per project in Settings › Tickets: the chats to read, the
repos (with local clones for a file map), a DeepSeek key (Keychain; a shared
key is the fallback), and options such as auto-approving confident bug/feature
tickets, ignoring types, active hours, screenshot OCR and voice/video
transcription.

Customer voice notes and the audio track of videos are transcribed on-device
with Whisper, so the model only ever sees text (DeepSeek has no audio input,
and Apple's speech models have no Turkish). The model is a one-time download
from Hugging Face, chosen in the same pane; transcripts are cached per message,
so media WhatsApp later purges keeps its text.

Screenshots, videos and documents can also be attached to the tickets they came
from. This is off by default, and the reason is worth stating plainly: the
redactor masks secrets in the OCR *text*, but it cannot touch the *pixels*, and
these chats carry panel credentials inside screenshots. With it on, the file is
uploaded as-is to an `ookook-attachments` branch in the ticket's repo and linked
from the issue, which makes it readable by everyone with access to that repo —
including the rest of the org. Per-post and per-file caps are in the same pane.
Files WhatsApp has already purged from disk are skipped and logged.

Follow-up comments carry their media too, not just the ticket body: a
resolution or a status nudge often arrives with the screenshot that prompted
it, sometimes days after the original report. Links are resolved against the
repo that actually holds the issue, so a follow-up on a ticket in `crm` does
not drop its images into the project's first repo. A message cited by both a
new ticket and a later follow-up is committed once and linked from both.

The sidebar shows a Tickets group under each enabled project. Hover a row for
approve/close, double-click to open on GitHub. Claude Code gets three MCP
tools: `list_tickets`, `claim_ticket` (moves to in-progress, returns body and
comments and a `ticket/N-slug` branch name) and `finish_ticket` (comment, then
close / leave for the PR / send back to triage).

Headless checks, using the same settings as the app:

```bash
./Ookook.app/Contents/MacOS/Ookook tickets list-chats [--source auto|whatsapp|zapfast]
./Ookook.app/Contents/MacOS/Ookook tickets backtest --project /path/to/project --from 2026-04-20 --to 2026-04-25
./Ookook.app/Contents/MacOS/Ookook tickets redact-test --project /path/to/project --hours 24
```

`--source` pins the client for that run (the default follows the project's
setting), and `list-chats` prints which client each row came from.
