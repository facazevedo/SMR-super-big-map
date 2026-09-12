# Next exact candidate: retain native crease predicate certificates

Not production; pending v975 full acceptance. Research decoder passed205,096
offer/winner/51-bit packing comparisons with the current literal scalar bodies.
This is not native engine proof or a performance claim. The native discovery filter
already proves the U16 jump threshold and both doubled flank bounds, at widths1..3.
Current Lua discovery/refinement rereads cells and repeats those same predicates.
All intermediate differences, twice-flanks and masks are exact integers in f32.

Proposed representation: encode signed jump as delta+65536 (1..131071 for a
nonzero qualifying jump), zero for an absent width. Pack widths1..3 in three17-bit
slots, at factors1/131072/17179869184. Maximum word is2^51-1, exact in both engine
int64 and ordinary Lua binary64. No approximate joins or terrain changes.

BuildHeightStepDiscoveryIndex can preserve signed b-a before abs, bias/mask that
native grid, and enumerate encoded signed jumps with the existing exact count and
coordinate/duplicate checks. Double each biased code before native enumeration:
accepted values are2..262142 and rejected values0, so the existing lower bound1
is safe for either inclusive or exclusive native filters (code1 must not be lost).
Validate parity/range before halving to the17-bit stored code. Replace each current row_seen[along][perp] boolean
with its packed word. Keep the current returned ordered position rows and stats
unchanged; return the packed row_seen as a third result. No per-step Lua tables.

collect_axis receives before/after certificates along with the original rows.
scan_line_range can use certified widths/jumps/directions in the same position,
width and offer order. Original scalar path remains for calls without certificates.
Store certificates beside rows in the existing refinement guide. Only return them
when its complete-domain and same-/cross-axis write checks pass. Indexed refinement
then ranks exact certified widths with the original direction/distance/jump/tie
rules; overlapping prior track writes still use the current live scalar path.

Research decoder is `_ralph/tmp/under80_20260912/certified_steps.lua`. Required
before production: exhaustive width/sign/boundary and randomized offer/winner
oracles; native full-position/packed-record differential tests; existing failed API,
lost/duplicate callback and track-write invalidation tests; full cold predecessor
parity, untouched joins/translation order, three timing samples and five-site gates.
Do not infer a speedup yet. Keep production/HEAD fixed during v975 reference runs.
