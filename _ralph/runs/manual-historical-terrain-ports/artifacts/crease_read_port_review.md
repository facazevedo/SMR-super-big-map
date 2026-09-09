# v960 crease read-window source review

Scope: only scan_line_range and refine_step inside RepairInternalHeightStep.
Every candidate's width order, directional tests, contrast/flank thresholds,
offer sequence, nearest-distance/strongest-jump tie break and sampled-track
validation remain unchanged. No discovery resolution or boundary moves.

Within each contiguous scan, neighboring candidate windows overlap. A source
scan needs four initial samples and one new sample per following position,
instead of four per position. A destination scan needs six initial samples and
one new sample per following position, instead of twelve per position. Samples
live only in local scalar variables: no hash allocation, RNG or cross-call cache.

The scan/refinement body makes no terrain writes and does not yield. Thus sample
reuse is valid within that invocation. Refinement starts a new window every time,
so previous repaired tracks' writes are visible. Empty ranges return without any
sample access. The final position does not prefetch another sample: the union of
read coordinates is exactly the old union, including old out-of-domain nils.

Width selection uses explicit branches, not Lua's and/or pseudo-ternary: a nil
neighbor must remain nil, not be replaced by a farther neighbor. Zero heights
remain valid. Source width remains one, destination widths remain one through
three. The current bounded monotone feather_join is unchanged byte-for-byte,
as are source-qualified repairs, terminal-strip repair and physical guard bands.

The production-block regression compares the original9982d4b functions across
both modes, four edges, six terrain patterns, both jump signs and boundary/middle
positions. It checks offered candidates/order, refined winners, changed terrain
between calls, empty/singleton ranges and reduced sample reads. It demonstrated
the expected repeated-read failure before implementation. The existing edge/join,
terminal-strip, apron, resource and rock tests remain mandatory.

Implementation applied after complete v959 acceptance. All54 established offline
commands pass, plus3,097 crease assertions (including identical coordinate unions),
15,414 native-apron assertions and81,267 rocket assertions. The pre-port red is
preserved as v960_offline/crease_before.json; the passing production run is
crease_sampling.json. The 37-line addition/8-line removal only caches these reads.

Runtime acceptance repeats the fresh14N benchmark/native control and the five
fixed predecessor comparisons with exact complete Surface/UG grids, sites/pads,
grounded rocks and ordinary/private streams. All comparisons passed and the median
improved2.645s; final process/runtime evidence is in v960_SIGN_OFF.md. No new visual
output is introduced in the verified scenarios.
