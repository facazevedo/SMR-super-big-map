# Accepted-v987 native procedure wall times

Both inputs passed complete predecessor/private/rock/process and probe audits.
Parent and child rows overlap. These are not cold startup or savings figures.

## Surface native call

| Procedure | Reference ms | 61N136W ms |
| --- | ---: | ---: |
| Whole native call | 4579 | 6287 |
| SetupStyles | 26 | 20 |
| InitPlayZone | 28 | 21 |
| FindPrefabPos | 1463 | 1572 |
| ↳ FindPrefabPos_Border | 193 | 148 |
| ↳ FindPrefabPos_Playable | 553 | 600 |
| ↳ FindPrefabPos_Slope | 48 | 92 |
| ↳ FindPrefabPos_Filler | 140 | 139 |
| ↳ FindPrefabPos_Base | 269 | 361 |
| ↳ FindPrefabPos_Unfilled | 245 | 220 |
| PlacePrefabs | 1092 | 886 |
| PlaceDecors | 113 | 1881 |
| ApplyTerrainMarkOnly | 395 | 412 |
| ApplyTerrain #1 | 222 | 189 |
| ApplyTerrain #2 | 592 | 622 |
| FixPadTerrain | 0 | 0 |
| AdjustObjects | 103 | 116 |
| ResolveBuildable | 389 | 410 |
| PlaceColdAreas | 0 | 2 |
| PlaceArtefacts | 0 | 0 |
| PlaceAnomalies | 148 | 146 |
| PlaceObstructions | 0 | 0 |
| ClearLandingZones | 0 | 0 |
| Outside recorded top-level procedures | 8 | 10 |

## Underground native call

| Procedure | Reference ms | 61N136W ms |
| --- | ---: | ---: |
| Whole native call | 12223 | 9729 |
| SetupStyles | 8 | 9 |
| InitPlayZone | 39 | 58 |
| FindPrefabPos | 5348 | 4647 |
| ↳ FindPrefabPos_Border | 0 | 0 |
| ↳ FindPrefabPos_Playable | 2149 | 1062 |
| ↳ FindPrefabPos_Slope | 9 | 8 |
| ↳ FindPrefabPos_Filler | 2116 | 2479 |
| ↳ FindPrefabPos_Base | 921 | 857 |
| ↳ FindPrefabPos_Unfilled | 153 | 241 |
| PlacePrefabs | 913 | 991 |
| PlaceDecors | 2 | 3 |
| ApplyTerrainMarkOnly | 573 | 589 |
| ApplyTerrain #1 | 25 | 24 |
| ApplyTerrain #2 | 597 | 584 |
| FixPadTerrain | 81 | 81 |
| AdjustObjects | 96 | 104 |
| ResolveBuildable | 937 | 913 |
| PlaceColdAreas | 0 | 0 |
| PlaceArtefacts | 3540 | 1663 |
| PlaceAnomalies | 28 | 26 |
| PlaceObstructions | 26 | 26 |
| ClearLandingZones | 0 | 0 |
| Outside recorded top-level procedures | 10 | 11 |

