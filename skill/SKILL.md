---
name: porthole
description: Work on another Mac's screen, apps and audio. Use when a task needs a real display, windows, keyboard and mouse input, or sound — running and testing a desktop app, UI testing, checking that audio plays, anything GUI — and a remote Mac is paired with porthole. Also use when asked to "test it on the other Mac", "run it on the mini", or to look at what's on a remote screen.
---

# Porthole: a second Mac for visual work

Porthole lets you drive a paired Mac as if you were sitting at it: run commands, copy files, see and operate its windows, and hear what it plays. Your own machine stays free; the app under test runs over there.

## Find the remote

- MCP tools named `mcp__porthole-<host>__*` act on that host. If you have them, use them; they are the main interface.
- Otherwise use the `porthole` CLI from Bash. `porthole hosts` lists paired hosts; `-H <host>` picks one (it defaults to the only host).
- `remote_info` / `porthole info` says whether Desktop Tools is running there and whether Screen Recording is granted.

## The loop

1. **Ship the code.** `remote_push` a directory (it skips `.git`, `node_modules`, `.build`, `target`, `DerivedData`), or `remote_exec` a `git clone`/`git pull` there. Remote paths are relative to its home; use `~/porthole/work/<project>` unless told otherwise.
2. **Build there.** `remote_exec` with `cwd` set. It runs a zsh login shell, so Homebrew, cargo and bun are on PATH. Pass `timeout_seconds` for long builds.
3. **Launch.** Start GUI apps and servers with `detach: true` (or `open -a`, `open path/To.app`) so the call returns; read the log path it gives you with `remote_exec "tail -50 <log>"`.
4. **Look.** `remote_screenshot` for the whole screen. For anything you'll interact with, `desktop_windows` / `desktop_apps` then `desktop_inspect`, which gives a screenshot plus element IDs.
5. **Act.** `desktop_click`, `desktop_type`, `desktop_key`, etc. with the snapshot from `desktop_inspect`. Inspect again after every action; snapshots are single-use.
6. **Listen.** To check sound, call `remote_audio` (e.g. `seconds: 4`, optionally `app`) and trigger the sound in a parallel call, or record while it plays. Read `silent`, `peak_dbfs`, `sound_from`/`sound_to` and the `levels_dbfs` timeline. `pull_to` copies the WAV here.
7. **Bring back evidence.** `remote_pull` logs, screenshots or recordings that the user should see.
8. **Clean up.** Quit what you launched (`desktop_quit`, or `remote_exec "pkill -x AppName"`).

CLI equivalents: `porthole exec -- cmd`, `porthole exec --detach -- cmd`, `porthole push <local> <remote>`, `porthole pull <remote> <local>`, `porthole shot out.png`, `porthole audio --seconds 4 --app Music`.

## Rules

- Every `desktop_*` tool in a porthole server acts on the **remote** Mac. Paths those tools take or return (`save_path`) are on the remote; pull them to read them here.
- Don't run destructive commands there that you wouldn't run on the user's own machine; it is a real Mac someone owns.
- `CALLER_NOT_APPROVED` means Desktop Tools on the remote hasn't approved Porthole yet. `screencapture failed` / `cannot list shareable content` means Porthole lacks Screen Recording there. Both need the user at that Mac (or on Screen Sharing); tell them exactly which, and don't retry in a loop.
- If the host is unreachable, say so; check `tailscale status` here before guessing.
