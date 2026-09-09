# Exact rocket score pruning — manual, one optimization

Requested: profile v960, implement rocket score pruning, retain only with positive
START-to-T1 improvement and all ten rules passing across five fixed scenarios.
Require exact terrain, placements and prior corrections. No Ralph loop or goal API.

Baseline: HEAD 69fefb7, production 2e2676c, version 960 / guard 276.
Accepted 14N134W median 140.119s; all five prior site comparisons passed.
Initial worktree clean; deployment 38/38 exact; no game process running.

COMPLETE: accepted pruning checkpoint `ee51c1a` (v961/guard277), all58 offline
commands pass, deployed38/38 exact. All ten rules are GREEN in all five scenarios.
Finite
acceptance helper is `_ralph/tmp/rocket_pruning_20260909/accept.py`; it delegates
the unchanged historical-port verification helpers with the exact v960 twins.
Previous evidence is immutable. No test process remains; no further optimization
or Ralph loop is running as part of this task. Final sign-off and ranking updated.

Benchmark complete:135.919/132.839/133.666s, median133.666s vs140.119s (-6.453s,
4.605%). Fresh native control28.636s. Reference audit issues=[]; all three full
predecessor/repeat comparisons pass. All five full predecessor comparisons and
automated gates pass:15S133.102s,24S132.764s,45S122.423s,61N186.110s,17S131.341s.
Separate source/process reviews complete in artifacts/all_ten_rules_review.json.
The133.666s median remains above70s; this single requested unit is complete.

## Attempts

- 2026-09-09: inspected scoring, immutable grid cache and live readiness/spacing.
  Score is readiness bias plus nonnegative range*100 plus axial distance. Strict
  winner replacement permits exact lower-bound rejection, including equal ties.
- Diagnostic profile completed on pinned v960; full predecessor parity passes.
  Height stretch 40.088s, outer-resource terrain preparation 20.022s. Underground
  first-access expansion occurs after T1 and is not a START-to-T1 saving target.
- New actual-scorer regression was red on v960 (equal bound not pruned), then green
  with 655,454 assertions. Existing 81,267-assertion rocket-cache test also passes.
  Production uses exact score lower bounds, live read-only readiness and progressive
  range rejection; it keeps the original search disk, order, strict ties and weights.
- Completed all54 established offline commands plus rocket sampling, native apron,
  crease sampling and new pruning regressions (58 commands, all exit0). Production
  checkpoint committed and synced; no diagnostic timing flag is shipped.
- All nine cold acceptance processes completed with no runtime errors or output
  mismatches. The final evidence-assembly helper initially treated a judgment JSON
  file as a run directory; replaced its glob with the nine explicit run paths and
  reran successfully. No raw verdict, game run or acceptance criterion was changed.
