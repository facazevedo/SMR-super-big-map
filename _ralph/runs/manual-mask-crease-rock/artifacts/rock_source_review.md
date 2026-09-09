# Primary-agent review of the isolated rock-capture candidate

Capture is non-yielding and does not move/rotate/scale the object. Bounding-box
scalars and visual coordinates are immutable throughout that capture, so their
getters are reused. Each Y coordinate uses the original arithmetic once and is
reused across X columns. Original terrain sample coordinates and ordering remain.

The original segment spans [min_z-tile,max_z+tile]. Supported contact requires
source_z+(hit_z-visual_z)<=ground. Since hit_z cannot precede the segment bottom,
ground<source_z+((min_z-tile)-visual_z) proves that no supported contact is possible.
Equality is retained. The original ground>source_z+tile gate, ray endpoints,
intersection selection, contact formulas and ordering remain unchanged otherwise.
No broad approximation, common lowering, object/scenario whitelist or new Z policy.

Apply and all subsequent code remain byte-for-byte unchanged. The isolated
differential test compares complete captured records, individual lowering, final
positions and contact census against the unchanged accepted module. 360 fixtures,
1,443 assertions pass; scalar geometry getters66,645->2,493 and capture rays
13,093->12,350. It separately asserts exact unchanged Apply source. The previous
production fails the work-reduction checks. Existing grounding regressions remain.

Terrain, resources, entrances, placements, ordinary/private RNG, temporary buttons,
final rebuild/revalidation and T0/T1 boundaries have no changes in this candidate.
Full offline, fresh timing and five-scenario exact-output/process acceptance are
required separately before retention. No new visual screenshot evidence is claimed.
