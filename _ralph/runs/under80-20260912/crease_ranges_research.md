# Consecutive indexed crease positions

Production is restored accepted v979 at 8af568f after rejecting v980's slower
cold median. Do not interpret the preceding diagnostic's exact work reduction
as cold acceptance. v980_crease_phase_reference passes full exact output and
identifies destination discovery/tracking 2068ms, of which native discovery is
644ms; total destination repair 3390ms. Source repair is only242ms. Native class
qualification/public/captured identities all match: an inactive fast path does
not explain v980's cold result.

The native discovery index returns sorted unique perpendicular positions, but
collect_axis currently calls the already-rolling scan_line_range once per
position. Consecutive positions reread five of six overlapping samples at the
destination (three of four at the source). Group ONLY consecutive positions into
inclusive ranges and invoke that exact existing scan. Do not bridge gaps, alter
width/edge order, change offer/tie sorting, qualify extra positions, cache a
height outside the read-only discovery phase or touch refinement/write code.
No native packed decoder, wider terrain region, approximation or RNG change.

crease_ranges_candidate.py reads fixed accepted c4d3e67 and generates an isolated
fingerprinted artifact; it does not edit/deploy production. The only rewrite
adds scan_indexed_ranges and replaces the two singleton loops in collect_axis.
The existing rolling scan, native index, refinement/invalidation and joins are
unchanged. Fewer empty-row allocations are incidental; no persistent cache.

crease_ranges_test.lua executes the actual offer and scan functions with both
edge orientations, wide/destination widths, threshold/noisy/cliff/flat/nil-boundary
data, all256 subsets of eight neighbouring positions, empty/singleton/gapped/
consecutive/duplicate/descending lists and changed terrain on the next call.
263494 exact offer/read-coordinate checks PASS. Native-read model313040->195888,
scan calls62608->33320. These fixture counts are not a game loading-time claim.

crease_ranges_shadow.lua recompiles ONLY the one changed repair function and
joins all its original upvalue cells. Accepted function writes the live grid;
candidate writes a clone of the same input. Compare every U16 height via exact
f32 differences and all returned reports/tracks/stats. Preserve accepted output
even on mismatch; never hide a failed diagnostic. Per-range instrumentation
checks every indexed position is still visited. The old/new get-call formulas
are derived from the unchanged rolling function, not direct native getter hooks.
Diagnostic counters/timing hooks are not production.

Full native shadow29448/PID31080 is currently running at fixed8af568f with
deployment38/38. No native verdict, cold gain or promotion yet. If exact outputs
and actual read reduction pass, a single isolated production candidate still
requires all inherited offline tests and fresh cold acceptance against v979.

Native shadow29448 closed exit0, PID31080 normal captured shutdown. All complete
predecessor surface/underground terrain/pass grids/placements/private streams/
individual-rock outputs PASS. Both repair calls have identical return records
and zero different U16 heights. Source287 positions remain287 singleton ranges:
read model1148->1148, accepted298ms/candidate193ms. This unchanged-work timing
delta demonstrates why ordered shadow elapsed times are NOT cold acceptance.
Destination171387 positions become35342 ranges: read model1028322->348097
(680225 fewer), accepted4080ms/candidate3426ms including candidate counter calls.
All positions, native index stats, tracks and writes remain exact.

The diagnostic uses accepted output for downstream work, so its START-to-T1
is never the candidate's cold time. Production is still byte-identical to c4d3e67,
runtime979/guard294; deployment38/38. No owned game remains. Next: consider this
single isolated change as v981, add its regression to the77 inherited commands,
review/bump the generator guard, commit/deploy, and perform immutable reference3/
control before any five-site sweep. Do not automatically reintroduce v980's two
rejected combined changes or use their diagnostic timings to justify it.
