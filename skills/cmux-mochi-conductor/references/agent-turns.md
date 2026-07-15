# Agent Turns

Use this reference when sending prompts to a target agent and collecting the result.

## Submit a Prompt

For Codex TUI targets, type and submit in one atomic command:

```bash
cmux send --surface "$TARGET_SURFACE" --enter "Summarize the failing test and propose the smallest fix."
```

Use the same form for shell targets and other TUIs:

```bash
cmux send --surface "$TARGET_SURFACE" --enter "Summarize the failing test and propose the smallest fix."
```

Do not depend on a trailing newline embedded in the sent text.

Immediately read the target after a brief pause. Confirm the prompt moved out of
the input composer and the target shows processing, assistant output, or a later
idle prompt. Command success proves that cmux routed the input, not that the TUI
accepted the turn. If the text is still stranded in the composer, run
`cmux send-key --surface "$TARGET_SURFACE" enter` once, then read again. Do not
resend the prompt.

For a one-shot task, `--wait` implies `--enter`, waits for the screen to settle,
and prints the visible result:

```bash
cmux send --surface "$TARGET_SURFACE" --wait "Summarize the failing test and propose the smallest fix."
```

## Read the Result

```bash
cmux read-screen --surface "$TARGET_SURFACE" --scrollback --lines 200
```

Increase `--lines` when the answer is longer or when the useful output scrolled away.

## Polling Loop

Use a gentle read loop for simple tasks:

1. Send one prompt with `--enter`.
2. Wait briefly and read screen/scrollback to prove submission.
3. If it is stranded in the composer, press Enter once without resending text.
4. Repeat only the read until the target is idle or the requested answer is visible.

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
- Submit prompts with `cmux send --enter`, then verify with `read-screen`.
- Re-read the screen before sending any new task prompt.
