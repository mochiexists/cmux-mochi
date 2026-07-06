# Agent Turns

Use this reference when sending prompts to a target agent and collecting the result.

## Submit a Prompt

For Codex TUI targets, send text and then press Enter explicitly:

```bash
cmux send --surface "$TARGET_SURFACE" "Summarize the failing test and propose the smallest fix."
cmux send-key --surface "$TARGET_SURFACE" enter
```

For shell targets and some other TUIs, `--enter` can be enough:

```bash
cmux send --surface "$TARGET_SURFACE" --enter "Summarize the failing test and propose the smallest fix."
```

Do not depend on a trailing newline embedded in the sent text.

## Read the Result

```bash
cmux read-screen --surface "$TARGET_SURFACE" --scrollback --lines 200
```

Increase `--lines` when the answer is longer or when the useful output scrolled away.

## Polling Loop

Use a gentle read loop for simple tasks:

1. Send one prompt.
2. Wait a few seconds.
3. Read screen/scrollback.
4. Repeat the read only until the target is idle or the requested answer is visible.

Do not send a second prompt unless the first one clearly failed or the user asked for a follow-up.

## Event-Driven Completion

When hooks are installed, watch for agent stop events:

```bash
cmux events --category agent --name agent.hook.Stop --reconnect
```

Use the event to know that a target turn probably finished, then read the target screen to collect the visible answer. Events are coordination signals, not a substitute for reading the final output.

For native Codex agent-session surfaces, prefer structured turn completion and transcript commands once `cmux agent events/read` exist. Until then, use the visible composer or fall back to a terminal Codex pane when the conductor must submit autonomously.

## Recovery

If the target pane restarted or lost a pending resume prompt:

- Use Show IDs / Copy IDs to find `resume_command`.
- Send the resume command to the same surface.
- Submit with `cmux send-key ... enter` after sending text when the target is Codex TUI.
- Re-read the screen before sending any new task prompt.
