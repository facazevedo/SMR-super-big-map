# Radius-expanded decoration queries (nondeployed)

REJECTED BEFORE PRODUCTION: decor_radius_shadow_61n53366/PID9160 closed normally,
all775867 old/new queries exactly equal, full predecessor/private/rock PASS.
Original queries2618ms, expanded queries3263ms (ordered diagnostic only, not cold).
The eight active shared groups stayed within storage limits; no invalid fallback.
140 obstruct radii shared four built groups,97 decorated radii shared four.
The prototype was active but slower. Do not promote or repeat unchanged.

Current coarse wall diagnostics: reference decor427ms,61N136W decor9768ms.
Slow-site pass keeps190 groups and makes727247 synthetic attempts (701139 finite),
652582 obstruct rejections and60756 decorated rejections. Every attempt, seeded
cursor/random draw, terrain check, matcher result and rejection precedence stays.

The accepted v974 spatial query indexes circles, then searches all buckets in the
query circle's bounding box and deduplicates candidates. Research pre-expands
circles by an upper bound on query radius, making each query a single point-bucket
lookup. Radius groups use4096-unit ceilings, so nearby template radii share storage.
Every returned candidate still uses the unchanged strict squared-circle predicate
with the ACTUAL radius. Both circle arrays are private, append-only per Run; each
group incorporates all new circles before answering its next query. No hit result
cache and no object or native terrain query cache exists.

Exact-domain qualification: finite |coordinates| and circle radius<=2^26,
query radius0..65536. The dyadic4096 ceiling is an exact upper radius. The expanded
box is padded by one world unit, much more than binary64 endpoint/subtraction
roundoff in that domain; squared distances cannot overflow native signed64 there.
Any strict hit must be inside this enclosing box. Outside the domain, the complete
accepted spatial query runs. Groups warm up for32 queries before building; a131072
reference-slot storage ceiling also selects the accepted query, never omits work.
No per-map/class/coordinate allowlist, budget cut or candidate shortcut.

Offline three-way comparison checks the accepted spatial query and exhaustive
literal predicate, strict tangencies, fractional/negative coordinates, radius-group
edges, shared groups, live appends, pass lifetime and storage/domain fallback.
Native decor_radius_shadow runs BOTH queries for every actual call, returns the
original result, census actual groups/cache slots and record old/new diagnostic
time. It joins the live private query cell without reloading any module. No native
verdict or cold gain exists yet; do not promote based on offline speed.
