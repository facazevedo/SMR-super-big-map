# Unimplemented next hypothesis: avoid duplicate rock classification

The native relief function profile in `artifacts/zero_harmonic_profile_reference_3`
counted1,195,943 Engine.IsKindOf calls,33,609 ShouldSkipObject calls and16,579
RockGrounding.Capture calls within one reference annotation. Only21,414 native
IntersectSegment calls occurred; rays were1.59% of profiled exclusive load.
Profiler overhead means those percentages are not uninstrumented stage timings.

At `AnnotateDecorRelief`, the caller has just evaluated ShouldSkipObject and
IsImportantSectorObject for the exact object. Grounding.Capture is called only
when both are false. Between that check and the call, it appends the object to
the private eligible list; there is no object/terrain mutation or yield. Inside
Grounding.Eligible, the first two calls repeat those same classifications.

A narrow possible change is to pass an explicit per-call qualification from
this caller, avoiding those two repeated predicates only. Keep the old default
Capture/Eligible path for all callers without qualification. Keep all remaining
scale, parent, entity-category/material, bounds, source-Z, terrain, ray, native
support and lowering tests unchanged. Do not cache across objects, maps, yields,
object mutation, invalidation or separate placement stages. A per-class cache is
NOT established safe and must not be substituted for this narrower hypothesis.

Before implementation: prove the immediate caller contract and exercise the
default/qualified paths with identical complete capture records and subsequent
grounding results, exclusions and failures. Test both terrain-glued and explicit
Z, map edges, unchanged/tilted objects, changed pose and reload/default callers.
Full exact individual-rock comparison is mandatory, not only count/total lowering.
Primitive binding in v978 may reduce this hotspot enough to make another change
unnecessary; measure on accepted v978 before deciding. This file is research, not
a production change, timing claim or permission to weaken eligibility checks.

A non-deployed generator `classification_candidate.py` is prepared but not run.
It preserves the default full classification and adds immediate-call checked
predicate identities. The receiver also requires those identities to match its
current Clone fields, so rebinding/module reload cannot silently reuse a result
from different classifiers. This matters because TerrainCopy captures predicate
aliases while RockGrounding reads the Clone fields dynamically. The prepared
`classification_test.lua` compares complete private capture records, native-query
arguments, final positions/stamps/stats, exclusions, rebound classifiers and ray
failures. Neither generator nor test has run yet; no native measurements exist.
Do not promote it based on this note.

An independent diagnostic setup `pipeline_function_profile.lua` is prepared to
measure the remaining full pre-T1 Lua work after v978 acceptance. It starts the
native profiler before START and stops after the unchanged scheduled surface
revalidation returns, so its timing is intentionally NOT a benchmark. Use a fresh
owned process and exact full predecessor comparison. This can distinguish remaining
shared-helper overhead from arithmetic/native stages before selecting another
change. No dynamic game-function cache or class-result cache is authorized by it.
