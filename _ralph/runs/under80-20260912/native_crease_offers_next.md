# Next larger lead: exact native discovery offer certificates

Research hypothesis only, no code, proof or speed claim. First refresh the current
unchanged-v983 five-site baseline as declared in STATUS.md. Do not rerun rejected
v986 unchanged or silently fold old experiments into a new candidate.

BuildHeightStepDiscoveryIndex already evaluates jump/flank/threshold predicates
on U16 inputs using integer-exact f32 operations (bounded differences, doubling,
mask thresholds separated by integer gaps). It returns only sorted per-row/perp
positions, discarding per-width evidence. collect_axis then rereads heights and
repeats scalar acceptance. Investigate retaining EXACT offers for immutable
discovery/collection only, never for refinement after any terrain write.

Possible native packet representation, requiring proof and actual-engine tests:
clone signed_delta before GridAbs removes its sign. After the unchanged accepted
mask, encode2*(signed_delta+65536)*accepted. Accepted packets are integers>=2,
zeros remain0; a lower enumeration threshold1 makes inclusive/exclusive engine
bounds equivalent. Decode signed_delta=packet/2-65536, jump=abs(delta), low_before
=delta>0; width comes from the current native width pass. Values remain below2^24.
Keep original magnitude GridCount census and validate every packet/coordinate.
Extra clone/native operations and callback payload may cost more than they save.

Keep rows/stats/refinement-guide inputs identical. Store certificates separately
(e.g. third return) and consume in original sorted-perp then width1..3 order, before
edge then after edge, preserving offer collapse/sort/cap, track matching and ties.
No candidate filtering, quotas, changed RNG or skipped native rebuilds. No reuse
across collect_axis/height-write boundaries. No approximate predicate acceptance.

IMPORTANT boundary pitfall: native per-width positions clamp at perp_n-width-2,
but scalar scanning of a position discovered at another width may query outside
that range. Only use certificates where ALL widths' neighboring reads are in
bounds (perp<=perp_n-max_width-2); retain the original literal scanner at boundary
positions. Do not assume undocumented out-of-bounds grid:get behavior.

Need explicit integer/f32 proof for every operation, native packet and whole-grid
differential tests, complete offer/track ordering oracles, ownership/error tests
for added allocations, and fresh full-map parity. Keep lexical operand layout in
timing probes and test both orders. Only then freeze a genuinely new production
candidate for full reference/control/five-site performance and correctness gates.
