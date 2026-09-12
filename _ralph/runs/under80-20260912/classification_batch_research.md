# Unimplemented native class-list hypothesis

Read-only engine source: CommonLua/LuaExportedDocs/Global/LuaSharedLib.lua:545-555
documents both IsKindOf(object, class) and IsKindOfClasses(object, class_list),
plus a vararg overload. Production already uses IsKindOfClasses elsewhere, but
ObjectClone's classification loops still make repeated protected single-class
calls. The pre-v979 full profile counted1573005 Engine.IsKindOf calls; v979
removes duplicated capture-side exclusions, so that older count overstates the
remaining opportunity. No current native batch timing or equivalence test exists.

Potential scope: negative results for immutable per-call kind lists, with no
class-result cache, no object-state cache, no skipped validity/parent/name checks.
IsUndergroundAccessObject returns the FIRST matching kind as extra data, so any
positive batching shortcut there must still identify that same first kind.
ShouldSkipObject and ObjectScalesWithTerrain have other field/name decisions;
those are not implied by native class membership and must remain.

Compatibility is unresolved: existing predicates use Engine.IsKindOf, which
reads the live IsKindOf function and supports custom/fallback implementations.
An unrelated IsKindOfClasses override is not necessarily equivalent. A proposal
must qualify the actual native pair and preserve scalar paths for rebound/custom
helpers; merely finding two callable functions is insufficient. Do not replace
custom classification hooks, infer classes from names, or cache g_Classes results.

First step is a native scratch/read-only actual-object comparison and call counts,
then a narrow reviewed candidate only if the compatibility contract is sound.
This note authorizes no production changes and establishes no performance gain.

Native scratch probe native_class_batch_reference completed at accepted v979.
Both named APIs report C functions. Across7157 current g_Classes definitions and
five kind lists,35785 exact boolean comparisons passed with no query errors.
Positive counts: mystery21, underground access18, resources3, skip kinds643,
spawned deposits31. Owned PID39560 normally quit. This compares class definitions,
not live-object validity/parent/name behavior; no candidate or timing claim yet.

ObjectScalesWithTerrain is currently NAME-based (ClassScalesWithTerrain), not an
IsKindOf loop. It must not be converted to native ancestry semantics. Potential
batching is confined to existing ancestry checks. An Engine-level qualified helper
could preserve scalar fallback for captured/custom/rebound IsKindOf helpers and
live native pair changes, but its implementation/compatibility proof remains open.

## Current nondeployed candidate and verified failures

Continuation revalidated clean684295c, deployment38/38, no live game. Candidate
generation is class_batch_candidate.py; artifacts class_batch_research through
class_batch_research_4 preserve the successive source/manifest versions.

The candidate adds Engine.FirstKindOf: use a native list query only for a proved
negative, otherwise execute the original scalar list in order and return the
first matching kind plus its original scalar value. It qualifies captured native
function identities against LIVE sandbox rawget lookups, the original Engine
IsKindOf and SafeCall identities, and the caller's captured scalar helper. No
class/object/map result cache. Five ObjectClone classifiers use it; all names,
validity, parent/entity checks and name-based scaling remain unchanged. Missing
FirstKindOf on older/custom Engine tables retains the original scalar loop.

First fixture588904 development exposed a real edge: using Engine.Global for
qualification could accept stale functions after that helper itself was rebound.
The old draft fails the rebound_global_and_single return-value assertion.
Candidate2 instead uses the same live sandbox rawget as canonical Engine.IsKindOf.

First native profile class_batch_profile_reference (96971/PID45212) FAILED at
setup because debug is blacklisted in the mod sandbox. The captured error is
preserved; no classifier replacement occurred, and the owned game normally quit.
Do NOT unlock the sandbox or smuggle debug into production.

class_function_kind_reference (78726/PID42020) confirms the supported alternative:
the mod can access standard string.dump. C pcall/IsKindOf/IsKindOfClasses produce
the same caught 'unable to dump given function' error; a Lua closure and the mod
classifier serialize normally. Root debug was used ONLY as diagnostic ground
truth, not accessed via the mod. Production proposal checks a Lua and C control
once, then requires the same C failure protocol for both native class functions.
Unavailable/unexpected serialization behavior disables batching. No bytecode is
exported or executed. Standard primitives require module reload if replaced.

Second full profile class_batch_profile_reference_2 (77388/PID16216) preserved
all exact outputs, but FAILED instrumentation/work reduction:163827 native list
calls,955914 scalar calls, ZERO negative shortcuts, final status ready not pass.
The native API documents boolean but class_batch_returns_reference (74506/PID22468)
measured nil negatives:219577 scalar nil/716true and35069 batch nil/716true over
7157 definitions. Candidate4 recognizes false OR nil only on successful qualified
native calls; the canonical scalar Engine.IsKindOf would normalize either to false.

Current candidate4 passes667222 exact return/non-class-query-order fixture checks
across native true/false and true/nil, unavailable/malformed inspection, missing
batch API/helper, custom/rebound helpers, rebound globals, and failed batch calls.
Native scalar calls41906->4243 with9613 batches; unqualified modes keep all scalar
calls. Corrected class_batch_profile_reference_3 is the next native measurement;
its setup asserts all instrumentation substitutions, rather than silently accepting
a missing counter. No code/version/deployment promotion has happened yet.

Corrected profile class_batch_profile_reference_3 (4044/PID32056) now PASSES
instrumentation and full exact predecessor/individual-rock/private-stream parity.
Native pair true, two shared classifier cells replaced: 163834 batches, 163550
negative shortcuts, only482 scalar calls, zero failures. Surface annotation1434ms,
underground600ms. Do not compare its timing to the failed zero-shortcut profile
as if that were accepted-v979 cold timing: that profile added redundant queries.
Candidate4 is now promoted into pending v980; cold acceptance is still required.

v980 cold acceptance subsequently FAILED the performance criterion: median89.687
versus accepted89.425s; all exact outputs pass. Combined candidate rejected before
the five-site sweep, production restored at8af568f. A separate full native phase
probe confirms native pair/live identities/current public and captured helpers
all match; batching was active after normal startup. Do not claim a cold saving
from the earlier instrumented measurements or rerun unchanged as a rescue.
