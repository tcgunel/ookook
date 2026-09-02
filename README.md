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
- [ ] MCP server, so Claude Code can see process status and logs (milestone 2)
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
