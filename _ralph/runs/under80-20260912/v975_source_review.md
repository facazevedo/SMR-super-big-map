# v975 entry-scoped standard-library bindings

The terrain module differs from v974 by exactly five declarations. Each binds
math, type, ipairs, pairs and table at entry to one profiled terrain operation:
terminal-strip correction, native crease discovery, crease repair, natural-apron
raster, and outer resource terrain. Removing those declarations restores the
predecessor body literally. The generated candidate certificate records both
normalized source digests; production was checked equal to that candidate.

The engine's ModEnvMeta.__index resolves each ordinary global by checking its
blacklist and reading the original global table. The fresh native profile counted
9,891,316 such lookups in destination crease repair and 10,106,912 in outer terrain.
Local bindings reuse the same authorized library tables/functions within one
operation. They do not modify the environment or bypass access to any engine state.
Library tables remain shared, so their method fields are still resolved live.
Bindings are renewed at every helper invocation, not cached across maps or loads.

All calls, operands, arithmetic association, traversal order, terrain reads/writes,
native primitives, error paths and random call sites remain literal predecessor
code. No new RNG calls or scenario conditions. Rebuilds, T1 readiness, resource/pad
plans, individual rock support, entrances and temporary buttons remain unchanged.
Guard290 forces captured generator closures to reinstall on reload; metadata975 is
the published version. Previously rejected guard289 remains historical, not reused.

All72 offline commands pass. The added binding-lifetime fixture compares3,500
exact values and verifies29,612 math-environment lookups fall to8 while a changed
library is observed on the next invocation. Existing geometry/grid/seed oracles
are unmodified. In-game timing and complete output/process verification remain
separate and are required before this candidate is called successful.
