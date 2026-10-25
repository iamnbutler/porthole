# Porthole

Let agents work on another Mac: run commands, move files, see and operate its windows, and hear its audio. It's the agent-facing half of [Beam](https://beam.win): instead of streaming windows to a person, it gives an agent on one Mac the screen, input and sound of another.

```
 this Mac (agent)                              other Mac (does the work)
 ┌──────────────────────────┐   tailnet      ┌──────────────────────────────────┐
 │ Claude Code              │   TCP :7878    │ Porthole.app  (LaunchAgent)      │
 │  └ porthole mcp <host>  ─┼──── token ────▶│  ├ mcp   → Desktop Tools MCP     │
 │     desktop_* (forwarded)│                │  ├ exec  → zsh -lc, process group │
 │     remote_*  (porthole) │                │  ├ put/get (files, dirs as tar)   │
 │  └ porthole CLI          │                │  ├ shot  → screencapture          │
 └──────────────────────────┘                │  └ audio → Core Audio process tap │
                                             └──────────────────────────────────┘
```

- **Desktop control** comes from [Desktop Tools](https://github.com/githubnext/desktop-tools): accessibility snapshots, screenshots and input. Porthole runs its MCP server on the remote Mac and pipes it over the connection, adding `remote_exec`, `remote_push`, `remote_pull`, `remote_screenshot`, `remote_audio` and `remote_info`.
- **Security:** the server only accepts loopback and Tailscale peers (100.64.0.0/10, fd7a:115c:a1e0::/48) unless started with `--any`, and every connection must present the 256-bit token from `~/.config/porthole/token`. Tailscale encrypts the traffic.
- **Audio:** `remote_audio` records all output or one process's through a Core Audio process tap (macOS 14.2+; it hears command-line tools, which ScreenCaptureKit misses), writes a WAV on the remote Mac, and returns peak level, when sound started and stopped, and a level per 0.1 s, so an agent can tell whether a sound played.

## Set up

On the agent's Mac:

```sh
./scripts/build-app.sh --install     # builds, signs and installs /Applications/Porthole.app
/Applications/Porthole.app/Contents/MacOS/porthole share
```

`share` prints a command. Run it on the other Mac:

```sh
curl -fsSL http://<this-mac-tailscale-ip>:7879/install | sh
```

That installs Porthole (and Desktop Tools, if missing), starts the server as a LaunchAgent, and pairs back: this Mac saves the host in `~/.config/porthole/hosts.json` and adds a `porthole-<host>` MCP server to Claude Code (user scope; `--mcp-scope none` to skip).

Then, at the other Mac, once:

1. In Desktop Tools' menu, grant Accessibility, Screen Recording and Keyboard input, and **Allow** Porthole when it asks.
2. Allow **Porthole** for Screen Recording (System Settings › Privacy & Security › Screen & System Audio Recording).

Give agents the skill: `ln -s "$PWD/skill" ~/.claude/skills/porthole`.

## CLI

```
porthole info  [-H host]
porthole exec  [-H host] [--cwd dir] [--timeout s] [--detach] -- command…
porthole push  [-H host] <local> <remote>
porthole pull  [-H host] <remote> <local>
porthole shot  [-H host] [--display n] [out.png]
porthole audio [-H host] [--seconds n] [--app name] [--pull path]
porthole mcp   [host]
porthole pair <name> <address[:port]> <token>   # manual pairing
porthole hosts [rm <name>]
```

## Not (yet) in here, compared with Beam

Per-window streaming to a person, ⌘Tab-able remote windows, clipboard sync and share links. For a person watching along, macOS Screen Sharing over Tailscale works today (`open vnc://<host>`).

## Develop

`swift test` runs the server in-process and exercises exec, timeouts, detach, file and directory transfer and auth against it.
