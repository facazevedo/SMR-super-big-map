# v961 exact rocket score pruning — accepted

Production commit `ee51c1a`, version 961 / generator guard 277. All ten standing
rules are GREEN in 15S67E, 24S74W, 45S120W, 61N136W and 17S11W. Each case passes
all eight automated gates plus separate source/RNG and deployment/process review.
The raw two review-only judgments remain unchanged. See all_ten_rules_review.json.

All five complete Surface/Underground height/pass grids, resource sites, rocket
pads, corrected-rock records and ordinary/private-stream outputs match accepted
v960 predecessors. The independent 14N A/B/C comparison also preserves every
predecessor and repeat output. No rule, placement or terrain change was needed.

## Profile and measured improvement

Separate v960 diagnostic profile: 140.247s START-to-T1, including 40.088s surface
height processing and 20.022s outer-resource terrain preparation. See
profile_summary.md for nested timing qualifications. Logging was enabled only in
that test process, not in production or performance acceptance runs.

| 14N134W | A | B | C | Median |
|---|---:|---:|---:|---:|
| v960 |140.229s|140.119s|138.318s|140.119s|
| v961 |135.919s|132.839s|133.666s|133.666s|

Median saving: **6.453s (4.6%)**. T0 starts immediately before the START action
body, after NewGame. T1 requires both surface stretch and post-pipeline
revalidation. First-access underground work is not hidden inside or subtracted
from the claim. The fresh native control completed in 28.636s.

| Scenario | Before | After |
|---|---:|---:|
|15S67E|136.236s|133.102s|
|24S74W|133.694s|132.764s|
|45S120W|124.833s|122.423s|
|61N136W|194.664s|186.110s|
|17S11W|134.262s|131.341s|

Five-site times are single matched correctness samples; only the three-run 14N
medians support the isolated performance claim. Pruning preserves the original
winner at every traversal prefix in 655,454 regression assertions. Height lookups
in each 14N run fall from 3,095,708 to 439,294, with the same 12 selected pads.

## Preservation and process

- Exact score lower bounds only; no approximate scoring, changed search order,
  tie rule, candidate quota, resource rule or scenario-specific exception.
- Height cache, winning-center certificate and failure reporting remain intact.
  Readiness is still a live read-only predicate; the source/RNG proof is in
  source_review.md. No new runtime API, DLL or host helper is required by the mod.
- All 58 offline commands pass: 54 established commands plus four regressions.
  The deliberately red pre-implementation pruning test is retained separately.
- Nine fresh acceptance process identities, exact version/payload checkpoints,
  complete first-access snapshots and clean normal exits. No runtime failure or
  output mismatch occurred. Final local-mod audit: 38/38 exact.
- The unchanged native path reuses accepted same-site v957 controls and has a
  fresh v961 14N control. Full output equivalence inherits prior sampled visual
  acceptance only; no new screenshots or universal visual inspection is claimed.
- Wall/spike repairs, seamless resource blending, selective rock lowering,
  entrances and temporary buttons are untouched. No automatic loop was started.

The accepted median remains **above 70s**. This single requested optimization is
complete; later strategies require the owner's next instruction.
