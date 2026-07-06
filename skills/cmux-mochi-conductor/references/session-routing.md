# Session Routing

Use this reference when choosing a target pane, reconciling IDs, or debugging a resume/session mismatch.

## ID Payload Fields

Copy IDs and Show IDs may include:

- `workspace_ref` / `workspace_id`
- `pane_ref` / `pane_id`
- `surface_ref` / `surface_id`
- `agent_name` when the pane has a user-visible agent name
- `agent_kind` such as `codex` or `claude`
- `session_id` from the running agent when detected
- provider/thread ids for native agent-session surfaces when available
- `working_directory`
- `resume_command`

Not every surface has every field. Missing agent fields usually mean the pane has not launched a recognized agent or the detector has not observed the session yet.

## Targeting Rules

- Prefer `surface_id` UUIDs for commands that may cross workspaces or windows.
- Use `surface_ref` only for local, short-lived interactions where you just inspected the same topology.
- Keep `workspace_id` and `pane_id` with logs/screenshots so a future debugger can reconstruct the layout.
- Do not infer Codex/Claude identity from the tab title alone. Use `agent_kind` and `session_id` when available.
- For native agent-session surfaces, distinguish the cmux panel/session id from the provider thread/session id. The conductor needs both.

## Session Reuse

Reuse an existing session when:

- The user asked to continue the same work.
- The pane already has the relevant repo, branch, and conversation context.
- The `session_id` or `resume_command` matches the work being resumed.

Create a fresh pane/session when:

- The user wants an independent review or second opinion.
- The existing pane is busy, blocked on approvals, or in the wrong repo.
- Mixing context would make the result harder to trust.

Use a native Codex agent-session surface when the worker should be structured and visible. Use a terminal Claude pane when the worker must be Claude Code. Do not silently switch providers just because one is easier to automate.

## Divergence Checks

If the visual pane, copied IDs, and expected agent session do not agree:

1. Re-run `cmux tree --all --id-format both`.
2. Ask for or collect Copy IDs / Show IDs from the tab menu.
3. Compare `surface_id`, `agent_kind`, `session_id`, and `resume_command`.
4. Trust the copied/details payload over the tab title.
5. Report the mismatch before sending new work.
