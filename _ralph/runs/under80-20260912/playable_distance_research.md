# Playable distance composition: scratch identity passes, speed unknown

Current user goal is reference arithmetic mean START-to-T1 below85s, with all
correctness/terrain rules retained. Accepted production remains56fbf44/v987 and
its reference average87.069667s. Both pairedv993 and the revised-scope rawv992
fresh confirmations failed performance and were restored; no timing retries.

## Native source opportunity

RandomMapGenerator.lua1684-1689 computes GridOr(place,dist,bounds), then in-place
GridDistanceMars(dist,1,1). At1708-1710 it separately computes
GridDistanceMars(place,bounds_zone,1,1) for weighting during the same placement
epoch. Bounds is fixed; successful placement changes place at1742 and causes the
primary field to be rebuilt. Hypothesis: retain D(place) per placement epoch and
D(bounds) per procedure; construct D(place OR bounds) with native GridMin, then
copy the same D(place) to each ordinary secondary destination before weighting.

Primary GridOr and both distance outputs are separate observable boundaries and
must remain exact. Do not skip the original raw union output or mutate the cached
distance during subsequent masks/weighting. Keep every seeded pick, weighting
operation, candidate/rejection and placement write in original order.

Native grid minimum form is GridMin(source,destination,reference), established
by primary CommonLua/Libs/MapGen/GridOps.lua2878. Actual prefab packing is U16
(RandomMapGenerator.lua8,1029-1032); the scratch probe explicitly verifies16.
Earlier profiling measured ALL Playable transforms at1.152s reference/.563s61N.
Only part is avoidable, while minimum/copy/guard work replaces it. No multi-second
claim or expected startup gain follows from this opportunity.

## First native scratch experiment completed

playable_distance_contract.lua/.py at e7b2ad3a7d4ed671016d2d928ea5225a58b17c14,
execution12396 CLOSEDexit0; PID60272, creation134337891252903299. Mapless hidden
owned process closed normally with flushed logs and no errors. Contract audit
PASS issues empty in artifacts/playable_distance_native_contract. The capture
helper's 'failure evidence' wording is its failed=True mapless mode, not failure.

All12 cases match D(A OR B)=GridMin(D(A),D(B)) on every cell: opposite corners,
coincident seeds, disjoint and overlapping circles, edge frame, checkerboard,
sparse128x128, full/full, empty/empty, empty/corner, corner/empty, actual768x768
frame/circle.616448 comparedcells;96 owned allocations/all96freed. Raw OR and
native minimum outputs independently checked; source fields compared against
independent native clones and binary inputs unchanged. Both all_cases_hold and
all_nonempty_hold true. No RNG, game map, production hook or source mutation.

This is finite scratch evidence, not proof for every native input or a generation
parity/timing sample. It qualifies the next actual-map shadow; it does not justify
production integration or startup claims on its own.

## Next decisive work

Use the existing native procedure observer, scoped to actual Playable. Track the
first GridOr place/bounds lineage and every original positive place-circle write.
Retain fixed-bound and mutable-place guards; refresh the private D(place) after
each actual placement epoch. Compare every native primary and secondary distance
output in full, at its original return boundary, without changing real outputs.
Check guards before native frees, preserve full native tuples and source/thread
lifetime. Require full predecessor/private/individual-rock/process audits.

Record a bounded operation journal and replay old/new in both orders, charging
all required raw union operations, transforms, minimums, copies, initialization,
place writes, allocation and cleanup. Do not infer savings by adding overlapping
wall spans or ignoring the candidate's extra minimum/copy work. Only positive
full-work replay plus exact actual-field parity permits supported-owner integration
and a new fixed cold confirmation under the current reference-average goal.
