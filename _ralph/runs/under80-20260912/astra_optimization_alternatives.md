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

## Latest follow-through: collection-only offers tested as v988, not promoted

The second alternative passed88 offline checks and full forward/reverse native
repair shadows with exact104857600 cells each. Immutable dc88950 then passed full
reference/five-site correctness in nine normally closed owned processes.
Reference median84.919s improved onv98786.606s, but three of five sites regressed:
15S+0.474s,24S+0.276s,17S+0.050s.45S improved0.814s and61N0.417s; worst91.708s.
Candidate not promoted; acceptedv987 restored and38-file deployment audited.
See v988_source_review.md for every sample and preserved counterevidence.

Third alternative positive-cell certificates remains private: revised prototype
saves719..1007 diagnostic ms on61N but adds15ms on the reference's small workload.
Generic workload/reuse admission needs independent proof and measurement before
any integration. Do not combine or cold-repeat unchanged rejected candidates.
The all-site sub85 target is still unmet; neither diagnostic gains nor a reference
median below85 imply consistent startup below85 across the validation matrix.

## Workload-admitted positive-cell follow-through: v989 not promoted

A genuinely new4096-full-query admission gate removed unused reference cache
learning and retained716..763ms diagnostic61N savings in both orders. All four
native shadows,87 actual production checks and nine cold correctness processes
passed. However, coldv989 reference86.520s was essentially flat versus86.606s;
61N improved0.651s while15S/24S/45S/17S regressed1.797/0.091/3.585/0.894s.
Candidateb130478 NOT promoted; acceptedv987 restored/audited, all evidence retained.
See v989_source_review.md. The next larger remaining all-map lead is stronger
adaptive apron bounds, not unchanged rejected-candidate cold repeats.

## Follow-through: first alternative accepted as v987

The native outer-mask alternative passed all83 offline checks, six-site exact
mask shadows, integrated native tests and the complete cold correctness matrix.
Accepted production56fbf44/v987: reference median86.606s versus freshv98390.244s;
all five declared fresh comparisons improved. Worst remaining site61N136W92.125s.
The full <85s goal is not reached. Detailed times and limits are in
v987_source_review.md; full cold evidence is retained under artifacts/v987_reference
and artifacts/v987_matrix. Isolated kernel timings were smaller than some total
gains, so do not claim exact causal attribution of the full observed difference.

The historical five-site limitation above was resolved before this candidate by
an unchanged-v983 confirmation, without overwriting earlier results. Future work
uses the new accepted v987 evidence. Whole-cell obstruction certificates are a
relevant next private investigation for61N; they are not implemented or proven.

See `native_crease_offers_next.md`, `v976_source_review.md`, `v984_source_review.md`,
`v985_source_review.md`, `v986_source_review.md`, and the retained diagnostic artifacts.

## Latest adaptive-bound follow-through: v990 not promoted

The first stronger global apron certificate passed 87 actual offline checks,
both-order complete native raster comparisons, and nine cold correctness runs.
Reference median was 85.048s versus accepted v987's 86.606s. Five-site times were
89.314 / 90.117 / 82.044 / 91.773 / 86.390s: two regressions, despite fewer scalar
corrections on every map. Candidate 88ff956 was not promoted; exact accepted
56fbf44/v987 production was restored and its 38-file deployment audited.
See `v990_source_review.md` for the full results, including retained failed tests.

The next distinct lead is a per-cell quintic sensitivity certificate instead of
another global constant reduction. `apron_local_sensitivity_next.md` records the
unproven derivation and required rounding, ownership, native parity and cold gates.
Extra native grid passes may erase the savings; neither this hypothesis nor the
isolated diagnostic improvements establish the all-site <85s target. Current
accepted reference remains 86.606s and worst validation site 92.125s.

## Local sensitivity private follow-through

The new per-cell derivative field now passes nine private checks and both-order
native shadows at86fff28: each67108864 terrain cells exact,148032 primitive
interval endpoints checked, corrections396398->256451. Helper old/new timings
1879/1238ms forward and1893/1228ms reverse. See apron_local_research.md for the
conditional proof, new +1 H reserve, failure coverage and complete process audits.
This641..665ms helper saving warrants actual-production replay and cold testing;
it is NOT a startup result, production promotion or all-site target achievement.

That local candidate was subsequently cold-tested asv991 after88 actual checks.
Nine-process preservation passed; reference median85.319s, but24S/45S/17S recorded
slower times by.128/.007/.457s.15S and61N improved.527/.714s. All maps reduce
corrections with exact outputs. v991 NOT promoted; acceptedv987 restored/audited.
See v991_source_review.md; tiny deltas are not claims of statistical significance.
The next useful investigation is a fresh sparse acceptedv987 pipeline/substage
census (reference and worst61N) before selecting another small helper change.

Fresh accepted-v987 sparse profiles now PASS full output/private/rock/process
audits:134/132 complete spans, no leaked hooks or Config changes. Coarse wall
times show decor419/9617ms reference/61N, passage bootstrap6404/1664ms, destination
crease3936/1572ms. These are map-specific large costs, not additive savings.
Next split bootstrap's native clearance, bridge copy, passage search, resumes and
common-hex planning before selecting a new implementation. See
sparse_pipeline_research.md and artifacts/v987_sparse_comparison. Productionv987
and cold baseline are unchanged; no claimed target achievement.

## Fresh explicit Astra xhigh review after bootstrap split

User requested another Astra extra-high alternatives review. Read-only agent
astra_fresh_alternatives completed, and parent independently checked native
RandomMapGenerator.lua:2850-2866. The strongest new finding is missing pre-logic
procedure timing, not another bridge-copy or cache micro-optimization. Native
ProcStart/ProcEnd exposes eight coarse stages (two ApplyTerrain occurrences)
plus nested prefab-placement phases before OnGenerateLogic. Their costs are
currently hidden inside the source-view7620/7064ms WALL remainder.

Ranked follow-through: (1) partition those phases, then consider exact immutable
preparation reuse only if measured; (2) a distinct fused decor rejection dispatch,
keeping all existing cursor/index/terrain/matcher/RNG behavior; (3) qualified
callback-local reuse of object observations in relief capture. None is a proved
saving. Passage loop splitting is secondary reference-specific work; new2185/61ms
includes search, landscape repair, spawning and clearance. Bridge136/141ms is not
a major lead. See bootstrap_phase_research.md and native_proc_research.md.

All-site sub85 remains plausible to investigate, not established. Slowest92.125s
needs more than7.125s; required native passability rebuilds cannot be skipped or
narrowed. Production unchanged, no new implementation accepted by this review.

Fresh review's first lead now measured: corrected native-proc reference/61N both
PASS full native audits atcf1af4d. UG FindPrefabPos5348/4647ms, including
Playable2149/1062,Filler2116/2479,Base921/857. Raster mark+actual1170/1173ms
(excluding25/24ms overlap removal) is much smaller. Focus the next primitive
census on prefab position selection's grid transforms/masks/allocation/seeded
sampling, not assumed prefab-preload reuse. See native_proc_research.md and
v987_native_proc_comparison_2. Initial setup-identity guard failure retained;
corrected203 fixture checks include legitimate registered lifecycle epochs.
No optimization/cold gain claimed; both timing targets remain unmet.

Primitive follow-through now PASS both native audits at48d23c8. Allocation is
only7/2ms across selected stages: no grid pool. Actual common target is Filler
GridMask870/1012ms (1524/1798 calls); intersections611/719ms remain separate.
Private bounded mask cache now has34939 model checks, conditional on an immutable
source/full-overwrite native mask. Actual source stability, key diversity, exact
native outputs and copies/cleanup-inclusive timings still required. See
prefab_primitive_research.md/filler_mask_research.md; no production promotion.

Private mask-cache native proof now PASS at1e2e07a on reference/61N: every1524/
1798 real request exact against both cache and sentinel native oracle, real and
private source grids unchanged. Five unique keys,5misses/clones,1519/1793hits,
all scratch/hooks restored. Both-order replay867->132ms reference,1010->155 and
1005->148ms61N, including cache creation/copy/cleanup. Not a cold startup result.

Mapless native ABI check additionally proves supported integer calls return only
destination; math.type distinguishes integer/float. Fractional1.5 rejected by
native API, failed first check retained; clean supported checkPASS atf8706a9.
Next actual production integration and full real-source/native/cold gates, not
another allocation-pool or unchanged rejected-candidate retry. See
filler_mask_research.md for source-lifetime, owner bridge and fallback obligations.

Actual production cachev992 followed through:85actualcommands+bothintegrated
nativeauditsPASS, full source/output/RNG/rock/ownershiprestoration. Coldreference
median84.147vs86.606s, but15S/24S/45S slower by2.206/2.089/3.288s,61N/17S faster
by1.418/.879s. Complete nine-process preservationPASS; v992NOTpromoted andexact
v987restored/deployedaudit38PASS. Seev992_source_review.md. Privatekernelwinand
referencegain didnotestablish an all-site improvement or targetachievement.

Nextunexecuted recommendation remains fuseddecor rejectiondispatch. Important
sourcecheck: decor_hotpath_candidate.py alreadyincluded per-Run stdlibbindings
and hoistedhas_get_type alongside rejectedv984hints/cursorchanges. Thosebindings
alone are not a newlydiscovered untested optimization. A new candidate must be
distinct, preservingcirclepredicate/index, candidate/cursor/RNGorder, no_match
precedence, retryablefailedmatching, and everyappend/stampingoperation. Qualify
withbounded exactcompleteoutcome shadows andwholepass timings, not helper-only
or intrusiveper-call totals. Acceptedv98786.606/worst92.125s remainsunchanged.
