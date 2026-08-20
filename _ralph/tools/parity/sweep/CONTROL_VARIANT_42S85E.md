# 42S85E: the vanilla control flips between two whole surface layouts

Measured 2026-08-20 iter 1594. All three runs are fresh MarsDebug processes on the
committed v824 payload (audit 36/36), same coordinate (lat=2520 lon=5100), same
surface seed -4057722651014861964, `serial passagepin hexgrid`.

| run | file | invocation | underground seed | starting sector(s) logged |
|-----|------|------------|------------------|---------------------------|
| ctl1 | `objects-fv823b206v.csv`  | sweep case 7 control, `nopin` | 2495899094735985612 (drawn) | G6, F6 (2) |
| ctl2 | `objects-fv823b206v2.csv` | repeat control, identical args | 7242586386255985993 (drawn) | I2 (1) |
| exp  | `objects-fv823b206e.csv`  | expanded twin, seed pinned to ctl1's | 2495899094735985612 (injected) | none logged |

Surface (class,x,y) multiset intersection:

| pair | identical | only left | only right |
|------|-----------|-----------|------------|
| ctl1 vs ctl2 | 203 | 13096 | 13230 |
| ctl1 vs exp source stamps | 7 | 13292 | 13220 |
| **ctl2 vs exp source stamps** | **13221** | 212 | 6 |

Per-class: Geyser_02 ctl1 69, ctl2 49, exp source 49. StonesSlate_02 1501 / 1510 / 1510.
PrefabMarker 1423 / 1436 / 1436.

Conclusions:

1. Two identical vanilla control invocations produce two different surface layouts -
   not a cluster of contested stones (the superseded `sweep/DRIFT_VERDICT.md` case,
   6-34 rows) but a whole-map re-draw: 203 of 13,299 positions survive.
2. The expanded twin's source capture reproduces the SECOND control almost exactly
   (13221 of 13227 stamped source positions), so the mod delivered a legitimate
   vanilla variant; case 7's red is the control having drawn the other variant.
3. The flipping input is NOT the underground seed: exp was pinned to ctl1's seed and
   still matches ctl2, which drew a third seed. Not `MapLoadRandom` either (ctl1 and
   ctl2 log the identical three values). `rival_colonies` order differs in every run
   of every case, green ones included, so it is unordered iteration, not RNG.
4. The starting-sector count follows the variant (ctl1 = 2 sectors, hence
   SectorUnexplored 98/100; variant B = 1, hence the expanded map's 399/400), so
   section E's infrastructure red is a symptom of the same divergence.

Open question for the next session: which per-process input selects the variant, and
can the control be pinned to it (a general rule, not a per-coordinate allowance).
