# Surface T0-to-T1 measurement protocol (draft)

Status: **draft, not yet adopted.** It replaces the current acceptance rule, so it needs an
operator ruling before the loop uses it.

**Phase 0 has been run** (2026-09-01, 21 cold runs, 0 crashes). Its results are folded in below
and they are much better than this draft originally assumed. Verdict:
`_ralph/runtime/overnight-super-big-map/phase0-null-experiment-verdict.json`.

## Phase 0 at the Start boundary: drop the pairing (2026-09-01)

24 consecutive runs, 0 crashes, 6 blocks, accepted payload on both arms.

```
unpaired run-to-run SD   673.8 ms
paired ABBA SD_d         692.9 ms      ratio 1.03
mean d                  -375.7 ms      95% CI [-864.6, +111.2]  -> unbiased
phase-shift by offset    -376 / +370 / +107 / -301 ms  -> sign flips, no structure
drift                    -38.3 ms/run
```

**Pairing buys nothing here.** `SD_d` is not smaller than the unpaired SD, which is the signature
of white, run-independent noise rather than the shared slow drift ABBA exists to cancel. The
design is not *wrong* -- it is unbiased, and the phase-shift check confirms it -- it is simply
useless at this boundary, because moving T0 past `ChangeMap("PreGame")` removed the drift that
made pairing worthwhile. Differencing two independent means adds variance instead of removing it.

Use **randomised interleaved two-sample** comparison instead: same session, alternating
control/candidate in randomised order, compare the two arms directly. It is modestly more
efficient for the same run budget:

| total runs | ABBA MDE | two-sample MDE |
|---:|---:|---:|
| 20 | 952 ms | **780 ms** |
| 40 | 595 ms | **540 ms** |
| 80 | 401 ms | **379 ms** |

Everything else in this document stands: same-session control, three outcomes with `inconclusive`
distinct from `reject`, bootstrap CIs at small n, no absolute constant as a threshold, and the
phase-shift check before ever believing a "biased" verdict.

Budget consequences: the ~2.0 s needed for sub-60 is 2-3 sigma and lands comfortably in ~20 runs.
A 0.5 s candidate is *below* the 20-run MDE and marginal at 40; budget 40-80 runs for any
sub-second verdict. Note also that the noise level itself moves -- the earlier 14-run cohort had
an unpaired SD of 380 ms against this cohort's 674 ms -- so re-measure rather than assuming.

Verdict: `_ralph/runtime/overnight-super-big-map/phase0-startboundary-verdict.json`.

## Superseded in part by the T0 ruling (2026-09-01)

T0 is now the Start button (`generation_start.txt` sentinel), not the New Game button. That
changes two things in this document:

- **The 12-run warm-up requirement no longer applies at this boundary.** The warm-up lived almost
  entirely inside `ChangeMap("PreGame")`, which is now outside the clock. Measured drift fell from
  -725 ms/run to -46 ms/run, and the first-three-minus-last-three ramp from ~15 s to 0.5 s. The
  first run of a session is usable. Re-establish this with a null cohort if the machine changes.
- **The MDE table below was computed from the old boundary's 322 ms plateau SD.** The Start
  boundary's baseline SD over 14 consecutive runs is 407 ms (CV 0.656%), so the table is roughly
  right in magnitude; recompute it from a Phase 0 null cohort at the new boundary before relying
  on a specific figure.

Everything else stands: paired ABBA blocks inside one session, three outcomes with `inconclusive`
distinct from `reject`, bootstrap CIs below n=20, and no absolute constant as a threshold.
Baseline: `_ralph/runtime/overnight-super-big-map/start-boundary-baseline.json`.

## Why the current rule cannot work

`execute_surface_only_acceptance.ps1` accepts a candidate when one cold sample is faster than a
constant, `maximum_t0_to_t1_ms = 75813.298`. That constant came from a single run on
2026-08-31. Two measurements since then invalidate the comparison:

1. **Within its own cohort it is an outlier.** Five cold runs of the byte-identical payload gave
   78.84 / 78.98 / 80.97 / 81.07 / 83.16 s — median 80.97, sample SD 1.78 s. The accepted value
   sits 3.03 s *below the minimum* of its own distribution.
2. **It is not reproducible at all across sessions.** Four cold runs on 2026-09-01, on the
   payload restored byte-exact from `SBM_historical_best/` with the manifest verified file by
   file, gave 89.61 / 90.59 / 95.05 / 98.35 s — median 92.82 s, **+17.0 s**. Every one of those
   runs reproduced the accepted output exactly (`plan_digest` 1232699597, `validation_z_digest`
   1418606361, `single_flush_tuple` optimized, draw count 19175, and `deferred_t1` /
   `scheduler_census` hashes byte-identical to the accepted receipt).

The two distributions are **disjoint** — the 2026-09-01 minimum is 6.4 s above the 2026-08-31
maximum — while the output is identical. The payload is therefore not the variable.

Phase 0 has since identified the mechanism: a **~12-run machine warm-up worth up to 14 s**. The
2026-08-31 cohort ran warm, the 2026-09-01 replication ran cold, and neither knew which. Warm-up
is controllable, so this is a fixable instrument defect rather than irreducible noise — but it
was never controlled, and it is larger than every candidate effect the campaign measures.

Every candidate this campaign chases is worth 0.5–3 s. An uncontrolled 14 s warm-up bias is
three to thirty times that. **Absolute times compared across sessions, without a warm-up
guarantee, carry no information about code changes.** Candidates 1, 4, 6, 7 and 14 were rejected
at 80.3–91.6 s, a band this same payload spans depending only on how warm the machine was.

Evidence: `_ralph/runtime/overnight-super-big-map/accepted-baseline-replication-verdict.json`
and `accepted-baseline-five-run-calibration.json`.

## Principle

Measure **differences inside one session**, never absolutes across sessions. A candidate is
compared against a control run of the accepted payload taken minutes away on the same machine in
the same state, and the verdict is a confidence interval on the paired difference.

## Design

### The unit of measurement is an ABBA block, not a run

One block is four cold runs in this order:

```
control, candidate, candidate, control
```

with the block difference

```
d = mean(candidate runs) - mean(control runs)      negative means the candidate is faster
```

ABBA ordering cancels any drift that is linear in time across the block exactly, which simple
`control, candidate` pairing does not: under a rising drift, plain pairing charges the whole
drift to the candidate. Blocks are independent samples of `d`; the analysis is over blocks.

Each run inside a block is a fresh `MarsDebug.exe` with a full teardown, exactly as today. Only
the deployed payload alternates. Nothing else may change inside a session.

### Phase 0 result — the instrument has a 12-run warm-up, then it is excellent

21 cold runs of the accepted payload, back to back, no payload change:

```
run  1-12   95.3 -> 81.7 s   monotone decline, spans 13.6 s   WARM-UP, unusable
run 13-20   80.50 s mean, SD 322 ms, range 812 ms, CV 0.40%   PLATEAU, usable
run 21      83.7 s           +3.4 s, cpu_load 27% vs ~17%     transient, guard would flag it
```

Two conclusions:

1. **The earlier "disjoint distributions" were a warm-up artifact.** The plateau median
   (80,542 ms) sits within 430 ms of the 2026-08-31 five-run cohort median (80,972 ms). That
   cohort ran on a warm machine; the 2026-09-01 replication runs that measured 89.6-98.3 s ran
   on a cold one. It was never time of day or interactive load. The warm plateau reproduces
   across sessions and days to within about half a second.
2. **The accepted 75.813 s constant is still unexplained.** Warm-up makes runs *slower*, so it
   cannot account for a value 4.7 s *faster* than the warm plateau. The constant stays
   unreproducible and must not gate anything.

The ABBA estimator was validated on the cohort: mean `d` = 187 ms with a bootstrap 95% CI of
[-891, +1028] ms, so it is unbiased. Its `SD_d` over the full cohort was 1245 ms, but that number
is inflated because warm-up decay is exponential and ABBA cancels only *linear* drift — which is
exactly why blocks must run inside the plateau.

### Phase 0 — calibrate the instrument before trusting it (re-run whenever the machine changes)

Run the full block protocol with the accepted payload deployed as **both** A and B. The true
effect is zero by construction, so the observed spread of `d` is the instrument's paired noise,
`SD_d`. This is the number nobody has ever measured, and every later decision depends on it.

Phase 0 delivers:

- `SD_d`, the paired residual after ABBA differencing;
- a check that the mean of `d` is statistically indistinguishable from zero — if it is not, the
  block design is biased and must be fixed before any candidate is judged;
- the minimum detectable effect table below, populated with the real `SD_d`.

Run at least 5 blocks (20 runs, ~40 min). Do not skip this. A protocol whose noise floor is
unknown cannot say whether a verdict means anything.

### Phase 1 — sample size follows from the effect you care about

One-sided superiority test, α = 0.05, power = 0.80, over `n` blocks. A cold run costs about
1.9 min end to end, so a block costs about 7.6 min.

Using the measured plateau `SD_d` of 322 ms, and counting the mandatory 12 warm-up runs:

| blocks | measurement runs | + warm-up | wall | minimum detectable effect |
|---:|---:|---:|---:|---:|
| 3 | 12 | 24 | 0.8 h | 740 ms |
| 5 | 20 | 32 | 1.0 h | **443 ms** |
| 10 | 40 | 52 | 1.6 h | 277 ms |
| 20 | 80 | 92 | 2.9 h | 187 ms |

This is far better than this draft originally guessed. **Sub-second candidates are testable.**
Candidate 16's ~0.5 s ceiling needs 5 blocks — about one hour including warm-up — not the eight
hours the pre-Phase-0 estimate implied. The earlier advice to drop sub-second candidates on cost
grounds is withdrawn.

Declare the target effect and its block count before the first run; choosing `n` after seeing the
data invalidates the test.

### Decision rule

Compute the mean of the block differences and a one-sided 95% confidence bound. With `n < 20`
use a bootstrap (10,000 resamples of the block differences) rather than a t-interval; timing
distributions are right-skewed and small-`n` t-intervals will overstate confidence.

- **accept** — upper confidence bound on `d` is `< 0`. Report the point estimate and interval.
- **reject** — lower confidence bound is `> 0`. The candidate is genuinely slower.
- **inconclusive** — the interval spans 0. This is the honest and most common outcome for a
  sub-MDE candidate. It is *not* a rejection, and it must not be recorded as one. Either add
  blocks to reach the required `n`, or mark the candidate as below the measurable floor and move
  on.

Correctness is a separate, absolute gate and is unchanged: every run must still produce the full
digest corpus, the RoughTerrain proof, no pre-T1 Underground work, and a clean teardown. A run
failing correctness is not a slow run, it is an invalid one.

## Environmental controls

The 10 s between-session shift is the thing being controlled. Pairing removes most of it; these
reduce what is left.

- One session, back to back, no other heavy process started or stopped mid-session.
- **Discard the first 12 runs of every session** as warm-up, and verify convergence rather than
  assuming it: the last four warm-up runs should sit inside the plateau's spread. Phase 0
  measured a 13.6 s monotone decline over runs 1-12 before the number stabilised. A single
  warm-up run — what this draft first proposed — would have left a 14 s bias in the data.
- Fixed power plan; no sleep, no display blanking transitions.
- Record per run and store in the sample record: CPU load average, free physical memory, current
  and max CPU clock, total process count, and whether a game process existed before launch.
  `replicate_accepted_baseline.ps1` now captures this. A run whose telemetry breaches a declared
  guard is flagged, not silently kept — Phase 0's run 21 was +3.4 s with cpu_load 27% against a
  plateau norm of ~17%, which such a guard would have caught.
- Interactive tooling (editors, agent CLIs) is part of the environment. Note its presence in the
  session record. Do not compare a cohort taken with it against one taken without it.

## Invalid runs

- **Engine crash.** The accepted release crashes about 1% of runs — access violation on the Lua
  thread at module offset `…eb46` in `SBMSourceBuildableRawGridBridge`, seen in 2 of 183 logged
  runs. A crashed run is discarded and *redrawn in the same position of the block*, never
  substituted by shifting later runs, which would break the ABBA symmetry.
- **Digest mismatch.** Halts the experiment. The candidate is not output-equivalent, which is a
  correctness verdict and outranks any timing question.
- **Dirty teardown or a surviving process.** Discard the run and the block containing it.

Record every discarded run with its reason. A protocol that hides its discards cannot be audited.

## What changes in the tooling

- `maximum_t0_to_t1_ms` stops being an acceptance threshold. Set it loose (300 s) so correctness
  always completes, exactly as `replicate_accepted_baseline.ps1` already does. The
  improvement-only `throw` at `execute_surface_only_acceptance.ps1:727` is the mechanism that
  produced the invalid verdicts and must not gate candidates.
- The accepted best remains recorded as history and provenance. It stops being a comparison
  target. Any absolute number is reported only alongside its own session's control median.
- `replicate_accepted_baseline.ps1` already provides the run primitive: payload-identity
  enforcement, loose threshold, correctness reduction, crash detection, and a JSONL ledger. An
  A/B driver on top of it needs to alternate the deployed payload, emit block records, and run
  the bootstrap.

## Re-adjudicating the existing queue

Past verdicts were single samples against the outlier constant, so their *timing* conclusions do
not survive; their *correctness* and *capability* findings do, and those are the majority of the
campaign's real output. The infeasibility verdicts — no map-backing resize primitive, no
region-scoped `BuildableGrid:Build`, `ChangeMapInSlot` already paid before `DoGenerate`, no
repeatable pure prefab search — rest on live capability probes, not on timing, and stand
unchanged.

Timing rejections should be re-read as: candidate 14 (+12.2 s) and candidate 1 (+15.8 s) are
plausibly genuinely slower, since they exceed even the between-session shift. Candidates 4
(+4.5 s), 6 (+9.2 s) and 7 (+8.9 s) fall inside the band this payload spans on its own and are
properly **inconclusive**, not rejected. Re-testing any of them is only worthwhile if its
expected effect exceeds the Phase 0 MDE.

## Open question this protocol does not settle

None of this makes the mod faster. It makes the campaign able to tell whether a change did
anything. The separate finding stands: about 60% of T0-to-T1 is engine or stock work the
contract forbids touching, roughly 20 s of the measured interval is a `ChangeMap("PreGame")` a
real player pays before pressing Start, and the remaining in-mod harvest is 2–4 s. Deciding the
T0 boundary is worth more than any measurement improvement, and it is an operator ruling.
