# TCC stall resilience

2026-11-08. An unanswered macOS privacy (TCC) prompt stalled `sandboxd` from 20:09 to
21:01, and every open of a protected file on the M5 waited for it. Opening a new tab
then hung cmux's main thread here:

`TerminalSurface.createSurface` → `createNativeRuntimeSurface` → `makeGhosttySurface`
→ `ghostty_surface_new` → `openat`

musa force-quit cmux and every agent in its terminals died. The evidence, including
cmux's own hang capture, is in
`theforest/local-ai-cat/scratch/2026-11-08/cmux-freeze/raw/`.

## What landed on `mochi/new-tab-file-access-guard`

1. **A new tab never opens a stalled directory on the main thread.**
   `TerminalWorkingDirectoryAccessGate` (CmuxTerminal) opens the working directory
   on a background queue and waits at most 750 ms.
   - On a timeout the surface starts in `$HOME`. A shell surface gets
     `cd '<dir>'` typed ahead of any other startup input, so the shell waits for
     macOS in its own process.
   - While the stuck open is still pending, later tabs fall back at once. One stall
     costs one 750 ms wait and parks one probe thread.
   - The surface posts `terminalSurfaceWorkingDirectoryAccessDeferred`.
     `WorkingDirectoryAccessDeferralNotice` turns that into a pane notification
     reading "Waiting for file access".
2. **The watchdog names the stall.** At capture time, `ThreadProgramCounterSymbolReader`
   (CmuxFoundation) reads the main thread's program counter from the watchdog queue,
   and `BlockedFileAccessCall` classifies the symbol.
   - The hang metadata gains a `mainThreadSymbol=` line.
   - If the symbol is a file-access call, the metadata also gains
     `tags=main-thread-in-openat` (or the matching syscall), and a user notification
     says "cmux is waiting on macOS file access — a privacy prompt may be open".

Known gaps:
- A surface with an explicit command (not a shell) starts in `$HOME` with no `cd`.
  Typing `cd` into, say, `htop` would be wrong.
- The pane notice shares one 60 s cooldown, so a burst of restored tabs gets one
  notice, not one per pane.

## Ghostty: proposal (not patched)

Pinned submodule `fd9b5b94`.

**`src/apprt/embedded.zig:961-999`.** `Surface.init` calls `openDirAbsolute` and
`stat` on `opts.working_directory` on the embedder's thread, which is cmux's main
thread. That is the only main-thread file access in surface creation. It validates
the path and then sets `config.working-directory`.

It can be removed safely **only together with the fallback below**:
- Set `.path = wd`, call `finalize`, and drop the open and stat.
- `termio/Exec.zig:982` already runs `access(proposed)` on the IO thread, and when
  that fails it sets `cwd = null`.
- The behaviour change: a bad path used to keep the configured default working
  directory. With the open gone, the path is set, the IO thread finds it bad, and
  `cwd = null` makes the child inherit the *process* cwd. For a Finder-launched cmux
  that is `/`, which is exactly what the cmux-mochi CLAUDE.md forbids.

**Fallback to `$HOME`, in two places:**

```zig
// termio/Exec.zig, the access() else-branch (IO thread):
} else |err| {
    log.warn("cannot access cwd, using home: {}", .{err});
    break :cwd home_dir orelse null; // resolved once via internal_os.home()
}

// Command.zig:211, in the forked child (getenv only reads environ; no locks):
if (self.cwd) |cwd| {
    if (posix.system.chdir(cwd) != 0) {
        if (posix.getenv("HOME")) |home| _ = posix.system.chdir(home);
    }
}
```

The `access()` and the child's `chdir` can still block on TCC, but only the IO
thread and the child wait, never the app.

**Why it is not patched here:**
- The cmux side already keeps stalled paths away from `ghostty_surface_new`.
- A Ghostty change needs a commit and a push to `mochiexists/ghostty` before the
  pointer bump. Pushing is the seat's call.
- It needs a GhosttyKit rebuild (zig 0.15.2 / SDK caveats in `FORK.md`).

It is about 15 lines, with a Zig test for the `chdir` fallback. Worth doing as
defence in depth on the next Ghostty bump.

## Next

The bigger fix, keeping agents alive when cmux dies, is in
[local-session-daemon.md](local-session-daemon.md).
