# v981 consecutive indexed crease reads

Baseline c4d3e67 (accepted v979). Candidate changes only one terrain discovery
caller plus runtime981/generator guard296. Rejected v980's class-list helper and
tighter apron bound are NOT reintroduced. Existing Engine/ObjectClone/grounding,
all other production modules, game binaries/settings and debug buttons remain.

The native discovery index produces sorted unique perpendicular positions.
Previously collect_axis called scan_line_range for each singleton, repeatedly
initializing the same overlapping read window. scan_indexed_ranges joins only
consecutive positions and invokes the SAME existing rolling scan on each range.
No gap is bridged. Every certified position and edge/width order remains.
Both helpers are local to the same repair call. Discovery is read-only, with
only private row-offer bookkeeping between samples; no engine mutation or yield.
No height escapes that read-only scan, and later refinement still sees all prior
track writes through the existing invalidation guide. This is not a class/map/
grid result cache and adds no native grids, packed buffer or decoder.

Native index tests, actual scalar predicates, row offer/strict tie logic, track
qualification/refinement, translation order, bounded slope-matched joins and
every write remain unchanged. No numerical expression is reassociated. Sample
coordinate union is identical; fewer repeated reads of those coordinates are
the intended optimization. Nil/empty lists do no work, as before.

Production regression now compiles old scan/offer functions directly from
c4d3e67 and current functions independently. It passes263494 exact offer/read-
coordinate checks across both scan widths, all edges, missing/boundary/noisy/
cliff/flat samples,256 position subsets, empty/singleton/consecutive/gapped lists,
duplicates/descending lists and changed terrain on a subsequent call.
Fixture reads313040->195888 and scan calls62608->33320. Existing crease_sampling,
native discovery, refinement guide, track ordering and join tests remain required.

Nondeployed native crease_ranges_shadow_reference passes full predecessor
surface/underground terrain, pass grids, placements, private streams and individual
rocks, plus both complete U16 repair grids and all returned reports/tracks/stats.
Source287positions/287ranges reads1148 unchanged; destination171387positions/
35342ranges calculated reads1028322->348097. Counter formulas follow the unchanged
rolling function, not native getter hooks. Accepted source298ms/new193ms despite
unchanged reads demonstrates ordered-shadow noise; destination4080vs3426ms is
also diagnostic-only, never a cold acceptance claim. Owned PID31080 quit normally.

No RNG call or sequence changes, quotas/content cuts, coordinates, terrain
approximation, passability/buildable rebuild removals, transaction order changes,
deferred work, START/T1 changes or scheduled postpipeline revalidation changes.
All ten correctness rules remain in scope. Require78 offline commands, one fixed
reference-three/control/five-site cold checkpoint, full exact predecessor and
private-stream evidence, source/shared RNG review, nine unique owned normal
shutdowns and deployment38/38. Inherited visual equivalence rests on full exact
outputs, not newly captured screenshots. Under80 remains unproven at all six sites.
