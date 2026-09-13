# Whole-cell positive obstruction certificates (private research)

Baseline accepted56fbf44/v987, evidence checkpoint3b8feba. Previous goal turn made
verified progress, not completion: reference86.606s, worst61N92.125s. Deployment
38/38 and no live game were confirmed before this investigation. No production
file, metadata, deployment, test harness, settings or other mod is changed.

This is not the rejected expanded-radius index or last-hit hint. Keep the literal
accepted circle index, additionally returning its winning immutable circle. After
32 queries, a private4096-unit cell can learn a minimum radius only if its complete
padded box lies strictly inside that circle expanded by the floored query radius.
Subsequent points in that cell with at least that radius return true without another
distance predicate. All other cases run the full original index. No negative
answer, candidate, cursor result, random draw, rejection order or quota is cached.

Qualification: finite query/circle coordinates within+/-2^24; query radius0..65536,
circle radius0..2^24. Pad cell endpoints by1, round maximum corner deltas outward
with ceil()+1, require deltas<=2^25, and shrink floor(circle radius)+floor(query
radius) by1. The integer squared comparison is exact in signed64 and binary64.
Conditional rational bounds cover corner calculation, old scalar strict predicate
and original index bounding endpoints. No approximate sqrt is used. Unsupported
inputs take the old query; a32768-cell storage cap bounds memory, never work.

Positive certificates survive append-only lists because they refer to immutable
circle geometry. Run creates the private arrays/records at decor lines392..435 and
only appends records at639..641; no mutation/removal/cross-Run sharing. Cache misses
catch up the accepted lazy index. Existing records may lower their radius at cap.

Offline54581 separate-index old/new/exhaustive comparisons PASS, including1601
certified answers, strict tangencies, fractional/negative coordinates, cell/radius
boundaries, appends, independent list lifetimes, memory cap and numeric refusals.
The exact-Fraction bound script PASS is a conditional arithmetic argument, not
exhaustive evidence about arbitrary engine behavior or a performance result.

Native shadow clones only Run and joins its private cells. Old and new queries use
SEPARATE private index state, with the same immutable circle records and append
sequence. Both execute for every real call; the original result alone controls
the game. Timings include each query's own index/certificate construction. The
wrapper records certified/full query counts and restores Run at the existing
scheduled surface revalidation. Full predecessor/private/final/rock parity and
normal owned process shutdown are mandatory. Native effectiveness is pending.
