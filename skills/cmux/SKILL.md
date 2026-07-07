---
name: cmux
description: End-user control of cmux topology and routing (windows, workspaces, panes/surfaces, focus, moves, reorder, identify, trigger flash). Use when automation needs deterministic placement and navigation in a multi-pane cmux layout.
---

# cmux Core Control

Use this skill to control non-browser cmux topology and routing.

## Core Concepts

- Window: top-level macOS cmux window.
- Workspace: tab-like group within a window.
- Pane: split container in a workspace.
- Surface: a tab within a pane (terminal or browser panel).

## Fast Start

```bash
# identify current caller context
cmux identify --json

# list topology
cmux list-windows
cmux list-workspaces
cmux list-panes
cmux list-pane-surfaces --pane pane:1

# create/focus/move
cmux new-workspace
cmux new-split right --panel pane:1
cmux move-surface --surface surface:7 --pane pane:2 --focus true
cmux split-off --surface surface:7 right
cmux reorder-surface --surface surface:7 --before surface:3

# attention cue
cmux trigger-flash --surface surface:7
```

If `CMUX_SURFACE_ID` or `CMUX_WORKSPACE_ID` is set, the process is already running inside cmux. Treat those env vars as the caller anchor, not the visually focused tab. `cmux identify --json` should be the first command an agent runs before opening, closing, moving, or sending to panes. Newer builds also provide `cmux whoami --json` as an alias.

For cross-pane work, pass explicit `--workspace` and `--surface` values. For destructive commands such as close, move, clear, and focus, do not rely on focus fallback.

To create a native Codex tab in the current workspace:

```bash
cmux new-surface --type agent-session --provider codex --workspace "${CMUX_WORKSPACE_ID:-}" --focus false
```

To capture one image of the whole visible workspace (all panes plus window chrome, with a per-pane rect map in the JSON payload):

```bash
cmux capture-workspace --workspace "${CMUX_WORKSPACE_ID:-}" --out /tmp/workspace.png
```

Use raw `cmux rpc` only when the socket method and params are already known. Prefer named CLI commands for agent workflows because raw RPC currently has less discoverable schema and weaker guardrails around wrong parameter names.

## Settings and Docs

Use `cmux docs settings` before changing cmux-owned settings. It prints the docs URL, schema URL, raw GitHub resources, cmux.json paths, and reload command.

```bash
cmux docs settings
cmux settings path
```

cmux-owned settings live in `~/.config/cmux/cmux.json`. Legacy `~/.config/cmux/settings.json` and `~/Library/Application Support/com.cmux-mochi/settings.json` files are read only as fallback for missing keys. Before editing, copy any existing `cmux.json` file to a timestamped `.bak` next to it so the user can revert. Edit the user file, then reload:

```bash
cmux reload-config
```

`cmux reload-config` reloads BOTH `cmux.json` and Ghostty config (`~/.config/ghostty/config`) and refreshes terminals in place. No app restart needed.

Use cmux settings for app behavior, sidebar, notifications, browser behavior, automation, workspace colors, and cmux-owned shortcuts. Terminal rendering settings such as font, cursor style, theme, scrollback, background transparency (`background-opacity`), and blur (`background-blur`) belong in Ghostty config at `~/.config/ghostty/config`.

Open the UI when useful:

```bash
cmux settings
cmux settings cmux-json
cmux settings shortcuts
```

## Handle Model

- Default output uses short refs: `window:N`, `workspace:N`, `pane:N`, `surface:N`.
- UUIDs are still accepted as inputs.
- Request UUID output only when needed: `--id-format uuids|both`.

## Deep-Dive References

| Reference | When to Use |
|-----------|-------------|
| [references/handles-and-identify.md](references/handles-and-identify.md) | Handle syntax, self-identify, caller targeting |
| [references/windows-workspaces.md](references/windows-workspaces.md) | Window/workspace lifecycle and reorder/move |
| [references/panes-surfaces.md](references/panes-surfaces.md) | Splits, surfaces, move/reorder, focus routing |
| [references/trigger-flash-and-health.md](references/trigger-flash-and-health.md) | Flash cue and surface health checks |
| [../cmux-mochi-conductor/SKILL.md](../cmux-mochi-conductor/SKILL.md) | Drive visible Codex/Claude worker panes and reconcile agent session IDs |
| [../cmux-workspace/SKILL.md](../cmux-workspace/SKILL.md) | Current caller workspace rules and non-disruptive automation |
| [../cmux-settings/SKILL.md](../cmux-settings/SKILL.md) | Safe cmux.json settings edits and validation |
| [../cmux-browser/SKILL.md](../cmux-browser/SKILL.md) | Browser automation on surface-backed webviews |
| [../cmux-markdown/SKILL.md](../cmux-markdown/SKILL.md) | Markdown viewer panel with live file watching |
