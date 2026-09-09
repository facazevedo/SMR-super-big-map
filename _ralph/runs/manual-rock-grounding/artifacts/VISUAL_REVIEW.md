# v957 visual review log

Original screenshots only; no image editing. Cameras settle before capture.
Rock before/after comparisons occur after canonical snapshots and T1; only the
selected rock is temporarily raised to its pre-correction Z, then restored in a
finally block. They do not override production generation or accepted timings.

## Expanded A runs inspected

- 15s67e_a: all six rock_visuals/01..03-{grounded,without-correction}.png.
  RocksSlate_01, RocksSlate_04 and CliffDark_02 seat deeper against existing
  terrain; the exposed underside is reduced without reshaping either mesh or
  surrounding ground. Also visuals/cluster-003-oblique.png and right-a0.png.
- 24s74w_a: visuals/cluster-001-oblique.png and right-a0.png. No grounding images
  exist because no rock required correction; the empty manifest is expected.
- 45s120w_a: visuals/cluster-001-oblique.png and right-a0.png. No rocks adjusted.
- 61n136w_a: visuals/cluster-001-oblique.png and right-a0.png. No rocks adjusted.
- 17s11w_a: all six rock_visuals/01..03-{grounded,without-correction}.png.
  CliffDark_02, CliffDark_02_66 and CliffDark_03_33 sit lower, retaining their
  shape and the native surrounding formation. Also visuals/cluster-001-oblique.png
  and right-a0.png. This is selective seating, not removal of every native
  authored overhang or a claim that all distant rocks in these views are grounded.

No new deposit-centered raised rim/moat or thin continuous artificial edge wall
was found in those fresh resource/edge views. Native craters, mountain faces and
stock shadows remain. Exact whole-surface height/site/pad equality with v955
supports the retained prior terrain QA in 15S/24S/45S/61N. 17S has unchanged sites,
pads and entrance XY. The complete 8192x8192 raw-height comparison finds exactly
13,496 changed cells, all lowered by one U16 unit and confined within 7,610wu of
entrance 2 (tile bbox 2464,3761..2615,3895). Every other height cell is identical.
The final entrance footprint reports Z7586 instead of Z7587. This small local
native/buildable entrance-plane consequence reproduces exactly in A/B; it is
not a direct terrain-writing operation in the grounding module or a map-wide
terrain change. See v957_17s11w_height_difference.json.

## Expanded B entrance views inspected

All ten entrance_visuals/entrance-{1,2}.png images, two per scenario, were viewed.
The built elevator and unbuilt stock passage imprint remain seated; no new
entrance-edge cliff or terrain discontinuity was found. The 17S one-unit plane
change has no visible boundary change in these views.

## Final v957 G3 reproduction inspected

v957_g3_final/grounded.png and grounded-close.png were both viewed. The automatic
2127wu lowering seats the reported CliffDark_03 deeper in the unchanged terrain,
matching the intent of the previously approved manual trial. XY, mesh scale and
rotation remain unchanged; final sampled native support has no positive gap.
The closer view is left open and paused for the owner. No manual drop override
was applied to this fresh generation. The153.679s interval is an instrumented
reproduction timing, not one of the cold acceptance timings.

The earlier v956 G3 image g3_bounded_auto.png was reviewed as a diagnostic only.
This log describes sampled QA, not universal future-map pixel coverage.
