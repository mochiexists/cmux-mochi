---
name: cmux-mochi-conductor
description: Drive visible Codex, Claude, or other agent panes from cmux. Use when the user asks to orchestrate another agent, route work between panes, reuse or inspect agent sessions, choose Codex-native vs Claude pane workflows, debug copied workspace/pane/surface/session IDs, resume an agent from a pane, or run a conductor-worker flow inside cmux.
---

# cmux Mochi Conductor

Use this skill when one agent should coordinate another visible cmux agent pane while preserving the user's layout, focus, and session continuity.

## Operating Model

- Driver: the current agent/session doing the coordination.
- Target: a visible agent surface or terminal surface running Codex, Claude, or another shell/agent.
- Prefer structured provider/session APIs over terminal keystrokes whenever cmux exposes them.
- For Codex, prefer cmux's native `agent-session` surface because it talks to `codex app-server` directly.
- For Claude Code, prefer the visible terminal/wrapper flow plus cmux hooks, because Claude is currently integrated through its TUI and hook stream.
- Prefer an existing visible pane in the current workspace when it has the right context.
- Spawn a new pane only when the user asks, task isolation requires it, or no suitable target exists.
- Use UUIDs for cross-workspace targeting. Short refs such as `surface:3` are convenient but can become ambiguous across windows/workspaces.
- Treat tab-menu Copy IDs / Show IDs as the source of truth for `workspace_id`, `pane_id`, `surface_id`, `agent_kind`, `session_id`, `working_directory`, and `resume_command`.

## Quick Flow

```bash
cmux identify --json
cmux tree --all --id-format both
```

Choose the workflow:

- Codex native surface: use an existing `agent-session` surface or create one, then interact through its visible composer until cmux exposes external `agent submit/read/events` commands.
- Claude terminal surface: use `ccy`/`cc` or an existing Claude pane; submit with `cmux send --enter` and watch hook events when available.
- Generic terminal agent: use the terminal fallback.

Create a native Codex agent surface when you need a fresh structured Codex worker:

```bash
cmux new-surface --type agent-session --provider codex --workspace "${CMUX_WORKSPACE_ID:-}" --focus false
```

Terminal fallback, for Claude and non-native agents:

```bash
cmux send --surface "$TARGET_SURFACE" --enter "Review the current diff and report only blocking issues."
```

For Codex TUI targets, prefer an explicit submit key after sending text:

```bash
cmux send --surface "$TARGET_SURFACE" "Review the current diff and report only blocking issues."
cmux send-key --surface "$TARGET_SURFACE" enter
```

Read terminal targets without stealing focus:

```bash
cmux read-screen --surface "$TARGET_SURFACE" --scrollback --lines 200
```

If the response is incomplete, wait briefly and read again. Do not spam repeated prompts.

For one image of the whole visible workspace (every pane plus the tab bar, with a per-pane rect map in the JSON payload; the left sidebar is excluded by default, `--sidebar include` to keep it), use the workspace capture instead of stitching per-surface screenshots:

```bash
cmux capture-workspace --workspace "$CMUX_WORKSPACE_ID" --out /tmp/workspace.png
```

The workspace must already be selected in its window; the command never changes focus, so capture your own caller workspace or ask before selecting another one.

For detailed Codex-vs-Claude choice and the desired native command set, read `references/native-agent-workflows.md`.

## Arrival Rules

- If `CMUX_SURFACE_ID` or `CMUX_WORKSPACE_ID` is set, you are already inside cmux. Run `cmux identify --json` before creating or routing panes. Newer builds also provide `cmux whoami --json` as an alias.
- Do not infer the target workspace from the visually focused tab. Use the caller env, `identify`, and `tree --all --id-format both`.
- When the user says "this workspace" or asks for a tab beside the current session, default to `CMUX_WORKSPACE_ID` and keep `--focus false` unless they asked to switch focus.
- Use `new-surface --type agent-session --provider codex` for a native Codex tab. Use terminal Codex/Claude panes only when the conductor must submit and read turns autonomously today.
- When the user asks to run something "where I can watch it", open a visible plain terminal pane/workspace running the CLI in TUI form (`new-workspace --cwd ... --command ...`, or a terminal surface plus `send`). Never keep the run as a hidden background job in your own shell, and do not pick the native agent-session (web) view for a streaming `codex exec`-style run unless the user asked for the native view.
- Avoid raw `cmux rpc` for topology edits unless the method schema is known. A wrong raw param can fall through to focus-based defaults in older builds; named CLI commands are safer.

## Demo Templates

For a visible conductor/worker demo, use one of the templates instead of writing temporary relay scripts:

- `templates/telephone-loop.md`
- `templates/additive-story-loop.md`

These create a ring of visible panes where each agent receives a message, acts on it according to the demo rules, and passes it to the next surface with cmux send commands.

## Target Selection

- For existing panes, inspect `cmux tree --all --id-format both` and prefer the pane already showing the relevant repo, branch, or agent.
- If app UI is available, ask the user to use the tab context menu Copy IDs or Show IDs when CLI topology is not enough.
- If the copied payload includes `session_id`, use it to verify the target agent session before sending sensitive or long-running work.
- If the payload includes `resume_command`, keep it as the exact recovery command when the pane loses a pending resume prompt.
- If no agent fields are present, the pane may not have a recognized Codex/Claude session yet.

For detailed ID handling, read `references/session-routing.md`.

## Creating a Worker Pane

Create a right split in the current workspace when a fresh worker is needed:

```bash
cmux new-split right
cmux tree --all --id-format both
```

Launch the requested agent in the new surface:

```bash
cmux send --surface "$TARGET_SURFACE" --enter "cxy"
```

Use `ccy` for Claude when the user wants a Claude worker. Use the project's normal launcher if the repo has a more specific alias.

## Completion and Wake-Up

- Default terminal behavior: read the target screen/scrollback until the agent has produced the requested answer or returned to an idle prompt.
- For hook-enabled agents, prefer event-driven completion when available:

```bash
cmux events --category agent --name agent.hook.Stop --reconnect
```

- Use events as confirmation, then collect the final visible output with `cmux read-screen`.
- If hooks are not installed, keep the loop simple: wait, read, and stop once the answer is visible.
- For native Codex agent surfaces, use the visible agent-session UI until cmux exposes `agent read/events`; do not scrape the WebView by screenshot.

For turn patterns and event use, read `references/agent-turns.md`.

## Guardrails

- Do not rely on a trailing `\n` in `cmux send` to submit. For Codex TUI panes, send the text and then run `cmux send-key ... enter`.
- Do not scrape native agent-session surfaces by screenshot or DOM text as the primary integration. Add or use structured agent commands.
- Do not focus, close, clear, or recycle target panes unless the user asked for that.
- Do not mix up visual tab titles with session identity. Trust Show IDs / Copy IDs and the CLI topology.
- When a session ID diverges from the expected Codex/Claude session, pause and summarize the target map before acting.
- Preserve user work: conductor flows should observe and route, not take ownership of unrelated panes.
