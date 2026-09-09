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

All 59 offline commands/checks green. Cold evidence pending; this source review is
not yet a timing acceptance or full all-ten-rules sign-off.
