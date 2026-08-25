# Ralph task contract

## Objective

Reduce a cold **expanded surface** load to **strictly less than 60,000 ms** without
changing any gameplay result or policy. The optimization baseline is committed mod
v888, `f297615` (`Guard ZoomPlus mode cleanup state`). The primary scenario is
**14N134W**; the final gate also covers the established 30S146E and 45S82E controls.

This is an optimization task, not permission to redesign generation. The completed
surface must be the same surface v888 would produce for the same pinned inputs, only
faster.

## Exact timing definition

A timed sample always uses a fresh `MarsDebug.exe` process and a fresh new game with
EXPAND MAP enabled. No hot reload, save reuse, warm process, or partially generated
map may count.

- **T0**: host monotonic time immediately before submitting the new-game/random-map
  generation action for the pinned coordinate.
- **T1**: the first instant at which the surface expansion pipeline has completed,
  all mandatory surface terrain/resource audits and the final gameplay-grid rebuild
  have passed, `SuperBigMapSurfaceStretchDone == true`, no surface finalization is
  pending, the mod loading box has ended, and the normal game UI is interactive.
- **Duration**: `T1 - T0` in milliseconds. Game boot before T0 is not surface loading;
  work deferred beyond T1 is unfinished surface loading and is not allowed.

Use an external monotonic clock plus a minimal stable completion sentinel. Existing
`[Super Big Map][LoadingTiming] SESSION_END` evidence may be used for phase profiling,
but broad diagnostic logging makes that run a profiling sample, not a final release
sample. Do not poll DAP or game state during generation: read a log/sentinel externally
and make at most one post-completion state acquisition. A timeout is a measured failure,
not missing data.

## Final performance gate

All samples must use the final committed and deployed release configuration:

1. 14N134W: **five consecutive cold samples**, each `< 60,000 ms`.
2. 30S146E: **three consecutive cold samples**, each `< 60,000 ms`.
3. 45S82E: **three consecutive cold samples**, each `< 60,000 ms`.

Report every duration, maximum, median, commit, mod version, game version, coordinate,
input seed/hash, and exact T0/T1 markers. The maximum is the gate; an average or median
below one minute cannot hide a slower sample. Any error/assert/modal/crash, audit
failure, missing completion sentinel, or dirty teardown invalidates the sample.

## Frozen gameplay and visual-equivalence contract

Before changing production code, capture a reproducible v888 reference for every
benchmark coordinate with pinned generation inputs. The candidate must match those
references exactly. At minimum compare and preserve:

- random-map seed, generation hash, source preset, source dimensions, and random draw
  count/order at every mod-owned generation boundary;
- raw surface height/type grids and the final buildable/passable grids, `PassBorder`,
  playable bounds, and sector geometry;
- every generated surface object's class, immutable provenance/source key, position,
  angle, scale, relevant properties, visibility/scan state, and class counts;
- all native and top-up deposits, exposed surface deposits, resources, anomalies,
  vistas, research sites, morale effects, cluster identities, landing pads, concrete
  imprints, and badge relocations;
- all terrain-edit masks and resulting grid values, including seamless transitions and
  untouched regions; an output digest mismatch is a regression even if it looks close;
- entrance/passage placement and every inherited exact-parity/ratchet floor currently
  green at v888.

The following current rules are immutable and must remain fail-closed:

- surface resource/anomaly cluster generation and all density top-ups;
- at least three axial hexes between enrichments, including anomalies/effects; exposed
  surface-deposit pairs are the only neighboring-tile exception and may never share a
  tile;
- resource clusters remain six to ten clusters, one to five total resource deposits,
  one to three extractor deposits, at most three anomalies, and at most five combined
  members under the current production definitions;
- the approximately 60/40 split between the outermost sector band and the adjacent
  inner perimeter band;
- surface top-up anomalies remain in the physical two-sector perimeter;
- terrain modification for resource/deposit support remains confined to the physical
  two-sector perimeter: sector x or y in `{0,1,18,19}`. The 256 inner sectors must not
  receive these terrain edits;
- exposed surface deposits receive only the current passable local grade; extractor
  deposits keep their live extractor footprint; rocket pads keep their live landing
  footprint; current C2/quintic irregular transitions and native-detail retention stay
  exact;
- all current placement, obstruction, edge-margin, repulsion, scan-gating,
  buildability, passability, provenance, final census, and final terrain audits.

Do not reduce samples/candidate pools, relax a predicate, change a threshold, skip an
audit, change RNG consumption, reduce counts, move content, narrow the map, scan fewer
required gameplay objects, finish behind the loading UI, or move mandatory surface
work into a background thread merely to stop the clock.

## Allowed optimization surface

Preserve output and order while optimizing implementation. Preferred strategies are:

- profile first and attack measured dominant phases;
- eliminate duplicate whole-map scans, redundant coordinate conversions, repeated
  sorting, duplicate spatial-index construction, and redundant gameplay-grid rebuilds;
- batch equivalent native grid operations and reuse immutable per-generation caches;
- replace allocation-heavy temporary tables with bounded reusable structures where
  iteration order and results remain exact;
- precompute pure constants/offsets and memoize pure deterministic predicates whose
  inputs include every relevant terrain/grid generation stamp;
- remove or disable log messages. Published builds may leave all nonessential logging
  off, including the current focused traces, once their evidence is preserved;
- remove legacy/dead code only after a reachability proof covers fresh generation,
  save/load, mod toggle, camera cleanup, and surface/underground transitions. Deleting
  code that is merely cold on 14N134W is not a reachability proof.

Temporary config-gated phase timing is allowed. Preserve its evidence, then remove it
or return it to default-off before final timing. Logging removal must not remove a
fail-closed validation or audit disguised as a log call. Parallel work is allowed only
where engine thread safety and deterministic iteration/RNG order are proven.

## Required workflow

1. Read the current code and v888 evidence. Do not guess from line count.
2. Capture v888 correctness baselines before the first production optimization.
3. Establish a cold-load baseline and a phase-ranked profile for 14N134W. Attribute at
   least 90% of T0-T1 time before selecting a strategy.
4. Change one measured bottleneck family at a time. For every candidate, run offline
   syntax/static/unit gates, one cold 14N134W timing, and exact reference comparison.
   Revert or fix the same session if any output differs.
5. When 14N134W first passes, prove the three-coordinate consecutive-run matrix and all
   frozen equivalence gates on the same final commit.

`_ralph/tools/parity/outer_ring_policy_check.py` must stay green. Extend focused test
tools rather than weakening them. The historical `_ralph/tools/parity/run_parity.py`
does not implement `--help`; never invoke it merely to inspect usage because that
starts a real game. Read its source or use its documented command forms.

Every production change requires a mod version bump, concise `last_changes`, Lua parse,
relevant offline gates, a commit, then `_ralph/tools/deploy.py sync` and
`_ralph/tools/deploy.py audit` **before** launching the game. Audit must report all
36/36 payload files matching with no missing, stale, or mismatched file. Commit every
accepted change; never push. Preserve unrelated user changes.

Use only the `smr` harness for automated game control. One game process globally. Cold
stop between samples and prove no tracked or untracked `MarsDebug.exe` remains. Never
take over or stop a manually launched user game; wait for it to close.

## Error regression gate

The v888 guard for the reported
`XWindow:Close ... self.class[SelectionModeDialog]` assertion is part of the baseline.
No optimization may reintroduce it. Any `BugReportMinimal`, Lua error, assert, or unknown
modal is diagnosed before another timing attempt and makes the run fail.

## Completion

Create `DONE.md` only when:

- all eleven final cold samples pass strictly below 60,000 ms;
- candidate outputs match the pinned v888 references exactly at all three coordinates;
- every static, spacing, terrain, parity, and audit gate is green;
- final logs contain no error/assert/modal and no mandatory surface work occurs after T1;
- the final version is committed, deployed, audited 36/36, the worktree is clean, and no
  game process remains.

Publish a compact table of timings and correctness digests in the run artifacts and
name the final commit/version in `HANDOFF.md` and `DONE.md`.

## Blockers

`BLOCKED.md` is allowed only for a demonstrated engine lower bound or platform failure
after at least three materially different, profiled optimization strategies at Sol
xhigh, each with preserved before/after phase evidence and exact-output results. A hard
optimization is not a blocker. Quota/usage pauses are not blockers; record and resume.
