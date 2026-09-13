# Private immutable filler radius-mask cache hypothesis

Evidence: fully audited native primitive profiles show1524/1798 Filler GridMask
calls costing870/1012ms reference/61N. GridAnd611/719ms remains separate and is
NOT removed by this proposal. Allocation7/2ms across all selected stages rules
out pooling as a material improvement. Expected mask-cache savings are UNKNOWN;
copy/clone/lookup/eviction cost and actual key diversity may erase all benefit.

## Conditional correctness and current prototype

For a pure full-overwrite native mask F(source,from,to,scale), if source is unchanged
and all three scalar parameters match, copying a previously computed full output
equals recomputing it. This is a conditional equivalence, not proof that the live
engine callsite meets every premise. Source identity alone is insufficient.

Private filler_mask_cache.lua implements only that conditional cache, bounded LRU,
ownership cleanup and explicit local failures. apply returns success/error; it is
not interchangeable with a native function's return tuple. It never retains the
caller destination as its cached mask. Initial34935 and current34939 model checks
PASS; the latter additionally rejects false clone results. All evidence retained
under filler_mask_offline and filler_mask_offline_2. Production still exactv987.

## Next actual-native experiment (not yet implemented)

1. Use the existing observer/base native-proc infrastructure, capture only actual
   UG FindPrefabPos_Filler GridMask requests from the original DoGenerate's _ENV.
   Original GridMask still performs every game write and preserves every return.
   Record the bounded actual parameter sequence and ONE private source clone;
   reject unsupported arity/types, source aliases or more than one source grid.
   Do not precompute candidate draws or inspect/advance RNG.
2. Certify source identity AND unchanged complete source contents at each observed
   mask request, not only matching dimensions. Use exact native full-grid difference
   reduction with verified integer/format/range behavior; no approximate hash-only
   claim of equal cells. It is acceptable for this private diagnostic to cost more
   than a normal run. Bound memory and all captures, preserve first failure.
3. On the private frozen clone, replay ALL actual requests through native uncached
   masks and the private cache. Verify every full destination and no mutation of
   the private input. Include sentinel-prefilled destinations to prove native full
   overwrite semantics. Obtain actual unique-key counts, hit/miss/eviction counts
   and peak retained bytes. Start conservatively with at most8 masks/16MiB.
4. Separately time both orders, including lookup/copies/misses/clones/evictions and
   final cache cleanup. Exclude equality checking from measured kernels equally.
   Do not bypass copy cost or use an unbounded warm cache to advertise savings.
   Existing native grid:copy is available; use inspected native equality machinery
   (e.g. exact U-range-to-f32 difference + GridCount) only after validating bounds.
5. All scratch resources and temporary hooks restore on success and failures.
   Native APIs may log errors and return; helper success alone is insufficient.
   Require comparison results, explicit failure latches and full clean engine logs.
   Reuse full predecessor/private-four-fields/individual-rock/process audits, fresh
   hidden owned identities and normal shutdown. No user game, module reload, engine
   settings/raster parallelism change or class generation method replacement.

Only a genuinely positive bounded native result warrants integrating an actual
production candidate and rerunning its real-source correctness suite. Then cold
reference/control and all five scenarios must prove the requested performance
and preservation gates. Do not promote a private helper result or repeat unchanged
rejected candidates. No displacement of required native work pastT1 is allowed.

If key diversity/copied bytes erase gains, reject promptly. Other measured costs
are exact distance transforms and seeded grid selection, but neither may be
replaced by a different algorithm/RNG merely because it is expensive. The full
<80 objective and user's relaxed<85 target remain unmet, not redefined here.

## Native shadow implemented; prerequisites PASS

filler_mask_observer.lua uses the existing native_proc observer interface and
temporarily wraps only the actual shipped GridMask owner during UG Filler. Real
GridMask executes once and its nil-preserving full tuple is always returned.
Private failures latch diagnostics without replacing the original output. Initial
source is cloned BEFORE the first real mask; every call verifies source equality
to that initial guard. Private cache results and a second, differently sentinel-
prefilled uncached mask each match the actual live destination. Private input is
checked unchanged too. Request sequence cap8192; one source and arity5/scale1 only.

Comparator accepts only unsigned grids whose min/max are integers within0..2^24,
so conversion to f32 and signed subtraction preserve every integer difference.
Independent repacks, subtraction/abs and GridCount detect every unequal cell.
Before use, a private clone has one cell changed; both directions must count1 and
self-comparison0. Full comparisons are not hash-only. No actual game grid is
repacked/filled/modified/freed by the observer; only original GridMask writes it.

Cache at most8 masks and floor(16MiB/(width*height*4)) entries. This conservatively
bounds cached unsigned payload; separate private comparison grids also exist.
Both timing orders include fresh destinations, masks/copies/clones/evictions and
cache close. Full comparison work is outside timed kernels. All scratch handles
are tracked, hook resolved/raw identities restored, native errors and observer
failures latched; active-scope restoration also releases the hook and scratch.

filler_mask_shadow_offline all7 commands PASS:203 inherited probe checks,
34939 private kernel model checks and1676 observer exact-grid/source/tuple/
ownership/error/driver checks, two syntax checks, exact56fbf44 Code/metadata/items
comparison and38file deployment audit. Fixtures include deliberate source mutation,
broken copy/comparator, partial writes, bad clones/repack errors, changed source,
unsupported arity, unfinished scopes, inherited owner slots and other coroutines.
These do not substitute for actual native-engine proof. Python audit adds full
native process/private/rock parity and every-request/benchmark/ownership censuses.

Next frozen reference then61N, querySBM_NATIVE_PROC_DIAGNOSTIC through profile.py
with filler_mask_profile.lua; audit with filler_mask_audit.py. No production cache,
mod version or benchmark acceptance change. Current production remainsv987.
