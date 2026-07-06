# Telephone Loop Template

Use this template when the user wants a visible loop-engineering demo: four cmux panes in a 2x2 grid pass a message in a circle. The fun is watching each agent decide what to do with the message.

Do not write helper relay scripts. Each visible agent should pass the baton itself with cmux send commands so the user can watch the swarm.

## Setup

1. Identify the current topology:

   ```bash
   cmux identify --json
   cmux tree --all --id-format both
   ```

2. Pick four target terminal surfaces in the same workspace, arranged 2x2. Prefer existing visible agent panes. If creating fresh workers, create visible terminal surfaces and launch the requested agent in each.

3. Assign each surface a stable label. Do not infer visual position from the pane or surface number alone; verify labels with `cmux tree` plus `cmux read-screen` after the panes render.

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

5. Verify every target is ready before starting the baton:

   ```bash
   cmux tree --workspace "$WORKSPACE" --id-format both
   cmux read-screen --workspace "$WORKSPACE" --surface "$SURFACE_A" --lines 20
   cmux read-screen --workspace "$WORKSPACE" --surface "$SURFACE_B" --lines 20
   cmux read-screen --workspace "$WORKSPACE" --surface "$SURFACE_C" --lines 20
   cmux read-screen --workspace "$WORKSPACE" --surface "$SURFACE_D" --lines 20
   ```

   If a pane was just created, wait until the shell prompt or agent composer is visible. `new-workspace` and layout creation can return before every terminal has finished its first render.

## Worker Prompt

Send this to each worker, changing `YOUR_LABEL`, `NEXT_LABEL`, `NEXT_SURFACE`, `NEXT_SUBMIT`, and whether this worker should mark the next hop as `FINAL`.

```text
You are YOUR_LABEL.

If somebody passes you a message, pass it to NEXT_LABEL. Keep it the same, or not, it is up to you :)

Rules:
- Only react to a message that starts with BATON.
- Use your own wording in the pane before you pass it on, if you want.
- Pass it on by running exactly one shell command. The next message only needs to start with BATON:
  cmux send --surface "NEXT_SURFACE" "BATON from YOUR_LABEL: <message you want to pass>" && NEXT_SUBMIT
- If this is the final hop, include FINAL somewhere in the BATON message.
- If you receive a BATON marked FINAL, react however you like and do not pass it on.
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

`cmux send --enter` is enough for many shell targets, but it can leave text sitting in the Codex TUI composer without submitting. For visible Codex workers, always pair `cmux send` with `cmux send-key ... enter`.

## Starter Baton

Start the loop by sending the first message to A:

```bash
cmux send --surface "$SURFACE_A" "BATON from COMMANDER: hey, I passed you a message. pass it to B. keep it the same, or not, it is up to you :)"
cmux send-key --surface "$SURFACE_A" enter
```

## Socket Routing Smoke

This is not the demo. Use it only to verify surface targeting before launching agents.

```bash
cmux send --workspace "$WORKSPACE" --surface "$SURFACE_A" --enter "echo 'A received cycle 1: frosted glass release train left at midnight'"
cmux send --workspace "$WORKSPACE" --surface "$SURFACE_B" --enter "echo 'B received from A cycle 2: frosted glass release train became frosty glass release tram'"
cmux send --workspace "$WORKSPACE" --surface "$SURFACE_C" --enter "echo 'C received from B cycle 3: frosty glass release tram became frosted class release tram'"
cmux send --workspace "$WORKSPACE" --surface "$SURFACE_D" --enter "echo 'D received from C cycle 4: frosted class release tram became frosted glass release plan'"
cmux send --workspace "$WORKSPACE" --surface "$SURFACE_A" --enter "echo 'A final from D cycle 5: frosted glass release plan became frosted glass loop plan'"
```

## Watch

Read any surface without changing focus:

```bash
cmux read-screen --surface "$SURFACE" --scrollback --lines 120
```

If one worker stalls, send a single nudge to that worker:

```bash
cmux send --surface "$SURFACE" "Continue the telephone loop from the latest baton visible in this pane. Follow your assigned NEXT_SURFACE."
cmux send-key --surface "$SURFACE" enter
```

## Cleanup

Do not close panes automatically after the demo. Ask the user whether to keep the scene, save it, or close the worker surfaces.

## Notes

- This template intentionally allows each agent to decide whether the message stays intact.
- Keep the ring 2x2 for the first test. Four panes and one full lap are enough.
- If the same worker receives two batons, process only the newest one and mention that the older one was superseded.
