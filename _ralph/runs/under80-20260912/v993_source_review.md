# v993 source and correctness review (cold performance pending)

Candidate payload e6976fc4d92a10f2ed54f6bae86ff04b0fc49bd7, based on accepted
56fbf44/v987. Production diff is exactly three files: map-generation helper and
integration, generator patch identity 299 -> 305, metadata 987 -> 993 and release
text. All terrain, decor, rock, object, configuration and remaining production
files stay byte-equivalent to accepted source after line-ending normalization.

Native primary source RandomMapGenerator.lua:1771-1833 builds one distance source,
initializes one place grid, and uses GridMask followed immediately by GridAnd with
that place. Successful placements only clear circles in place at line 1826. The
source is otherwise read-only; place is freed by GridOpFree at 1833. Wrapper
qualification uses this supported procedure, one generator/coroutine, native
allocation/distance lineage, unsigned matching dimensions and integer mask bounds.

Raw-mask cache substitution is a full copy of the same native threshold result.
Boolean eligibility is a distinct clone of the actual initial native intersection.
Applying every identical native zero circle to each eligible clone maintains the
same result as masking the current place. The raw and eligible API boundaries are
not fused. Pending first intersections read then-current place. Original zone-mask
operations, similar_apply, trand/grand and seeded state:Get() calls execute in the
same order against ordinary independent trial grids. No RNG source or consumer
is changed, bypassed or replicated. Class Generate/DoGenerate/OnGenerateLogic
identities are left alone; current ProcStart/End boundaries are composed/restored.

Unsupported pairings, types, dimensions and known mutations disable the cache
before the affected native operation. Native result tuples preserve nil positions;
admitted hits return exactly destination as established by actual native contracts.
Direct unexpected source/place changes fail full range-safe f32 difference guards
before place free. This is not arbitrary userdata-write interception, nor a proof
against mutate-then-restore behavior absent from the supported native body. Only
owned clones/comparator outputs are freed. Cleanup failures latch, owned globals
restore by identity, and the outer native transaction restores before propagating
failure even when the engine's error() only logs.

No required eager underground bootstrap, serial raster/projection, native pass-edit
resume, immediate rebuild, scheduled pre-T1 revalidation, terrain fix, rock/contact
sample, selection, placement or decor cursor is omitted, moved or shortened. No
engine, harness-core, settings, other-mod or scenario-specific edit. Native controls
do not enter this expanded-UG cache installation. Exact final-output evidence
inherits accepted visual geometry; no fresh visual-inspection claim is made.

Verification: all 83 accepted regression commands unchanged plus actual-helper
(4,418 checks) and source/transaction tests = 85 commands PASS. Frozen hashes and
logs in artifacts/v993_offline. Private paired native outputs/tuples on two maps
passed at 21481b0. Integrated reference and 61N at e6976fc both pass the full
predecessor/private/rock/process audit with actual expected mask/And hits, all live
clears, source/place guards, bounded ownership and restoration. See
v993_paired_filler_integration.md for exact identities and censuses.

This proves tested correctness and actual production activation, not all-site
startup improvement. Candidate is not promoted yet. Cold samples and full six-site
performance decision are missing; under-80 and under-85 targets remain unproven.

## Explicit user acceptance revision before cold samples

The user changed the requested end state to reference START-to-T1 median below
85 seconds, measured over three runs. The five additional sites still require
complete preservation checks, but no longer impose an all-site startup threshold.
The older goal/performance wording above records the original investigation, not
the current acceptance criterion. No v993 cold sample existed when this changed.

Use existing reference A/B/C/control and five-site exact verification workflows.
review_v974.py --version 993 keeps the full 85-command/source/deployment/nine-unique-
process/correctness review and records the revised timing predicate separately.
All historical versions retain their original decisions and timing predicates.
No under-80 or all-site speedup will be claimed from reference-only success.
