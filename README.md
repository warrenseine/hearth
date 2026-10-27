<p align="center">
  <img src="docs/logo.png" width="128" height="128" alt="Hearth logo">
</p>

# Hearth

A lightweight, native macOS GUI for [process-compose](https://f1bonacc1.github.io/process-compose/):
the parts of its TUI you reach for every day, in a menu bar + a normal window.

Hearth has no daemon of its own. It talks to process-compose's REST + WebSocket API, starts
projects as detached headless servers, and finds the ones you started from a terminal.

![Hearth main window: process table with health and live logs](docs/screenshot.png)

## Install

```bash
brew install --cask warrenseine/hearth/hearth
```

This also installs `process-compose` from its author's tap (`f1bonacc1/tap`) if needed. The app
is unsigned (no Apple Developer ID yet), so macOS blocks the first launch. Approve it once in
**System Settings → Privacy & Security → Open Anyway**, or run
`xattr -dr com.apple.quarantine /Applications/Hearth.app`.

## Requirements

- macOS 26+ on Apple silicon
- [`process-compose`](https://f1bonacc1.github.io/process-compose/installation/) installed
  (Homebrew, `~/.local/bin`, mise, Nix or `~/go/bin` are found automatically; otherwise set its
  path in Settings)
- Xcode 26+ (Swift 6.2 toolchain) to build from source
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`) to generate the Xcode project

## Building

```bash
make build   # regenerates Hearth.xcodeproj and builds Debug
make run     # build + launch
make test    # run the HearthKit test suite (no Xcode project needed)
make icon    # re-render the app icon into the asset catalog
```

`Hearth.xcodeproj` is generated from [`project.yml`](project.yml) and is not checked in.

## Layout

- **`HearthKit/`**: a plain SwiftPM package with all the logic. It holds the HTTP/1.1 + WebSocket
  client, typed API models, server discovery, the launcher, the project registry and the
  observable store. Tests decode fixtures captured from a real process-compose v1.122. When
  `process-compose` is installed, a live suite also drives a real server over a unix socket and
  over TCP with a token.
- **`Hearth/`**: the SwiftUI app target (menu bar, main window, all views).
- **`examples/`**: a sample project (a web server with a readiness probe, a worker, a crashing
  process) for trying Hearth by hand.

## What it does (v1)

- **Menu bar**: every project and its running/total count. Up/Down per project, and
  start/stop/restart per process. Clickable port shortcuts.
- **Projects**: add a folder with a `process-compose.yaml`. Optional extra config files, env
  files and namespaces. **Up** runs `process-compose up --detached --tui=false` on a socket Hearth
  owns, so the project keeps running after Hearth quits and is re-attached on next launch.
  **Down**, **Reload config** and **Open TUI in Terminal** (`process-compose attach`) are there too.
- **Discovery**: any process-compose server already running on this machine shows up as
  *attached*, whether over a unix socket (`-U`/`-u`) or TCP (`-p`). If it was started from a
  registered project's folder, it's matched to that project.
- **Processes**: status, readiness health, PID, restarts, exit code, age, CPU, memory and
  listening ports, with click-to-open-in-browser. Sortable and filterable. Start/stop/restart.
- **Process detail**: live logs (follow, wrap, search, copy; one process or all of them
  interleaved), the resolved config, and timings.
- **Token-protected servers**: a token in the server's own environment (`PC_API_TOKEN`) or token
  file is picked up automatically. Otherwise Hearth asks for it and keeps it in the Keychain.

Deliberately left out for now: dependency graph, scale/signal/send-keys, namespace actions,
crash notifications.

## How it talks to process-compose

- **Transport.** Everything goes over process-compose's own API, through one `NWConnection`
  code path for both unix sockets and TCP. HTTP/1.1 and WebSocket framing are done by hand in
  `HearthKit/Sources/HearthKit/API/Transport.swift`, because `URLSession` can't reach a unix socket.
- **Process state.** It is pushed by `/process/states/ws`. `/processes` is polled every 2s while
  a window is visible (10s in the background) for the CPU, memory and age figures the socket
  doesn't push. Ports refresh every 10s.
- **Logs.** They stream from `/process/logs/ws`.
- **Discovery.** It reads each `process-compose` process's exact argv, environment and cwd via
  libproc and `sysctl(KERN_PROCARGS2)`, not by parsing `ps`, since paths with spaces can't be
  split back out of `ps` output. It applies process-compose's own flag/env precedence to work
  out where each server listens.
- **Launching.** Projects Hearth launches get the user's login-shell environment, so `node`,
  `python3`, mise/nvm shims and so on resolve as they would in a terminal. Their sockets live in
  `$TMPDIR/hearth/<id>.sock`, short enough for the 104-byte socket path limit. Their
  process-compose logs go to `~/Library/Logs/Hearth/<id>.log`.

## Security notes

- Hearth reads API tokens from the environment of process-compose servers *you* own, the same
  way process-compose's own CLI would. Pasted tokens go to the login Keychain. Tokens are never
  logged.
- The app is unsigned and not sandboxed, since it needs to spawn `process-compose` and read other
  processes' arguments.

## License

MIT — see [LICENSE](LICENSE).
