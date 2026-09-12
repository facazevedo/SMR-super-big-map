# v980 guarded class-list negatives and whole-domain apron bound

Baseline c4d3e67 (accepted v979), runtime 980 / generator guard 295. Only Engine,
ObjectClone and the apron raster change, plus version/guard. No other production
files, game binaries/settings, dependencies or debug/elevator buttons change.

## Class queries

Engine.FirstKindOf can prove a list negative in one protected native call. The
named IsKindOf/IsKindOfClasses functions must both qualify as native via standard
string.dump's checked Lua-success/C-failure protocol. Mod debug stays blacklisted.
Captured native identities, Engine.IsKindOf, Engine.SafeCall and the caller's
captured scalar helper must still match live sandbox rawget lookups on every call.
No class/object/map query result is cached. Missing/custom/rebound helpers and
failed native queries retain the original ordered scalar loop. Positive native
queries also use that loop, preserving the FIRST matching class and scalar value.
Successful native false OR nil means false in canonical Engine.IsKindOf.

ObjectClone changes only existing ancestry lists in mystery/access/resources/skip
classification. Names, validity, parent/entity access and order remain unchanged.
Name-based ObjectScalesWithTerrain is deliberately unchanged. An older/custom
Engine table without FirstKindOf uses the original ordered scalar fallback.
RockGrounding's accepted immediate identity-qualified reuse remains intact; all
geometry, support rays, individual grounding and placement code is unchanged.

The full-module predecessor fixture passes 667222 exact return/non-class-query
order checks across native nil/false, missing/malformed qualification, missing API,
custom hooks, live rebinding, failed batch calls and missing helper. Existing
engine_primitives fixture now excludes ONLY the added helper block from its
inherited source invariant and clears initialization traces before hot-method
comparison; it still executes the complete module and checks all original method
results/runtime traces, live rebinding/errors and 2/1 primitive lookup counts.
New helper initialization/qualification is independently covered by class_batch.

Nondeployed native class_batch_profile_reference_3 passed exact full predecessor
terrain, placements, individual-rock and private streams, zero failures, owned
PID 32056 normal shutdown. Qualified pair true, two shared classifier upvalue
cells replaced, 163834 batch calls / 163550 negative shortcuts / 482 scalar calls.
Surface annotation 1434ms and underground 600ms are instrumented diagnostics,
NOT cold acceptance. Earlier failed setup and zero-shortcut measurements remain
preserved and are not relabeled passes; see classification_batch_research.md.

## Apron certificate

Retain the existing domain, coordinate construction, nonlinear residual checks,
literal scalar oracle, plane arithmetic, four-H-unit reserve and exact rounding
correction. Tighten only the bound implied by native_mask_bound.md:

    E(c) = 1.875 * (12e-6 + 7e-6/c)/(1-c) + 16e-6

Since (12+7/c)/(1-c) = 7/c + 19/(1-c) is convex, endpoint maxima suffice.
On [0.20,0.60], E <= 126.9375e-6 < 9/65536.
On [0.60,0.75], E <= 176e-6 < 12/65536.
Exact rational checks also cover actual binary endpoints. Choose numerator 9
for core <= 0.60, otherwise 12. Both upper-weight and cubic terms use that SAME
bound: integral U24 allowances 2304/3072, integral native arguments 27/36 over
65536. Outside the existing certified domain the original scalar mask remains.
This derives the smaller bound; it is not empirical removal of a safety margin.

Offline f32 raster compares old/new/literal over 38115 cells: exact, 21 cases
with fewer ambiguous cells, no case with more. Revised native scratch compares
523776 cells across 33 cases, including both branch/domain endpoints and outside
fallback, zero mismatches in all three comparison categories, normal PID 41884.
Native full shadow PID 43784 records actual core 0.2 / numerator 9 and passes
complete height plus predecessor/individual-rock/private-stream parity:
808696 -> 576132 exact corrections, unchanged 50 shaped / 1910302 modified.
2122ms vs 3320ms is ordered diagnostic timing, NOT cold acceptance evidence.
Both full probes preserve flushed logs and owned normal shutdown.

## All-ten-rules review boundary

No RNG calls or sequence changes, traversal changes, gameplay quotas, coordinates,
terrain approximation, passability/buildable rebuild removals, transaction changes,
deferred work, START/T1 changes or scheduled postpipeline revalidation changes.
Shared RNG source paths and private draws remain identical. Exact full terrain,
pass grids, sites/pads, placements and individual rocks must match predecessor.
Visual equivalence is inherited only through complete exact outputs, not a claim
of newly captured screenshots. Require 79 offline commands and one immutable
reference-three/control/five-site cold suite, all ten correctness rules, unique
owned normal shutdowns and deployment 38/38. Target remains <80s at all six sites.
