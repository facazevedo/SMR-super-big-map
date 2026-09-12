# Nondeployed exact circle hint research

Preceding turn classified PROGRESS: accepted f4d1da6/v983 reference median86.718,
all80 tests and ten-rule/five-site review passed. Revalidated cleanb81263c,
deployment38/38 and no live game. Effective user target remains under85 seconds.

Diagnostic decor_detail_61n at ee5266b, session72865/PID5016 CLOSED exit0, normal
shutdown, exact full predecessor/private-stream/individual-rock comparison PASS.
Only cloned Run was instrumented; all private cells joined, no module reload or
engine API replacement. Original Run restored at scheduled surface revalidation.
No cold performance claim from its instrumentation-inflated total17285ms.

| Helper | Calls | Inclusive ms | Exclusive ms |
| --- | ---: | ---: | ---: |
| circle_hits | 775867 | 2727 | 2727 |
| terrain_type_at | 727244 | 3372 | 2945 |
| native_get_type | 721100 | 427 | 427 |
| cursor | 701139 | 3952 | 2920 |
| rand | 2184096 | 1635 | 1635 |
| try_stamp | 714763 | 5775 | 2942 |
| place_prefab | 194 | 105 | 105 |

Nested timer-wrapper overhead is included in parent exclusive measurements. These
are diagnostic counts/coarse attribution, not additive uninstrumented durations.
Native terrain-type lookup itself is cheap; prioritize Lua overhead before a
GetTypeGrid rewrite whose semantic equivalence is unproved.

## Simpler last-hit hint, not a whole-cell positive answer

The temporary decor_hit_hint.lua retains the complete accepted index algorithm;
its private indexed_hit additionally returns the circle that caused a true result.
After32 warm queries, store a bounded last-hit circle per4096-unit spatial cell.
Future queries first evaluate that circle's exact original strict predicate. A
hint miss ALWAYS continues through the accepted index. No negative answer is
cached and no query, rejection precedence, traversal, random draw or stamp changes.

A cached positive also requires a conservative one-unit inward reach margin.
Numeric qualification: query coordinates within+/-2^26, radius0..65536; cached
circle coordinates within+/-2^26, radius0..2^26. Thus differences/squared sums stay
within native signed64 range; double roundoff in coordinates/radii is far below
one unit. The one-unit interior margin proves overlapping axis bounding intervals
despite rounding, so the original grid index must visit that circle. The exact
predicate is separately evaluated unchanged. Near-tangent points retain the old
full index. Unsupported queries retain the old query; unsupported circles are
never cached. Maximum32768 hints per list; existing entries may be replaced at cap.

List audit: obstruct/decorated are private Run arrays built at386-435, subsequently
only appended at639-641. Circles are private x/y/r records, never edited or removed.
On a miss the old lazy index catches up to every appended circle; positive hits
cannot be invalidated by appends. No cross-list/map cache or shared RNG is used.

Offline64009 three-way old/hint/exhaustive comparisons PASS, including tangency,
fractional/negative/large coordinates, warm-up, list isolation, append catch-up,
storage cap and unsupported query domains. Native complete-query shadow is next;
reject before production if it does not reduce real native query cost. No v984
candidate or cold gain exists yet. The older expanded-radius-list query remains
rejected and the whole-cell-certificate note remains an untested different idea.
