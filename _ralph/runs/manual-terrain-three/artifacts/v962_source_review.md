# v962 native crease discovery source review

Production predecessor: v961 / ee51c1a (sign-off HEAD20af194).
Changed runtime unit: read-only discovery in RepairInternalHeightStep only.

U16 integer differences, doubled absolute flanks and shifted threshold margins
remain exactly representable in F32. Integer-gap masks avoid the real engine's
different inclusive/exclusive lower-bound rules for Mask/Foreach versus Count.
Each width exports the same magnitude/flank predicate as the scalar oracle;
the omitted flank floor of one cannot exclude a candidate because threshold>=128.
Direction is intentionally not filtered: the native list is a superset, replayed
in original perpendicular/edge order through unchanged scalar width/direction/tie
checks. Both axes are discovered before any repair writes. Refinement reads live
terrain after earlier track writes; no discovery index is reused for refinement.

Existing narrow-wall/terminal repair geometry, bounded monotone feather, source
repair, apron/rocket/resource math, placements, grounding, rebuilds, temporary
buttons, ordinary RNG and private placement/decor streams are unchanged. No RNG
call is added. Failure is explicit, scratch is freed and failed private height
results are not published; there is no scalar runtime fallback.

Offline helper oracle: 582 checks including threshold/sign/fringe/axis/stride
cases, unavailable API and missing/duplicate callbacks. Real engine scratch proof:
15,768 checks, zero candidate/order mismatches, complete input bytes unchanged.
Original 3,097 sampling regression assertions and eight full sparse 8192 geometry
checks remain. The geometry fixture supplies all scalar positions as its read-only
backend; it still executes original acceptance and full repair. Native backend is
covered independently and requires exact full cold predecessor outputs.

All59 offline commands/checks green. All nine fresh acceptance processes completed
normally on immutable691f900/installed38 payload files. Reference median115.665s
versus133.666s, saving18.001s; all three predecessor/repeat comparisons exact.
Five scenario comparisons and all eight automatic gates pass. This source/RNG
proof and the separately verified process provenance complete the two manual
review gates without rewriting raw judge fields. Full all-ten sign-off is recorded
in v962_all_ten_rules_review.json. Previous sampled visual acceptance is inherited
through exact complete outputs; no newly inspected screenshot is claimed.
