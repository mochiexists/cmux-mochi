# Agent Orchestration

cmux should make agent work feel like a visible swarm: one commander coordinates workers, every worker remains visible and interruptible, and automation talks to structured session state whenever possible.

## Preferred Model

Use one provider session with two clients:

- a visible cmux pane/surface for the user
- a conductor path that submits prompts, reads transcript/status, and subscribes to events

Terminal typing and screen reading are compatibility fallbacks. They are acceptable for terminal-only agents, but they should not be the primary design for Codex-native work.

## Agent Arrival

An agent that starts inside a cmux terminal should first discover where it is:

```bash
cmux whoami --json
cmux tree --all --id-format both
```

`whoami` is an alias for `identify`. It reports the caller workspace/surface from `CMUX_WORKSPACE_ID` and `CMUX_SURFACE_ID` when those env vars are present. That caller context wins over the visually focused workspace because the user may be watching a different pane or app.

Use explicit `--workspace` and `--surface` flags for cross-pane work, especially when closing, moving, focusing, clearing, or sending input. Avoid raw `cmux rpc` for topology mutations unless the method schema is known; named CLI commands provide safer defaults and better help.

## Codex

For new Codex workers, prefer a native agent-session surface:

```bash
cmux new-surface --type agent-session --provider codex --workspace "$CMUX_WORKSPACE_ID" --focus false
```

This path launches `codex app-server --listen stdio://` and submits turns through Codex app-server JSON-RPC from the native cmux surface. It is the right foundation for structured commander control.

Current limitation: the external CLI/socket surface cannot yet submit to or read from that same native agent-session directly. Until that lands, use the visible composer for native Codex surfaces, or use a terminal Codex pane when a conductor must submit autonomously today.

Terminal fallback:

```bash
cmux send --surface "$TARGET_SURFACE" --enter "Review the current diff and report blocking issues only."
cmux read-screen --surface "$TARGET_SURFACE" --scrollback --lines 200
```

For visual state across a whole workspace, `cmux capture-workspace` returns one composited image of every visible pane plus the tab bar, with a per-pane rect map in the JSON payload. The left sidebar is excluded by default (`--sidebar include` to keep it). It never changes focus; the workspace must already be selected in its window:

```bash
cmux capture-workspace --workspace "$CMUX_WORKSPACE_ID" --out /tmp/workspace.png
```

## Claude Code

Claude Code is currently best treated as a visible terminal pane with cmux wrapper/hooks:

```bash
cmux send --surface "$TARGET_SURFACE" --enter "ccy"
```

Use hooks for session mapping, restore, Feed, notifications, and turn completion signals:

```bash
cmux events --category agent --name agent.hook.Stop --reconnect
cmux read-screen --surface "$TARGET_SURFACE" --scrollback --lines 200
```

Claude is a good worker when you want Claude-specific behavior, Claude hooks, or a second opinion in its native TUI. Codex-native surfaces are a better worker when you want structured app-server control.

## Commands To Add

The missing commander API should be an `agent` command family:

```bash
cmux agent whoami --json
cmux agent list --json
cmux agent submit --surface "$SURFACE" --text "Prompt text" --json
cmux agent read --surface "$SURFACE" --json
cmux agent events --surface "$SURFACE" --json
cmux agent stop --surface "$SURFACE"
```

Expected behavior:

- `whoami`: report caller workspace, pane, surface, provider, cmux session id, provider thread/session id, cwd, and role labels.
- `list`: report visible and restorable agent sessions with workspace/pane/surface bindings.
- `submit`: use native provider submission for app-server sessions; terminal fallback only for terminal-backed agents.
- `read`: return structured transcript, activity rows, status, permission state, and recent messages.
- `events`: stream lifecycle, output, activity, approval, and turn-complete events without changing focus.
- `stop`: stop the provider process/session without closing panes unless explicitly requested.

Additional CLI hardening to make agent control boring:

- Raw `rpc` should reject unknown params and expose per-method schemas.
- Destructive socket methods should fail when no explicit target resolves, instead of falling back to focus.
- Agent launchers such as `codex-teams`, `claude-teams`, and `omx` should grow `--new-tab`, `--workspace`, and initial `--prompt`/`--goal` placement flags.
- `new-tab` should be a discoverable alias for `new-surface`.
- `read-screen` should gain a structured read path for native `agent-session` surfaces rather than requiring screenshot or WebView scraping.

## Saved Swarm Scenes

Scenes should sit above the `agent` command family:

```bash
cmux scene save "review-swarm"
cmux scene open "review-swarm" --cwd "$PWD"
```

A scene should record layout, roles, provider choice, cwd, initial prompt templates, and restore policy. It should not record secret prompt text or transient approvals.

## Telephone Loop Demo

For a simple visible swarm demo, create a ring of panes and have each agent pass a baton to the next pane:

```bash
cmux send --surface "$SURFACE_A" --enter "BATON from COMMANDER cycle 1/5: The release train left at midnight carrying frosted glass, safer agents, and one confused build timeout."
```

Each worker receives a short role prompt telling it its label, next surface, cycle limit, and rule: transform the message slightly, then pass it with `cmux send --surface "$NEXT_SURFACE" "BATON ..."` followed by `cmux send-key --surface "$NEXT_SURFACE" enter` until the final cycle. This makes a good test scene because the user can watch every hop and the message drift is visible.

The conductor skill includes this as `skills/cmux-mochi-conductor/templates/telephone-loop.md`.

## Decision Guide

Use Codex native agent-session surfaces when:

- the commander needs structured turn status, transcript, or activity
- the user wants a visible but programmatically controlled worker
- future `cmux agent submit/read/events` integration matters

Use Claude terminal panes when:

- the user explicitly wants Claude Code
- Claude hooks/Feed behavior are part of the workflow
- a visible TUI second opinion is more important than structured app-server control

Use terminal fallback when:

- the agent has no cmux provider bridge
- the conductor must submit today and the target is not a native agent-session surface
- the task is short enough that `send`, `send-key`, and `read-screen` are sufficient
