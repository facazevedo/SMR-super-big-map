# Under-80-second optimization, 2026-09-12

User requested implementation after the feasibility assessment. Target: reference
14N134W and five existing validation scenarios below 80 seconds, measured from START
through required surface post-pipeline revalidation. All current rules, geometry
corrections, seeded placement, individual rock support, and temporary buttons stay.
No automatic Ralph process is running. Primary agent owns this investigation.

Starting HEAD fe39258, clean production worktree; runtime is accepted v972/guard288
(67fa4ab), 38/38 deployed files match. Accepted reference median 102.488s; 61N136W
150.018s. Old experiment artifacts remain unchanged. New evidence lives here.

Initial diagnostic `v972_profile_reference`: old setup returned PROFILE_ERROR
because source anchors did not match CRLF text. No replacement source was executed;
the driver continued generation. Preserve capture/parity and normal shutdown, but
do not call this an instrumented profile or mix it into declared timing acceptance.
New setup normalizes line endings and times source/destination creases and natural
aprons, in addition to the existing rocket/raster splits. Fresh successful profiles
of the reference and 61N136W are next.

Rejected earlier work to respect: exact dirty-region union reduced regional calls
but did not establish end-to-end improvement; final rebuild deferral broke read
dependencies; float32 crease joins differed in rounding. No blind reuse of those.

## Decor obstruction index candidate v974

Code checkpoint `2c68ff3`, runtime v974/guard288. Private append-only obstruction
circles use a spatial hash; the old strict intersection predicate, candidate order,
rejection precedence and random draws are unchanged. All 71 offline regressions
pass (`artifacts/v974_offline`). Deployment audited 38/38.

First uninstrumented 61N136W run: 108.707s versus accepted v972 150.018s, an
observed 41.311s reduction. Exact predecessor grids, placements, rocks, private
streams and eight automated gates pass; the owned process exited normally.
Its decor stage took 9.778s; fresh v972 diagnostic decor took 54.680s. These are
single samples, not an established timing median. Under 80s is NOT reached.

Successful v974 reference diagnostic preserved exact outputs and closed normally.
Captured upvalue timers locate destination crease repair at 7.129s, natural
aprons at 8.056s and outer terrain raster at 7.190s. Nested stages are not additive.
The native function profile also completed with exact output parity and a normal
exit. Its reports are in `artifacts/v974_function_reference`: destination crease
repair made 9,891,316 mod-environment lookups; outer terrain made 10,106,912.
Each lookup traverses ModEnvMeta.__index/rawget. Profiler timing includes overhead
and is not an acceptance sample. Apron weight arithmetic is a separate hotspot.

Reference samples: 106.491 / 104.523 / 105.174s; median 105.174s versus recorded
v972 102.488s. Native control 28.649s. All exact predecessor/repeat comparisons and
automated gates pass; four fresh processes exited normally. This is NOT evidence
of a reference speedup: the observed median is 2.686s slower. The large 61N gain
and this reference result must be reported separately, without selecting samples.

Matrix completed: 15S67E 106.689s, 24S74W 105.515s, 45S120W 101.427s,
61N136W 108.707s, 17S11W 107.850s. All exact predecessor/gates pass and normally
closed. Source/RNG review is in `v974_source_review.md`; `review_v974.py` closed
all ten rules/five scenarios in `artifacts/v974_all_ten_rules_review.json`.
All nine acceptance processes are distinct; deployment still audited38/38.

Next candidate: five entry-scoped standard-library bindings in terrain helpers.
Non-deployed candidate and literal-body certificate are in `artifacts/binding_research`.
Focused test: 3,500 exact fixture comparisons; math lookups 29,612 -> 8, with
between-call library rebinding preserved. Candidate parses. The v974 matrix is
closed; production can now advance to the next isolated checkpoint.

## Terrain standard-library bindings v975 (checkpoint 1f67811)

Runtime v975/guard290, deployed and audited38/38. Exactly five entry-scoped
declarations in the terrain module; arithmetic and call order are unchanged.
All72 offline commands pass. Source review: `v975_source_review.md`.

Fresh reference samples99.851 /97.892 /97.914s; median97.914s versus fresh v974
105.174s: reduction7.260s (6.90%). Native control30.817s. Complete predecessor and
repeat outputs, original gates and normal shutdown all pass (`v975_reference/reference_audit.json`).
Five-site `v975_matrix` completed against v974: 102.317 / 100.171 / 94.862 /
104.302 / 102.034s in manifest order. All exact outputs and eight automated gates
pass. Primary source/RNG/process review closes all ten rules; nine distinct
acceptance processes exited normally. `v975_all_ten_rules_review.json` records
the complete review. Production checkpoint is accepted; the batch is closed.
Under80s is still not reached; do not mark the optimization goal complete.

Non-deployed next research: packed exact native crease certificates. The prototype
passes205,096 offer/winner/51-bit packing comparisons; native production integration
and real-engine validation have NOT been done. See `native_certificate_research.md`.

## Native crease certificates v976 candidate

Production integration completed, runtime976/guard291. All74 offline commands pass
(`v976_offline`). Actual native-grid scratch comparison passed2560 checks;
offline inclusive/exclusive lower bounds passed5120; actual production offer/winner
branches matched v975 over205096 checks. Invalid certificates fail explicitly;
guide propagation and write invalidation tests pass. Source review in
`v976_source_review.md`. Cold output and performance acceptance still pending.

## v976 rejected; v975 restored

v976 checkpoint `f42aaac` reference97.517 /97.146 /97.183s; median97.183s,
native control28.667s. Full predecessor/repeat/control comparisons and gates pass;
four owned processes exited normally. Reference audit has no issues. This is only
0.731s (0.75%) below v975, too small to justify the extra native buffers, packed
metadata and conditional decoder complexity. All samples preserved. No five-map
v976 sweep was run and no all-ten/five-site acceptance is claimed for v976.

Restore only production and the guide test to accepted `1f67811` (v975/guard290).
The two new candidate-specific regression files move into this run's research
folder and default to its non-deployed candidate source; evidence and candidate
commit remain recoverable. Do not resurrect v976 as an accepted optimization.
The fresh restored72-command offline replay passes in `artifacts/v975_restored_offline`.
Production matches accepted `1f67811` exactly; final deployment must audit38/38.

Under80s is NOT achieved. Accepted reference median97.914s; five sites102.317 /
100.171 /94.862 /104.302 /102.034s. Overall recorded v972 reference102.488 ->97.914
(-4.574s,4.46%); slow61N150.018 ->104.302 (-45.716s,30.47%). The slow-map
comparison is single samples, not a reference median. Full v975 validation remains
`v975_all_ten_rules_review.json`; inherited visuals require exact restored payload.

Next substantial unimplemented avenue is the remaining scalar apron/outer-mask
arithmetic (roughly8s and7s respectively in the pre-binding diagnostic stages), possibly native
arithmetic with rigorous error brackets and exact ambiguous-cell correction.
Native trig/reciprocal/precision behavior has NOT been proved for such a port.
Do not approximate shapes, weaken readiness, defer rebuilds, or claim this will
necessarily reach80s. Existing immediate and post-pipeline rebuilds are required.

## Native apron-mask research continuation

New non-deployed prototype now has evidence worth pursuing: native scratch math
API verified with integer fixed-point arguments;211848 mask samples measured;
317440 three-way final U16 comparisons and15414 offline checks pass. A full fresh
reference shadow run compares candidate/accepted algorithms on identical grids:
2663ms versus7591ms, zero differing full8192x8192 height cells, complete predecessor
output parity and normal shutdown. See `native_mask_research.md` and artifacts
`native_mask_shadow_reference`, `native_apron_probe_1`, `native_mask_probe_1`.

This is diagnostic-only, not deployed or accepted. Production remains exact v975.
Before promotion, prove the error bound across the full allowed input domain,
guard added allocation failures, clarify work counters, and run all cold/gates.
The80s goal stays active. No game process remains after this continuation.

## v977 certified apron-mask candidate

Strengthened native coordinate construction removes interpolation assumptions;
runtime whole-grid sqrt/reciprocal residual checks support the documented error
bound. Original scalar mask handles numeric domains outside the certificate;
native failures stay explicit.317440 native final-cell comparisons,15414 existing
raster checks,16170 domain/core-endpoint cells and221 failure/ownership checks pass.
Fresh strengthened shadow:2728ms versus7602ms, full8192x8192 grid identical,
complete predecessor outputs identical, owned process normally closed.

Production v977/guard292 integrated; full74-command `v977_offline` passes.
Next: commit, deploy/audit38, fresh `v977_reference` (three plus control), audit
against `v975_reference`, then `v977_matrix` against `v975_matrix` and final
`review_v974.py --version 977`. No change to HEAD/production while a cold batch
runs. Still not accepted and not under80s. Source/bound reviews are in this folder.

v977 code checkpoint `b5fb059`: fresh reference94.353 /93.635 /93.610s,
median93.635s versus v97597.914s (saving4.279s,4.37%). Native control29.748s.
Complete predecessor/repeat/native-control audit passes with no issues; four
distinct owned processes exited normally. Next is five-site `v977_matrix` against
`v975_matrix`. Keep HEAD at `b5fb059` until the whole version's acceptance closes.
No under80s or full five-site acceptance claim yet.

During the closed-reference interval, a scratch-only outer harmonic probe tests
an uninstalled complex-power approximation to repeated trigonometry. Files
`outer_harmonic_research.lua`, `outer_harmonic_probe.lua`, `outer_mask_research.md`
remain research; exact coarse-mask rounding/protection proof would be required.

v977 five-site matrix is live in exec session83806 at unchanged `b5fb059`.
Poll the handle to establish live/terminal state; do not infer it from ACTIVE.json.
No second game or HEAD/production/deployment change until it closes. Reference
batch10667 has a captured terminal exit0 and complete clean reference audit.

Outer harmonic scratch attempt failed because math.atan2 is absent. A separate
fresh probe confirms the mod and global math tables are identical, atan2 nil,
atan available and sin a native C function. Existing outer masks therefore use
angle0. Do NOT replace this fallback with atan: that changes terrain. Next useful
hypothesis is exact per-patch caching of the angle0 sine combination; details in
`outer_mask_research.md`. Both diagnostic processes closed normally; the failed
attempt remains failed evidence. Research files/notes are uncommitted solely to
keep v977's acceptance checkpoint unchanged.

## v977 accepted, all batches closed

Session83806 exited0; all five exact predecessor comparisons and normal owned
shutdowns passed at unchanged b5fb059. Times in manifest order:98.444 /94.162 /
90.365 /96.761 /94.691s. `v977_all_ten_rules_review.json` closes all ten rules,
74 offline commands, nine unique acceptance identities and deployment38/38.
Reference median93.635s versus v97597.914s. No under80s claim; goal remains active.

Non-deployed zero-angle cache passes86,905 exact coarse/domain/lifetime checks.
Missing-atan2 sine calls62892 ->648; present-atan2 path62892 ->61002. Candidate
and fresh diagnostic setup parse. Next diagnostic installs only the candidate
outer helper in its owned process and profiles the separate transferred-relief
capture hotspot. Production remains v977; diagnostic timings are not cold samples.

## v978 Lua helper/cache candidate

Closed diagnostics: zero_harmonic_profile_reference_3 exact full predecessor and
individual rocks PASS; outer stage3521ms. Relief function profile exposes5,486,204
mod-environment lookups and1,195,943 IsKindOf helper calls. Prior setup1 used a
nonexistent predecessor directory (no process); setup2 failed on a main-menu-only
missing installed wrapper and normally closed PID48300. Corrected setup hooks the
factory's captured helper; successful PID14476 normally closed.

engine_primitives_profile_reference snapshots only type/pcall in an isolated
engine-module diagnostic proxy. Full predecessor parity PASS, T1=87.978s,
relief3629ms; PID18696 normally closed. Production uses the equivalent lexical
binding, not that diagnostic proxy. No game functions are cached.

v978/guard293 integrates the two measured changes.172114 primitive result/trace
checks and86905 exact outer-mask checks pass. Full76-command v978_offline is live
in session92568. After it closes: commit code/tests/review, deploy sync+audit38,
measure v978_reference against v977_reference, then v978_matrix against v977_matrix,
and review_v974.py --version978. Preserve one HEAD across all acceptance processes.
Under80s is not established; the goal remains active.

v978_offline session92568 closed exit1:75 commands passed; static outer_policy
expected a combined `local harmonic =` declaration. It now checks the three
unchanged sine terms rather than declaration formatting. The failed artifact is
preserved. Full rerun will be v978_final_offline, used by the v978 review script.

v978_final_offline session60159 closed exit0: all76 commands pass. Production and
tests are ready for the committed cold checkpoint. Next reference output directory
is v978_reference; use v977_reference as predecessor. No live game remains.
