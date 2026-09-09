# Three preservation optimizations — manual session

Owner requests all three suggested strategies in this session:
1. Native crease discovery, with existing repair/feather/terminal formulas unchanged.
2. Exact terrain-mask construction shortcuts, no coarsening or visible boundaries.
3. Remove only demonstrably redundant rebuild work, with new native-state proof.

Keep each measured improvement in its own commit and update reoptimize-ranking.md.
Acceptance per retained unit: three fresh 14N START-to-T1 samples and native control;
all ten rules in five fixed scenarios, exact predecessor terrain/placements, all
existing regressions. Preserve rockets, top-ups, walls/spikes, rock grounding,
entrances and temporary buttons. No Ralph controller, goal API or automatic strategy
beyond these three. No foreign game may be reused or closed.

Baseline HEAD20af194 / productionee51c1a, v961/guard277. Clean worktree and installed
38/38 payload at start; daemon stopped with no untracked games. Median133.666s.
Baseline artifacts: manual-rocket-pruning/artifacts/v961_reference and v961_matrix.

## Current state

Native discovery accepted: code691f900, v962/guard278, median115.665s (saving18.001s).
All59 offline checks and allten rules in five scenarios pass; full outputs exact.
Next: mask construction shortcuts and a fresh native buildability-input diagnostic.
Read-only diagnostic on installed v961 completed; owned game closed normally.
Prior native discovery implementation inspected; do not copy its old unsafe feather
or silent fallback. Existing scalar refinement stays live after prior track writes.
Prior immediate closing-rebuild removal changed pass grids and remains prohibited
unless materially new evidence establishes an exact replacement.

## Attempts

- Initial source/profile/history review: about31.5s before aprons and8.5s in aprons.
  Both closing surface rebuilds have explicit regression coverage. Investigate their
  buildability component separately, not a blind repeat of rejected pass deferral.
- v961 diagnostic exact predecessor parity PASS. Immediate final pass/build hashes
  change; scheduled final pass/build hashes match their inputs on 14N only. This
  is not proof that hidden native pass state can be skipped. Investigate build only.
- Native GridMask/Foreach use inclusive lower bounds but GridCount excludes the
  lower bound. Discovery uses integer-gap cutoffs; 580 offline oracle/failure checks
  pass before integration. Runtime candidate equivalence still required.
- Integrated unit passes all59 offline commands/checks. Native scratch probe:
  15,768 checks, zero mismatches, source bytes unchanged. Cold timing and full
  five-scenario acceptance are next; not all-ten signed off yet.
