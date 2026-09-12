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
