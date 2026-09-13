# v985: exact outer coarse enclosure

Baseline f4d1da6/v983; production changes only TerrainCopy, generator guard299,
runtime985 and release text. Sector76 and all other modules remain unchanged.
Rejectedv984 decor changes are not included. TerrainCopy must match the
nondeployed outer_enclosure_research candidate exactly after newline normalization.

Zero-fill the full native coarse grid; evaluate only an outward-rounded,
generously padded enclosure of the existing maximum-radius disk. Existing core,
width clamp, angle fallback/cache, direction-dependent width, protection factors,
U12 rounding, dimensions, resampling, native support/core restoration, final
height blend/rounding and dirty-region accounting are unchanged. Private dense
protection arrays use numeric traversal in the same order. No candidates, quotas,
RNG calls, rock support, pass/build transactions or scheduled revalidation change.
All prior terrain fixes and temporary elevator/debug buttons are preserved.

Qualification and numerical enclosure rationale are in outer_enclosure_research.md.
Outside the bounded geometry domain, the original complete rectangle is evaluated.
GridFill is explicitly required; native errors retain the existing patch cleanup
and failure path, not an approximate or silently repaired fallback.

Native shadows before production: reference824d5a1/PID7844 and61N ec4ca93/PID40372
normally closed with full predecessor/private-stream/individual-rock parity.
106 complete native masks/1689008 U12 cells match exactly. Diagnostic old/new
mask totals2904/2432ms and2402/1973ms respectively. These are stage diagnostics,
not cold startup gains. Only the accepted grid reached terrain in those shadows.

Require all80 inherited offline commands plus two actual-source oracles (82).
outer_enclosure compares f4d1da6/production complete coarse blocks (800 masks,
1963334 exact cells); outer_enclosure_patch compares complete patch functions
and U16 outputs and checks allocation/fill failure ownership/no publication and
missing GridFill registration. Existing source-binding and sine-rebinding tests
remain enabled. Offline doubles do not replace full native/map correctness.

Freeze code/version/HEAD/deployment before reference3/control. Declared reference
comparator is the unchanged-v983 confirmation batch:90.449/90.244/90.104,
median90.244 and control28.532. Never substitute the historical86.718 acceptance
batch or discard/rescue samples. A strictly improved reference median permits
the five-site matrix against v983_matrix, with all site timing regressions visible.
Full ten-rule/source/process review is required before acceptance. The user target
is strictly under85 across reference and all five sites, including scheduled
surface revalidation beforeT1. An incremental gain does not establish that goal.

Cold acceptance FAILED at immutable b54df8f. Session18759 CLOSED normally:
reference91.231/89.371/90.542s, median90.542 vs90.244, a0.298s regression;
native control29.317 vs28.532. All four owned processes43080/38988/44936/38464
normally closed with full flushed logs. Exact predecessor/repeat/private-stream/
individual-rock comparisons and automated reference gates PASS; audit issues empty.
No five-site promotion, discarded sample or rescue repeat. The diagnostic stage
reduction did not establish a startup gain. Restore production to acceptedv983
byte-for-byte and remove the two candidate-only production tests; all candidate
source/tests are recoverable in b54df8f and research copies remain in _ralph/tmp.
