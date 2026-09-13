# Astra extra-high optimization review

Requested by the user; reviewed with `gpt-6-astra`, reasoning effort `xhigh`.
Read-only review of accepted v983, rejected candidates, native diagnostic evidence,
and the current source. No proposed speedup below is a cold-run result.

Current reference median: 90.244 s. Target: <85 s. The historical five-site v983
baseline has not been refreshed. Preserve previous result labels and all samples.

## Ranked alternatives

1. **Native outer coarse masks with exact rounding correction.** The scalar loop
   previously took 2,675 instrumented ms over 948,237 samples, including 422,144
   transition weights. This targets the complete kernel, unlike v985's rejected
   enclosure reduction. Native allocations, protection masks and correction cost
   reduce the possible gain. Shadow every U12 mask cell before resampling, then
   compare complete final terrain in both execution orders. Preserve the existing
   zero-angle harmonic behavior and protection products exactly.
2. **Collection-only native crease offers with a simpler representation.** The
   destination scanner cost 1,374 instrumented ms over 171,387 calls. Discovery
   already computes accepted widths and signed jumps. Retain original ordering,
   boundary scalar fallback and write invalidation. Important: rejected v976
   already retained signed packets, packed three widths and reused certificates
   in refinement. Packet retention itself is not new; this experiment must prove
   cheaper representation/allocation and keep its narrower collection-only scope.
3. **Whole-cell positive obstruction certificates.** On 61N, 775,867 circle queries
   cost 2,727 instrumented ms. Certifying a cell wholly inside an expanded circle
   could answer an exact positive without repeated distance tests. Measure coverage
   against construction/lookup cost. Preserve all cursor calls, rejection precedence
   and RNG draws. This mainly addresses worst-site time: reference decor was only
   410 ms in one existing diagnostic. Distinct from v984's last-hit hint.
4. **Relation-first passage dependant classification.** `build_dependant_index`
   classifies each CObject for each anchor before checking whether it references
   that anchor. Qualify only related objects, or once per object, after proving
   predicate purity and failure behavior. Preserve per-anchor append/move order.
   The old profiler's 1,349 ms maximum span is intrusive, not a current cold ceiling.
   New temporary logs measure this helper with existing object/match/anchor counts.
5. **Stronger adaptive apron error certificates.** Q22 still needs 396,398 scalar
   corrections over 5,039,674 native cells. Census uncertainty causes before trying
   tighter verified root/reciprocal bounds or local propagation. More coordinate
   precision alone leaves other error reserves. Keep all mandatory checks and the
   exact scalar correction whenever the stronger certificate is inconclusive.
6. **Hoist immutable indexed-refinement operands.** `sample(perp-1)` and
   `sample(perp)` repeat inside each width iteration. The entire indexed helper was
   560 instrumented ms, so this is a modest opportunity. Compare full winners/ties
   and preserve every live-read and invalidation rule.

## Recommended order and limits

Finish sparse diagnostic verification, then refresh the unchanged five-site
baseline with probes OFF before testing genuinely new candidates. Prioritize the
outer-mask private shadow and passage classification census. A crease-only change
cannot credibly account for the entire remaining 5.244-second reference gap.

Keep all required pass-edit resumes, immediate rebuilds and scheduled revalidation.
Their approximately 15-16 seconds are substantial, but existing experiments do
not justify skipping them. Nested intrusive profile spans are not additive.

The inspected `FunctionProfiler.txt` was a 0.353-second snapshot reporting 96.5%
slowdown, dominated by asset/hex initialization. Its absolute times cannot estimate
current full-map expansion savings.

See `native_crease_offers_next.md`, `v976_source_review.md`, `v984_source_review.md`,
`v985_source_review.md`, `v986_source_review.md`, and the retained diagnostic artifacts.
