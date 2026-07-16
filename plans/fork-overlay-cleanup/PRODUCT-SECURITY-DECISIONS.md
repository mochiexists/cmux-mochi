# Clean replay product and security decisions

These decisions close the product and security questions that must not be improvised during
semantic replay. They define the clean acceptance contract; stable behavior remains evidence,
not an automatic mandate to preserve an unsafe or over-broad implementation.

## Agent resume modes

Retain the stable tri-state model with **Medium** as the default:

| Mode | Scrollback | Resume command | Submission |
| --- | --- | --- | --- |
| Off | Do not replay | Do not prefill | Never |
| Medium | Replay | Prefill | Wait for the user |
| Full | Do not replay | Prefill | Submit immediately |

The legacy Boolean migrates `true` to Full and `false` to Off. Full deliberately omits replayed
scrollback so an automatically resumed provider owns the new terminal transcript. A restored
command preserves an explicitly recorded provider, session, working directory, and safety mode.
Missing or ambiguous safety metadata never escalates to an unsafe provider flag.

Live clean acceptance still requires a real relaunch in all three modes. The decision is closed;
the runtime proof is not.

## Event-confirmed submission

Submitting bytes and accepting a provider turn are separate facts:

1. A delivery result confirms only that cmux sent the requested bytes to the intended surface.
2. Confirmed submission succeeds only after a lifecycle event from that same surface identifies
   the accepted turn. A request or turn correlation identifier is required when the provider can
   supply one.
3. Confirmed completion succeeds only after a later terminal lifecycle event for the accepted
   turn. Screen stability, elapsed settle time, and prompt-shape polling are never success signals.
4. Wrong-surface events are ignored. Timeout, cancellation, provider exit, unsupported lifecycle
   hooks, and surface replacement return distinct typed results.
5. Providers without lifecycle hooks may support delivery-only send, but confirmed submit or wait
   must report unsupported or time out; they must never upgrade delivery into acceptance.

Authenticated provider proof is deferred until a privacy-safe credential fixture is explicitly
available. Owner: agent lifecycle adapters. Re-evaluate when the isolated fixture can emit a
provider accepted-turn event without retaining prompts or credentials.

## Artifact renderer network policy

Artifact rendering is offline and default-deny. Bundled renderer resources and the artifact's
local content may load; direct HTTP(S) navigation, subresources, fetch/XHR, WebSocket, and other
network schemes are denied. A user-activated external link may be handed to a normal cmux browser
surface or the system browser after scheme validation, but it does not grant the renderer network
access.

Any future networked artifact is a separate capability with visible user consent, origin and
destination constraints, revocation, and dedicated tests. It is not part of this replay.

## Artifact bridge grants and capabilities

The clean bridge is versioned, default-deny, and bound to one artifact instance and its owning
workspace. The default grant exposes capabilities plus bounded metadata and event snapshots for
that workspace only. Cross-workspace or `all` scope is absent.

Reading source or text requires an explicit per-surface grant. Every request validates protocol
version, main-frame origin, source artifact, owning workspace, method, scope, sizes, replay count,
and response size. Grants are revoked when the artifact closes or changes workspace. The replay
does not expose arbitrary file reads, socket forwarding, script evaluation, writes, process
launch, or implicit capability escalation.

Owner: the native Artifact host and bridge package. Re-evaluate the exact grant UI when the native
host exists; the least-privilege boundary above is fixed now.

## Yolo aliases

Retire cmux-injected `cxy` and `ccy` aliases and do not advertise them in Welcome. The clean shell
integration must not add an ambient command that bypasses approvals or sandboxing. Users remain
free to define their own aliases.

Restore compatibility preserves an explicitly recorded unsafe launch by rendering the provider's
real resume command with that recorded flag. It may recognize historical alias tokens when reading
old session metadata, but it does not emit an alias or infer unsafe mode when metadata is missing.
Normal `cx` and `cc` convenience names are outside this decision and require their own product case
if replayed.

## OVM

Retain OVM only as an optional documentation cross-reference. It is not a runtime dependency, a
setup prerequisite, or a top-level clean Welcome claim. Re-evaluate Welcome placement only when a
shipped cmux workflow directly integrates with OVM and has its own behavior proof.

## Clean Welcome selection

Generate clean Welcome output only from retained, clean-owned rows whose behavior proof is ready.
The catalog may explain user-visible capabilities and current signed-build limitations; it must
not advertise internal safeguards, implementation fixes, deferred work, source-only findings, or
rows with incomplete live acceptance.

Specifically:

- remove the Yolo and OVM top-level claims;
- split compound stable claims so one proven sub-behavior cannot imply its unproven siblings;
- keep placement, socket targeting, provider process safety, and performance budgets out of
  Welcome and document them in their technical homes;
- show passkey status only while the exact installed signed build proves it;
- derive both human and machine-readable output from the same feature selection.

Owner: the Welcome catalog generator. Re-evaluate the selected claim set after every retained row
has clean evidence; absence from pre-replay Welcome is not evidence that a feature was retired.
