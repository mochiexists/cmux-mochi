# RC signoff package — prepared 2026-09-06 for review on 2026-09-07

Supersedes the status sections of `CLAUDE-RC-HANDOVER-2026-09-06.md`. That
handover's git facts were accurate; only its location and its CI snapshot were
stale. The checkout now lives at
`Documents/mcc/fujira/thefertiliser/cmux-mochi/cmux-mochi-clean-v06422`.

## Candidate identity

| Item | Value |
| --- | --- |
| Branch | `mochi/transport-hive-foundation` |
| Nightly built from | `d46692c36ddc0943cbe1e3d6f6a58301c5382977` |
| Nightly run | 34062197107 |
| Expected build number | 3406219710701 |
| Expected artifact | `cmux-nightly-d46692c` (contains `cmux-nightly-macos-3406219710701.dmg`) |
| iOS beta for this candidate | NOT BUILT — see "TestFlight" below |

Download the Mac review build with:

```sh
gh run download 34062197107 --repo mochiexists/cmux-mochi --name cmux-nightly-d46692c
```

The branch lane signs AND notarizes; only publication to the Sparkle feed is
skipped. The disk image is therefore directly installable. It is a nightly-channel
bundle (`com.cmux-mochi.nightly`), so it installs alongside your stable app rather
than replacing it.

## What changed tonight

Three commits, all CI-only. None of them alters app behaviour, so the nightly
above is a faithful build of the candidate.

- **release-build path fix.** The Release configuration takes `PRODUCT_NAME` from
  `CMUX_FORK_APP_NAME`, producing `cmux Mochi.app` with a `cmux Mochi` executable.
  `ci.yml` still referenced upstream's `cmux.app`, so every release-build failed
  after a successful compile with "app bundle not found". `nightly.yml` had already
  been updated; only `ci.yml` was missed. Its paths now match nightly's exactly.
- **A guard test against that drift.** Checks every workflow's macOS Release bundle
  and executable names against the fork identity, allows channel suffixes such as
  `cmux Mochi NIGHTLY.app`, and leaves iOS products alone. Verified to flag all six
  stale references in the pre-fix workflow.
- **Result-policy fix.** Details below.

## Read this before trusting any "CI green"

The app-host unit-test gate was passing runs it should have failed. Two defects in
`scripts/ci/check_xcode_test_result.py`:

- xcodebuild writes `with N tests skipped and` before the failure count whenever a
  run skipped anything. The summary pattern could not match that, so the real
  aggregate was invisible and the policy fell through to whatever small per-suite
  summary printed last.
- It consulted only the final summary, so a clean trailing suite masked earlier ones.

In run 33990390707 this let shard 3 report **success with 191 failures, 9 of them
unexpected**. Shard 1 reported success although its selected-tests suite never
printed a completion line.

Separately, the recent harness fix that makes the runner wait for Swift Testing is
why shards 2 and 4 turned red. Before it, Swift Testing was cut off mid-run: the
last "green" shard 2 started 122 suites and printed zero completion summaries.
Those failures are pre-existing and newly visible, not new regressions.

**Expect all four shards to fail on the next run.** That is the honest baseline.
The tolerance for ordinary expected assertion failures is unchanged; that remains a
deliberate policy choice and is yours to revisit.

## TestFlight: blocked on one decision

The iOS TestFlight build job is gated on `github.ref == 'refs/heads/main'` and skips
entirely on a branch, with no artifact fallback. A beta for this candidate cannot
exist without landing the branch.

Reusing the existing beta is not viable. The last successful upload was 2026-08-31
from `5ac07698bb`, which is the current head of `main`. Relative to it this branch
changes 120 files under `Packages/iOS`, 22 under `Packages/Shared`, 20 under
`Sources/Mobile`, plus `ios/cmux` and `ios/cmuxPackage`.

Draft pull request #3 is open against `main`. `main` is not branch-protected and the
PR reports MERGEABLE, so the merge is mechanically trivial and purely a judgement
call. Once merged, dispatch `ios-testflight.yml` on `main`.

## Manual checklist for signoff

Carried forward from the handover's acceptance criteria. Each needs a real device
and a real network, so none of it is covered by anything automated above.

1. **Session safety.** Normal quit and force-kill relaunch both preserve scrollback,
   prompts, workspace folders, agent resume identity and zoom. Include Codex working
   under a repository while touching `~/.codex/memories`, and the reported
   copy-workspace-path mismatch. Cleared history stays cleared.
2. **Pairing.** No account or Stack login. A fresh QR succeeds. The Mac does not
   flash connected, then QR, then connected. The phone shows real progress and real
   errors. Pairing persists on BOTH ends before you call it durable. Deletion and
   revocation actually revoke rather than hide.
3. **Reconnect.** Phone background and foreground, cold launch, Mac restart, network
   loss and recovery. No repeated chat bounce, no endless reconnect loop. Reported
   status must match actual operations.
4. **Network routes.** Same-WiFi LAN, phone hotspot including USB tether, and
   Tailscale-only, plus switching between them. Do not infer the route from a UI
   label. Record fallback behaviour.
5. **Sidebar and files.** Finder wording, workspace drag highlight and spring-load,
   an empty group accepting drops immediately, Shift-selected multi-tab moves to
   existing and new drop zones, and local plus wrapped Cmd-click paths opening as
   files rather than as a `https://documents/...` URL.
6. **Reliability and parity.** Transient test servers leave the port list.
   Descriptor counts stay bounded across export, restore and network churn. Then the
   feature ledger: adaptive pane placement, zoom persistence, opaque update popover,
   CLI submit and wait, fork Sentry policy, Privacy Frost and redaction, resource
   footer and Task Manager, artifacts, reopen-closed, safe resume aliases, bundled
   skills, and no unpurchasable Pro prompts.
7. **Markdown editing.** Already present, no new work needed. In a Markdown pane the
   toolbar button reads **Show TextEdit** and switches to the built-in editor, not
   Apple's TextEdit. Confirm edit, Save, Revert and **Show Preview** on the artifact.

## Known-not-done

- The pre-existing app-host test failures are triaged, not fixed. See the triage
  section appended below.
- No physical-device or network-route testing was performed.
- No TestFlight build exists for this candidate.
- `tests/test_ci_universal_release_settings.sh` passes but is not invoked by any
  workflow, and is not executable. Dormant guard, worth wiring up later.

## Triage of the app-host test failures

Scale first, because it reframes everything: shard 2 alone recorded **122 issues
across 31 suites**. Swift Testing in that shard has effectively never been enforced.
When the worst cluster ran, **about 90 suites were open concurrently in one
process**. That single fact explains most of what follows.

### Remote tmux rect publication — 19 issues, ONE cause, fixed

Not a product bug and not timing. The suite is synchronous message injection and
finishes in 0.042 seconds.

`stagePendingLayout` subscribes to `pane-border-status` before issuing the rects
fetch, and that subscribe goes onto the same positional command FIFO that results
are correlated against. Real tmux answers it with its own empty block, so
production is correct. The test's fake stream never fed that block, so every rects
reply was consumed by the subscription's slot and discarded. Hence `windowsByID`
nil everywhere. The giveaway is one assertion expecting 2 queued commands and
seeing 4, exactly two extra subscribes for two windows.

Broken since 2026-07-15 by the commit that added the subscription without updating
the fake stream. Newly visible only because Swift Testing stopped being cut off.

The fix teaches the fake stream to answer fire-and-forget commands the way tmux
does. Test-only; no production code touched. Same cause very likely explains three
more failures in the mirror targeting tests.

### Fork conversation context menu — 25 issues, four causes

- **Spin-waits with no wall-clock deadline** (5 tests). They loop a fixed number of
  `Task.yield()` calls waiting on work that hops to a detached utility task. Under
  ~90 concurrent suites the loop can exhaust before that task is ever scheduled. In
  one case nothing had started after two full waits. Ordering is asserted correctly;
  the code was just later than the loop allowed.
- **Production's 3-second fail-closed probe budgets firing under load** (6 tests).
  These spawn real shell fixtures. The decisive evidence is a test that loops 130
  times and recorded exactly one issue. That is a flake, not a broken contract. Two
  fixtures also busy-wait at 100% CPU, which makes them lose their own race.
- **Two stale expectations** that contradict the current production contract. One
  asserts no verdict is recorded where the code deliberately records a rejection,
  contradicted by a sibling test that passes. The other requires a timeout that
  cannot happen, because same-process-group pipe holders are killed by design.
  Both need an owner decision, so they were left alone.
- **One suspected genuine fork-local regression**, the only one found in this
  cluster: the direct OpenCode context menu reconciliation, from a fork-local commit
  on 2026-07-27. Low confidence, needs a targeted single-test run.

Also found, latent and not the cause of any failure here: a candidate-snapshot
helper hard-codes the process-wide shared agent index, silently bypassing the
injected index and coupling those tests to global state.

### What this means for the release candidate

The overwhelming majority of these failures are test-harness and load artefacts on a
runner executing far too much in one process. That is reassuring for the product and
damning for the gate. One suspected product regression is worth a look; nothing else
here points at shipped behaviour.

Fixing the rest is a substantial piece of work and was deliberately not attempted
against an RC hours before signoff.

### CLI integration family — the biggest cluster of all, and it is a harness bug

These tests fail across three shards, in one batch 47 of 53. The cause is thread
pool starvation inside the test harness, not the app.

The mock socket servers park up to 128 blocking `accept()` calls on the global
concurrent dispatch queue, and the process helper submits its exit observer to that
same width-limited pool. Once more blocked accepts are outstanding than the pool is
wide, the observer never gets scheduled, so the helper declares a timeout for a
child that already finished and then terminates it.

The proof is a log line that is otherwise impossible: exit status 1, with the
complete expected stdout captured, and the timed-out flag set. The child was never
late. Raising timeouts would not have helped. It also explains the split perfectly:
every failing Grok and Antigravity test uses a 128 or 80 connection mock, while the
in-process ones pass in milliseconds.

Fixed by moving the blocking accepts and the process observers onto detached
threads, which are not pool limited. Test-only.

Two further findings in the same family, neither fixed:

- **Eleven Codex hook-stop tests are a half-finished fixture migration.** Their
  mocks answer every request with an empty surface list, so the CLI correctly
  declines to publish. One sibling was upgraded to a real protocol fixture on
  2026-09-05 and now passes; the other eleven still use the old stub. Each needs its
  own expectation updated.
- **Codex hook scripts ignore `$HOME`.** `codexHookScriptsDirectory` resolves the
  home directory from the passwd entry, so a test that points `HOME` at a temporary
  directory still writes into the real `~/.cmux/hooks`, and stale scripts from
  earlier runs then break a "collapse duplicates" assertion. Verified on disk: the
  exact filenames from the CI failure are present locally, dated 15 and 20 August,
  32 scripts in total.

  Be careful with the framing here. Resolving home from the passwd entry is used
  widely across the CLI and app, so this is not a lone outlier that is obviously
  wrong. Whether the hook installer should prefer `$HOME` is a design call. What is
  certain is that it makes those tests non-hermetic and lets stale state accumulate.

### Corrected: the tmux close/detach failures are flakiness, not a defect

Earlier reading called these three failures real. They are not. The same suite
**passed in shard 2 and failed in shard 4 within the same CI run**, on the same
commit and the same binary. The assertion polls for roughly two seconds for a file
written by a deliberately fire-and-forget child process that nothing waits on. That
is a wall-clock race by construction.

## Verification status of tonight's test fixes

The tmux and CLI harness fixes are committed and pushed, syntax-checked, and
reasoned from evidence, but **neither has been type-checked or executed**. No local
build was possible: this machine was running another session's Xcode build at a load
average above 400, and the CI runner was busy with the nightly.

They are test-only and land on shards that are already failing, so the downside is
bounded. If either fails to compile, revert with:

```sh
git revert 637726f153 75dd3b3b4a
```

The CI run dispatched tonight predates both commits, so it validates the workflow
fixes but not these. A follow-up run is needed to confirm them.
