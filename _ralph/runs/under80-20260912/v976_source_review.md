# v976 native crease predicate certificates

Native discovery already computes exact signed U16 differences and both flank
predicates in float32: every intermediate is an exactly representable integer.
This candidate preserves a signed clone, doubles/biases/masks it, then enumerates
the accepted sign and jump. Rejected zero and minimum accepted two leave a gap
under both possible native lower-bound conventions. Existing independent native
count, coordinates, bounds, duplicates and cleanup checks remain; invalid encoded
parity/range fails explicitly. Three 17-bit width slots fit in 51 exact bits.
The existing per-row seen dictionary holds the words; position and width order
are unchanged. Scratch native engine probe passed2560 complete position/word
comparisons; offline inclusive/exclusive mask oracles passed5120.

Discovery decodes only certified widths, applying the original edge direction
and offer order. Refinement uses them only when the existing guide proves the
entire influencing neighborhood unchanged. Same-axis and crossing writes still
invalidate reuse and take the original live scalar path. The literal predecessor
scalar paths remain available when no certificate exists. The new regression
compares actual production offer and refinement branches against v975 over205096
checks, including width/sign/boundary/tie/51-bit packing cases. Existing track
write/ordering/translation/join oracles are unchanged, except added guide tests.

No RNG calls, parameter changes, new map conditions, joins, track ordering,
terrain writes, passability/rebuilds, readiness/T1 gates, entrances, resource/pad
plans, individual rock support or temporary UI buttons changed. Guard291 and
metadata976 identify the new captured closure. Offline and cold acceptance are
separate requirements; no speedup or complete correctness claim until captured.

Scratch attempts1/2 had diagnostic setup errors (the engine's assert does not
return its operand, unlike stock Lua, and creating a global needs rawset). Both
owned processes exited normally, with their failures retained. Attempt3 uses
explicit error checks and rawset, passes without Lua errors/assertions and exits
normally. Scratch probes are not benchmark samples or new map visual evidence.
