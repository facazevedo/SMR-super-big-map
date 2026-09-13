# v984 exact decor hot paths (candidate)

Baseline f4d1da6/v983. Only DecorTopUp plus generator299/runtime984 changes;
sector76 and every other production module, including accepted Q22, are unchanged.

The circle query keeps its accepted full bounding-box index and strict predicate.
Private last-hit hints, learned after32 warm queries, use at most32768 cells per
list. A hit is returned only after the exact predicate AND a one-unit inward
reach margin succeed. Near-boundary/unsupported queries and all misses run the
old index. Circles are immutable records in append-only private Run arrays; no
negative result or cross-map state is cached. The original index catches up on
the next miss after appends. The floor primitive is bound for this private list's
lifetime, standard functions/tables at Run entry, and GetTerrainType's existing
local function validity once when its unchanged cache is created.

Exact-rational decor_hint_bound_test proves norm excess<2e-6 plus rounded bounding
endpoint error<6e-8, leaving more than half a unit of axis overlap. Qualified
integer products fit signed64. Thus the accepted index must visit a cached hit
circle; the separate unchanged predicate must agree. No approximate square root
or approximate positive boolean is used by the query.

The finite cursor retains exact ceil-rounded geometry, initial draws, stride,
coprime selection, permutation, coordinates, draw order and exhaustion. Only the
last column/row may be partial. Precompute those two original min expressions;
all other widths equal step. Qualified count/step/coordinates are bounded and
seed indices integral. Unsupported domains retain the original cursor verbatim
after the SAME initial draws. No candidate pool, skipped cell, quota or RNG draw.

Native research history: first whole-cell-certificate idea remains untested.
The last-hit factory passed775867 query comparisons, avoiding679685 full-index
queries (diagnostic2566ms->1682ms). Combined inline variant1 had a lexical-name
collision noticed during source review and was never run or deployed; preserve
its generated artifact as rejected. Variant2 uses distinct hint coordinates/row.
Production DecorTopUp matches variant2 exactly, with no diagnostic counters.

Combined native shadow8392/PID21672 at f16b8ed CLOSED normally, full predecessor,
private-stream and individual-rock parity PASS.775867 circle comparisons and
701139 cursor calls,1402786 replayed RNG arguments/values, zero mismatches.
Circle diagnostic2837ms->1488ms; do not call this a cold startup gain. Only the
original cursor consumed actual RNG draws in that shadow; candidate draws were
replayed and checked. Production uses the real unchanged stream. All Run private
registry/upvalue cells were joined; no module reload or engine API mutation.

Offline oracle covers64009 old/hint/exhaustive queries,80340 cursor coordinates,
160598 exact RNG arguments/values, append/lifetime/memory/domain boundaries,
terrain-cache values/queries/missing/error/callable cases and entry capture.
Require all80 inherited commands plus the new Lua oracle and rational proof (82).

No content, matching, terrain arithmetic, pass/build transaction, rock support,
placement, failure handling, START/T1 or scheduled revalidation change. All prior
terrain fixes and temporary elevator/debug buttons remain byte-identical. Source
RNG audit and exact full private captures supplement the automated eight gates;
visual equivalence is inherited through exact full outputs, not new screenshots.

Freeze production/version/HEAD/deployment before reference3/control, then five
sites after a positive reference median. Require the targeted61N sample also to
improve versus v983 before acceptance. No excluded or rescue samples. Report all
site timings, including any regressions, without inferring uniform speedup.
The effective under85-second goal is still unmet and cannot be claimed here.

Cold acceptance FAILED: immutable67feaec, session55510 normally closed all four
owned processes31492/40472/14616/control41232. Reference89.815/90.014/90.289,
median90.014 vs86.718; control31.753 vs28.844. Exact predecessor/repeat/private/
rock comparisons and automated reference gates PASS; audit issues empty. No
five-site promotion, excluded sample or rescue repeat. Restore production and
test inventory to acceptedv983; candidate source/oracles are recoverable67feaec.

The similarly slower native control suggests a common timing shift, but does
not establish its cause or justify normalizing/overriding acceptance. Declare a
new unchanged-v983 baseline confirmation batch AFTER restoration; keep its data
separate and never substitute it into the rejectedv984 comparison.
