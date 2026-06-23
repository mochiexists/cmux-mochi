---
name: cmux-mochi-conductor
description: Drive visible Codex, Claude, or other agent panes from cmux. Use when the user asks to orchestrate another agent, route work between cmux panes, reuse or inspect agent sessions, debug copied workspace/pane/surface/session IDs, resume an agent from a pane, or run a conductor-worker flow inside cmux.
---

# cmux Mochi Conductor

Use this skill when one agent should coordinate another visible cmux agent pane while preserving the user's layout, focus, and session continuity.

## Operating Model

- Driver: the current agent/session doing the coordination.
- Target: a visible terminal surface running Codex, Claude, or another shell/agent.
- Prefer an existing visible pane in the current workspace when it has the right context.
- Spawn a new pane only when the user asks, task isolation requires it, or no suitable target exists.
- Use UUIDs for cross-workspace targeting. Short refs such as `surface:3` are convenient but can become ambiguous across windows/workspaces.
- Treat tab-menu Copy IDs / Show IDs as the source of truth for `workspace_id`, `pane_id`, `surface_id`, `agent_kind`, `session_id`, `working_directory`, and `resume_command`.

## Quick Flow

```bash
cmux identify --json
cmux tree --all --id-format both
```

Pick a target surface, then send the prompt with two commands:

```bash
cmux send --surface "$TARGET_SURFACE" "Review the current diff and report only blocking issues."
cmux send-key --surface "$TARGET_SURFACE" enter
```

Read the target without stealing focus:

```bash
cmux read-screen --surface "$TARGET_SURFACE" --scrollback --lines 200
```

If the response is incomplete, wait briefly and read again. Do not spam repeated prompts.

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
cmux send --surface "$TARGET_SURFACE" "cxy"
cmux send-key --surface "$TARGET_SURFACE" enter
```

Use `ccy` for Claude when the user wants a Claude worker. Use the project's normal launcher if the repo has a more specific alias.

## Completion and Wake-Up

- Default v1 behavior: read the target screen/scrollback until the agent has produced the requested answer or returned to an idle prompt.
- For hook-enabled agents, prefer event-driven completion when available:

```bash
cmux events --category agent --name agent.hook.Stop --reconnect
```

- Use events as confirmation, then collect the final visible output with `cmux read-screen`.
- If hooks are not installed, keep the loop simple: wait, read, and stop once the answer is visible.

For turn patterns and event use, read `references/agent-turns.md`.

## Guardrails

- Do not rely on a trailing `\n` in `cmux send` to submit. Always follow with `cmux send-key ... enter`.
- Do not focus, close, clear, or recycle target panes unless the user asked for that.
- Do not mix up visual tab titles with session identity. Trust Show IDs / Copy IDs and the CLI topology.
- When a session ID diverges from the expected Codex/Claude session, pause and summarize the target map before acting.
- Preserve user work: conductor flows should observe and route, not take ownership of unrelated panes.
