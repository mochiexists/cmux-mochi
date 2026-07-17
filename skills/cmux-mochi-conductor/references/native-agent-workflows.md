# Native Agent Workflows

Use this reference to choose between Codex-native agent surfaces, Claude terminal panes, and generic terminal control.

## Preferred Shape

The ideal conductor flow has one provider session and two clients:

- the visible cmux surface the user can interact with
- the conductor using structured commands to submit prompts, read state, and subscribe to events

Do not make pane scraping the primary design when a provider API exists. Use terminal keystrokes only as the compatibility path for agents that do not expose a structured session API through cmux.

## Codex

Prefer a native cmux agent-session surface for new Codex workers:

```bash
cmux new-surface --type agent-session --provider codex --workspace "${CMUX_WORKSPACE_ID:-}" --focus false
```

That surface launches `codex app-server --listen stdio://` and the UI submits turns programmatically through Codex app-server JSON-RPC. It is better than driving the Codex TUI with keystrokes because it has structured activity, turn completion, and permission events inside the app process.

Current limitation: external conductor commands cannot yet address that native session directly. Until the `cmux agent ...` command family exists, use the visible composer for native Codex surfaces, or use the terminal fallback when the conductor must submit autonomously.

Terminal fallback:

```bash
cmux send --surface "$TARGET_SURFACE" --enter "Your prompt"
cmux read-screen --surface "$TARGET_SURFACE" --scrollback --lines 200
```

Verify the prompt left the composer and the agent started processing or produced
output. If it remains stranded, press Enter once with `send-key` and re-read;
do not resend the prompt.

## Claude Code

Claude Code currently remains a terminal/wrapper workflow. Prefer a visible Claude pane when the user wants to watch the session:

```bash
cmux send --surface "$TARGET_SURFACE" --enter "ccy"
```

or reuse an existing Claude pane discovered by:

```bash
cmux identify --json
cmux tree --all --id-format both
```

Use cmux hooks for lifecycle, Feed, notifications, restore, and session identity. The conductor may submit with `cmux send --enter`, then wait on hook events and read scrollback.

```bash
cmux events --category agent --name agent.hook.Stop --reconnect
cmux read-screen --surface "$TARGET_SURFACE" --scrollback --lines 200
```

## Command Set To Add

When implementing native orchestration, add this command family instead of extending terminal scraping:

```bash
cmux agent whoami --json
cmux agent list --json
cmux agent submit --surface "$SURFACE" --text "Prompt text" --json
cmux agent read --surface "$SURFACE" --json
cmux agent events --surface "$SURFACE" --json
cmux agent stop --surface "$SURFACE"
```

Expected behavior:

- `whoami` reports caller workspace, pane, surface, provider, cmux session id, provider thread/session id, cwd, and role labels.
- `list` returns all visible and restorable agent sessions with workspace/pane/surface bindings.
- `submit` uses the provider bridge for native sessions and falls back to terminal submission only for terminal-backed agents.
- `read` returns structured transcript, activity rows, status, current permission state, and the last assistant/user messages.
- `events` streams turn and activity events without stealing focus.
- `stop` stops the provider session without closing the pane unless explicitly requested.

## Saved Swarm Scenes

Saved scenes should compose the command set above:

```bash
cmux scene save "review-swarm"
cmux scene open "review-swarm" --cwd "$PWD"
```

A scene should record layout, roles, provider choice, cwd, initial prompt templates, and restore behavior. It should not record secret prompt text or transient approvals.

## Decision Rule

- Use native Codex surfaces for structured Codex work and future commander automation.
- Use Claude terminal panes when the user specifically wants Claude Code or Claude's hook/Feed behavior.
- Use terminal fallback for generic agents or when cmux lacks a provider bridge.
- If the user asks for a seamless commander-worker flow, implement missing `cmux agent ...` commands before adding more pane-reading heuristics.
