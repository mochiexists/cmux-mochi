# Unified workspace fabric — workspaces decoupled from machines

Status: proposed. Idea captured 2026-07-25 (operator, during remote-work setup).
Decision (operator, 2026-07-25): the desired end state is NOT multi-Mac aggregation
(upstream `feat-ios-multi-mac-workspaces`: merged lists, machine-tagged rows) but one
workspace fabric — a workspace is a first-class entity and **which machine executes it
is a mutable "runs-on" property**. "This workspace: do it on the M4 now."

## Today, the blockers

- A workspace is owned by the Mac that created it; identity and execution are fused.
- The iOS shell is single-active-Mac (attach tears down the previous Mac); upstream's
  aggregation plan federates views but keeps machines as the organizing principle.
- No verb exists to rebind a workspace's execution host, let alone migrate live state
  (terminal scrollback, panes, agent sessions).

## What already works (the seed)

Remote-SSH workspaces decouple view from execution today: a tab in the M5 sidebar whose
terminals run on the M4 over the tailnet (proven 2026-07-23, `cmux ssh` + reconnect).
Runs-on decoupling exists — per-tab, at creation time, immutable thereafter.

## Near-term approximation (no new architecture)

Hub-and-spoke: one Mac (the hub) holds local tabs + remote tabs to every worker; its
sidebar *is* the fabric. iOS mirrors only the hub and therefore sees the whole estate —
sidesteps single-active-Mac entirely. Costs: hub must be up; runs-on chosen at tab
creation, not rebindable.

## Target model

```
            workspace record (synced, machine-agnostic)
            id · name · repo/cwd · runs-on: <device-id> · route hints
                              │
        ┌─────────────────────┼─────────────────────┐
        ▼                     ▼                     ▼
     M5 (hub?)               M4                  mac minis
   renders/executes    renders/executes       renders/executes
        any workspace whose runs-on points at it
```

- Workspace records live in the local-first sync substrate upstream is building
  (`feat-do-device-list`, `feat-ios-paired-mac-backup`) — every device knows every
  workspace; runs-on selects the executor.
- Rebinding runs-on = detach surfaces on the old host, attach on the new one against the
  same record. Live-state migration (scrollback, running agents) is a later phase; v1 can
  rebind only workspaces whose processes are re-startable (agent sessions resume via
  their own persistence, e.g. claude --resume, tmux on the target).

## Phases (each independently shippable)

- **P1 — hub-and-spoke discipline (no code).** Operate the fabric via remote tabs; document
  the pattern; find the friction worth fixing.
- **P2 — runs-on in the model.** Add device identity + runs-on to workspace records on the
  sync substrate; render machine badges in sidebars/iOS; still immutable.
- **P3 — the rebind verb.** `cmux workspace move --to <device>` for cold rebinds
  (re-startable workloads only).
- **P4 — warm handoff.** Migrate terminal/agent state (tmux adoption, session relink, or
  styled-cell snapshot replay).

## Watch

- Upstream decision (Lawrence, 2026-06-09): iroh becomes the DEFAULT transport, Tailscale
  opt-in. Rides straight into this design's route hints — and its GFW behavior (QUIC +
  relays) matters for operator travel (China: Tailscale peer traffic passes, exit nodes
  and coordination are shakier).
- Upstream aggregation phases P1–P3 land device identity on the mobile model — P2 here
  should reuse, not duplicate.
