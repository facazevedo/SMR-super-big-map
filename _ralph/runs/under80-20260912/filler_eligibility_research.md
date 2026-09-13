# Next distinct lead: mutation-maintained Filler eligibility

Current production accepted56fbf44/v987; guarded rock scalar reuse is rejected
after four whole-phase runs (152/158ms slower). v992 immutable-mask-only cache
is ALSO rejected from its mixed-site cold gate; this is not an unchanged retry.

Actual native source: fpks/ModTools_Src/Lua/RandomMap/RandomMapGenerator.lua,
Proc_FindPrefabPos_Filler1771..1833. Each trial creates remaining_zone, computes
GridMask(distance_grid,radius,max_int,1), then GridAnd with current place_grid.
Zone intersection, similar_apply and native weighted seeded selection follow.
Successful placement clears one circle in place_grid via GridCircleSet(...,0,...).
The radius mask source is fixed, but place_grid changes monotonically after its
initial construction. Keep every original trial/selection/RNG call and order.

Proposed private kernel: own a bounded eligibility grid per admitted radius key,
equal to mask(fixed distance,radius) AND LIVE place_grid. On first use, compute
the complete mask/intersection andclone the result. On each original successful
circle clearing, perform the exact same native clear on EVERY owned eligibility
grid. On hits, copy current eligibility into the normal trial destination; zone,
similarity andstyle work continue separately on that destination. No altered
similarity cache, delayed native writes, skipped seeds or search candidates.
Evicted/new keys initialize from the current live place_grid; no unbounded
mutation history. Five keys were observed reference/61N, not guaranteed allsite.

Unlikev992, this aims to avoid repeated GridAnd as well as repeated GridMask.
Measured mask+And parent1481/1731ms reference/61N is NOT the saving. Charge all
initial masks/intersections, owned clones, every circle update of every admitted
key, destination copies, admission guards, evictions and cleanup. If native
updates/copies consume the gain, stop this implementation before production.

Cheapest next action: implement the private mutation-aware kernel with model
tests for actual ordered mask/intersection/clear sequences, new/evicted keys,
empty/full eligibility, circle clipping, source mutation refusal, tuple/alias/
ownership/failure cleanup. Then extend the existing native observer to witness
complete owner/mutation lineage and compare EVERY eligibility result before
zone/similarity/seeded selection. Prove exact native circle rasterization on
owned mask representations, not just mathematical set identities. Preserve
native integer-subtype/error contracts and all source/destination ownership.

Reuse _ralph/tmp/under80_20260912/filler_mask_cache.lua and its test scaffolding
for bounded ownership/LRU, NOT its immutable cache algorithm unchanged.
filler_mask_observer.lua already has full unsigned-grid comparison with bounded
f32 repacks, sentinel self-tests, immutable source guards and scoped native
procedure ownership. filler_mask_profile.lua installs that observer through
native_proc_profile.lua; private debug discovery must NOT enter production.
Extend the observation sequence to GridAnd andplace_grid circle clears, keeping
every actual native operation once and comparing scratch results separately.

No new kernel, native mutation census or saving exists yet in this note. This
is the next actionable implementation, not permission to integrate the rejected
v992 cache or edit engine files. Preserve eager UGbootstrap, serial raster/
projection, all pass-edit resumes andimmediate+scheduledpreT1 rebuilds. Eventual
actual production qualification, all-source review andfull six-site cold gate
remain required. Use prospectively declared contemporaneous baselines for any
genuinely new candidate; never rewrite prior failed gates or rescue samples.

## Mutation-aware private kernel and native observer implemented

filler_eligibility_cache.lua now owns bounded LRU eligibility grids and applies
every observed zero-circle clear to every live entry. Misses compute the complete
mask AND current place grid; hits copy maintained eligibility. Entries are never
used as the mutable trial destination. Integer-subtype mask admission, caller/
owned-grid alias refusal, explicit mutation/source invalidation, failure latching
and retryable owned cleanup are tested. The caller retains responsibility for
certifying source stability and the complete mutation stream; this is NOT a
production global wrapper or a native-return impersonation.

8980 kernel checks PASS across capacities0/1/2/5/8 and three grid shapes, ordered
interleaved clears/requests, clipping/fractional circle geometry, empty/full
regions, later trial writes, eviction, invalidation, integer-vs-float keys,
aliases, copy/mask/intersection/update/free failures and ownership cleanup.
The circle fixture is a model; exact native rasterization remains to be proved.

filler_eligibility_build.py reuses the reviewed ownership/unsigned-grid exact
comparison helpers from filler_mask_observer.lua and appends the new observer
tail. Generated observer/manifest live in artifacts/filler_eligibility_observer.
The observer brackets actual UG Filler and temporarily owns four native names:
GridDistanceMars identifies the private place/distance lineage; GridMask pairs
with its immediate GridAnd; GridCircleSet witnesses every later place clear.
Original native calls and return tuples always execute once. Each request compares
full scratch eligibility against the actual mask+And output before subsequent
zone/similarity/seeded selection. Live place guard receives each exact native
clear and is compared after clears and before later requests; fixed source guards
are checked too. Unexpected mutations/pairing fail the diagnostic.

After scope exit, both old/new and new/old replays use a private clone of the
initial place grid and the complete bounded request/clear journal. Timed work
includes place clone/free, every original clear, all maintained-grid updates,
masks/intersections/copies/owned clones/evictions/cleanup, plus an equal final
place copy used for an out-of-timer verification. No per-operation clocks. Native
source and final-place comparisons follow each replay. At most16384 journal
events; only scalar request metadata and aggregate counts survive scope cleanup.
Cache payload<=16MiB and8 entries; additional fixed scratch is bounded by source
dimensions and reused native comparator buffers. Never read the freed caller
place grid at ProcEnd (native Filler frees it before that boundary).

3192 observer checks PASS: complete native-shaped results and nil tuples, source/
mutation pairing, both-order replay work identity, missing And, unexpected writes,
bad copies/partial masks/comparator/alias/allocation errors, inherited raw slots,
foreign-coroutine pass-through, unfinished scope, rebound owners and full existing
native-procedure-driver composition. Initial fixture concatenation lacked a
newline (endfor syntax); fixed fixture only before any native run.203 retained
native-procedure checks also PASS. All9 filler_eligibility_offline prerequisite
commands pass, including exact56fbf44 production and38-file deployment audit.

Next frozen native61N thenreference using profile.py, new artifact names,
filler_eligibility_profile.lua and querySBM_NATIVE_PROC_DIAGNOSTIC. Require full
filler_eligibility_audit (native lifecycle, predecessor/grids/individualrocks/four
private-stream fields, mutation journal/full-grid comparator census, all replay
work/ownership and normal flushed process shutdown). Native proof/timing still
pending here. Private primitive replay gain would not establish startup savings.
