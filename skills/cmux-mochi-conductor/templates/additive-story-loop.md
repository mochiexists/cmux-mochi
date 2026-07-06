# Additive Story Loop Template

Use this template when the user wants four visible cmux agents to build a tiny story together, one word at a time, in a 2x2 loop. The loop keeps going until one agent decides the story is done.

Do not write helper relay scripts. Each visible agent should pass the story itself with cmux send commands so the user can watch the sentence grow.

## Setup

1. Identify the current topology:

   ```bash
   cmux identify --json
   cmux tree --all --id-format both
   ```

2. Pick four target terminal surfaces in the same workspace, arranged 2x2. Prefer existing visible agent panes. If creating fresh workers, create visible terminal surfaces and launch the requested agent in each.

3. Assign each surface a stable label. Do not infer visual position from pane or surface numbers alone; verify labels with `cmux tree` plus `cmux read-screen` after the panes render.

   ```text
   A -> surface:<id-or-ref>
   B -> surface:<id-or-ref>
   C -> surface:<id-or-ref>
   D -> surface:<id-or-ref>
   ```

4. Decide the ring order. Example:

   ```text
   top-left A -> top-right B -> bottom-right C -> bottom-left D -> top-left A
   ```

## Worker Prompt

Send the same prompt shape to each worker, changing only `YOUR_LABEL`, `NEXT_LABEL`, `NEXT_SURFACE`, and `NEXT_SUBMIT`.

```text
You are YOUR_LABEL.

We are making a tiny story together, one word at a time.

If somebody passes you a STORY, add exactly one word to the end and pass it to NEXT_LABEL. Do not rewrite, delete, reorder, or tidy up earlier words. Just append one word.

If the story feels complete after your word, you may end it by including FINAL in the message you pass on. Do not end it just because you can; let it run long enough to become a small story.

Rules:
- Only react to a message that starts with STORY.
- You may say your added word in the pane if you want.
- Pass it on by running exactly one shell command. The next message only needs to start with STORY:
  cmux send --surface "NEXT_SURFACE" "STORY from YOUR_LABEL: <full story with your one word added>" && NEXT_SUBMIT
- If you decide the story is done, include FINAL somewhere in the STORY message.
- If you receive a STORY marked FINAL, react however you like and do not pass it on.
- Do not create helper scripts, temp files, background loops, or contact external services.
- Preserve the active CMUX_SOCKET_PATH if it is set.
```

Use this for `NEXT_SUBMIT` when the next worker is a Codex TUI pane:

```bash
cmux send-key --surface "NEXT_SURFACE" enter
```

Use this for `NEXT_SUBMIT` when the next worker is a plain shell:

```bash
true
```

For visible Codex TUI workers, pair `cmux send` with `cmux send-key ... enter`. `cmux send --enter` can leave text sitting in the composer without submitting.

## Starter Story

Start the loop by sending the first story fragment to A:

```bash
cmux send --surface "$SURFACE_A" "STORY from COMMANDER: once"
cmux send-key --surface "$SURFACE_A" enter
```

Good starter fragments:

```text
once
tonight
outside
suddenly
```

## Watch

Read any surface without changing focus:

```bash
cmux read-screen --surface "$SURFACE" --scrollback --lines 120
```

If one worker stalls, send a single nudge to that worker:

```bash
cmux send --surface "$SURFACE" "Continue the story loop from the latest STORY visible in this pane. Add exactly one word, then pass it to NEXT_LABEL. If the story feels complete after your word, you may include FINAL."
cmux send-key --surface "$SURFACE" enter
```

## Cleanup

Do not close panes automatically after the demo. Ask the user whether to keep the scene, save it, or close the worker surfaces.

## Notes

- This demo makes cooperation visible because the story grows one word per agent.
- It also reveals when an agent cannot resist rewriting or tidying previous words.
- The stop condition is model-driven: any worker may mark the story FINAL once it feels complete.
- If the story ends too quickly, restart with a starter fragment that implies motion, such as `outside`, `suddenly`, or `tonight`.
