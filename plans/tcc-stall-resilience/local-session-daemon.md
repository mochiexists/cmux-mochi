# Local session daemon: design note (not built)

Goal: a crash, a hang or a Force Quit of cmux only detaches the window. Shells,
`claude`, `codex` and their subagents keep running, and on relaunch every tab
reattaches to its live session.

## The pieces that already exist

- **`daemon/remote` (cmuxd-remote, Go)** already has persistent PTY slots for `cmux ssh`:
  - `serve --stdio --persistent --slot <slot>` proxies to a per-slot daemon;
  - the daemon listens on an authenticated per-user Unix socket
    (`/tmp/cmuxd-remote-<uid>/`, 0600 token under `~/.cmux/daemon/<version>/<slot>/`);
  - it serves `pty.attach/write/resize/detach/close/list` with bounded scrollback;
  - it blocks SIGHUP so a PTY outlives its attachment
    (`persistent_pty_exec_darwin.go`).
- **`TerminalSurfaceIOMode.manualMirror`**
  (`TerminalSurface+RuntimeSurfaceCreation.swift:50-62`): "the embedder owns the
  PTY and terminal protocol while Ghostty mirrors output for rendering and
  encodes only user input". This is the in-process attach path.
- **`cmux ssh-session-attach`** already makes a local terminal whose startup
  command attaches to an existing daemon PTY. That is a working process-based
  attach path today.

## Steps

1. **Local mode for the daemon.**
   - Add `cmuxd-remote serve --local --slot local-<channel>`, with no SSH and no
     stdio proxy, listening on `~/Library/Application Support/cmux/<channel>/daemon.sock`
     (dir 0700) with the same token check.
   - `pty.attach` creates a PTY from an explicit `argv`, `cwd` and `env`. The env
     carries the per-surface `CMUX_*`, `PATH` shims and shell-integration variables
     cmux builds today.
   - Turn **off** idle-TTL reaping for local slots: an unattached session is the
     normal state after a crash. Reap only on an explicit `pty.close` or when the
     process exits.
2. **Run it as a per-user launchd agent.**
   - Register it with `SMAppService.agent(plistName:)` from inside the app bundle
     (`Contents/Library/LaunchAgents/`), one label per channel (stable, NIGHTLY,
     each dev tag), so channels never share sessions.
   - `KeepAlive` on crash only. The agent starts on demand, not at login, unless
     sessions exist.
3. **Attach tabs. v0 is process-based, v1 is in-process.**
   - **v0:** a local tab's Ghostty command becomes
     `cmuxd-remote attach --local --id <ptyID>`. Ghostty spawns that small client
     as usual (`exec` mode, no Ghostty change). A cmux crash kills only the client;
     the PTY and its process tree live on in the daemon.
   - **v1:** the surface uses `manualMirror` mode and talks to the socket directly.
     That saves the extra process, and cmux sees the bytes (iPhone mirroring,
     scrollback replay).
4. **Persist the mapping.**
   - The session snapshot stores `surfaceId → ptyID`.
   - On launch, cmux calls `pty.list`. Tabs whose `ptyID` is alive reattach with
     scrollback replay, then a resize nudge so full-screen TUIs (claude) redraw.
   - Live PTYs no tab claims go to a "detached sessions" list, never silently
     killed. Dead ones fall back to today's restore and agent-resume path.
5. **Close semantics.**
   - Closing a tab sends `pty.close`.
   - Quitting cmux normally asks once with "Keep sessions running?" and remembers
     the answer; the default is keep.
   - A crash or Force Quit always keeps the sessions.
6. **Versioning.**
   - The socket protocol carries a version.
   - A new app version never replaces a daemon that owns live sessions. The old
     daemon keeps serving its sessions and new tabs go to a new-version daemon;
     the old one exits when it has no sessions left.
7. **Tests.**
   - Go: local-slot lifecycle, no idle reap, and attach after the attacher is
     SIGKILLed.
   - Swift: the mapping and reattach planner, as pure types.
   - Dogfood with musa present: kill -9 a tagged dev build that is running a
     `claude` session, relaunch it, and check the session is intact.

## Risks

- **TCC "responsible process" becomes the daemon.** Today the shell's file
  accesses are attributed to cmux Mochi, which holds the Documents, Desktop and
  Downloads grants.
  - Children of a launchd agent are attributed to the agent's executable, so the
    first launch would raise a fresh round of privacy prompts against a new
    identity. That is the exact failure this work exists to survive.
  - Whether `SMAppService` plus `AssociatedBundleIdentifiers` makes the app the
    responsible process for its embedded agent must be **measured on a device with
    musa present** before building step 3.
  - If it does not, the agent needs its own stable signed identity, a one-time
    grant per channel, and the dev tags need care: each tag would prompt again.
- **Environment drift.** Shells spawned by the daemon do not inherit the app's
  environment, so everything `createNativeRuntimeSurface` puts in `env` must go
  over `pty.attach`, and stay in sync as that code changes.
- **Ghostty features that assume Ghostty spawned the shell.** These are the
  `/usr/bin/login` wrapping, shell-integration injection, OSC 7 cwd reporting and
  `wait-after-command`, and they must be reproduced in the daemon or the attach
  client.
- **Terminal state on reattach.** Replaying raw scrollback does not restore modes
  exactly (alt screen, mouse, bracketed paste). The daemon should keep a small VT
  state, or at least the last mode-set sequences, and replay them.
- **Orphans and resources.** A crash loop can pile up detached sessions, so the
  detached list needs a visible count and a "close all".
- **Security.**
  - The socket is a remote-control surface for every shell, so it needs: a 0700
    directory, a token, peer uid checked with `getpeereid`, and no TCP.
  - The `cmux` CLI socket path must stay stable across relaunches, or reattached
    shells lose `cmux notify` and the hooks.
- **The hang itself is not solved by this.** A main-thread hang still freezes the
  window. The daemon only makes Force Quit safe. The gate on this branch is what
  keeps new tabs from hanging.

## Size

| Step | Days |
|---|---|
| 1. Local daemon mode (Go) and tests | 1.5–2 |
| 2. launchd agent, SMAppService, per-channel labels | 1 |
| 3. v0 attach client as the tab command | 1–1.5 |
| 4. Snapshot mapping, `pty.list` reattach, detached list | 1.5 |
| 5–6. Close semantics, versioned daemons | 1 |
| TCC identity measurement, signing and notarizing the helper | 1 |
| Dogfood and fixes | 1–2 |
| **v0 total** | **about 8–10 days** |
| v1 in-process `manualMirror` attach | +2–3 |

Recommendation: measure the TCC identity first (half a day, with musa). Build only
if the daemon can inherit cmux Mochi's grants, or musa accepts a one-time grant per
channel.
