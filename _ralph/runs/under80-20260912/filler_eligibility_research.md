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
