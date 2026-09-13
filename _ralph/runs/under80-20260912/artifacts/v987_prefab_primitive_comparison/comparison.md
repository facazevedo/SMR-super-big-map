# Accepted-v987 prefab primitive census

Diagnostic wall times with aggregate primitive wrappers, not cold/CPU/savings. Use exclusive primitive times.

## FindPrefabPos_Playable

Scope duration: 2151/1065 ms; outside timed primitives: 30/17 ms.

| Primitive | Ref calls | Ref exclusive ms | 61N calls | 61N exclusive ms |
| --- | ---: | ---: | ---: | ---: |
| GridDistanceMars | 629 | 1152 | 307 | 563 |
| GridMask | 651 | 280 | 330 | 147 |
| GridMulDivAdd | 646 | 186 | 324 | 90 |
| GridOr | 305 | 140 | 144 | 65 |
| GridMinMax | 305 | 133 | 144 | 63 |
| GridAnd | 327 | 131 | 167 | 58 |
| GridMulAddScaled | 324 | 49 | 163 | 27 |
| GridStableRandomPosSimple | 325 | 33 | 164 | 23 |
| GridEquals | 326 | 9 | 166 | 7 |
| table.weighted_rand | 327 | 5 | 167 | 3 |
| GridDest | 956 | 3 | 474 | 0 |
| NewComputeGrid | 4 | 0 | 4 | 1 |
| GridCircleSet | 304 | 0 | 143 | 1 |
| GridNot | 1 | 0 | 1 | 0 |
| GridOpFree | 307 | 0 | 146 | 0 |

## FindPrefabPos_Filler

Scope duration: 2137/2532 ms; outside timed primitives: 60/69 ms.

| Primitive | Ref calls | Ref exclusive ms | 61N calls | 61N exclusive ms |
| --- | ---: | ---: | ---: | ---: |
| GridMask | 1524 | 870 | 1798 | 1012 |
| GridAnd | 1525 | 611 | 1799 | 719 |
| GridStableRandomPos | 1519 | 500 | 1795 | 611 |
| table.weighted_rand | 1525 | 38 | 1799 | 69 |
| GridEquals | 1524 | 50 | 1798 | 43 |
| GridDistanceMars | 1 | 2 | 1 | 3 |
| GridCircleSet | 1810 | 1 | 1925 | 4 |
| GridDest | 1525 | 4 | 1799 | 1 |
| GridNot | 1 | 0 | 1 | 1 |
| GridMinMax | 1 | 1 | 1 | 0 |
| NewComputeGrid | 1 | 0 | 1 | 0 |
| GridOpFree | 1 | 0 | 1 | 0 |

## FindPrefabPos_Base

Scope duration: 959/890 ms; outside timed primitives: 87/71 ms.

| Primitive | Ref calls | Ref exclusive ms | 61N calls | 61N exclusive ms |
| --- | ---: | ---: | ---: | ---: |
| GridStableRandomPos | 2457 | 787 | 2344 | 759 |
| table.weighted_rand | 2457 | 70 | 2344 | 49 |
| GridCircleSet | 4251 | 11 | 4253 | 7 |
| GridDistanceMars | 1 | 1 | 1 | 2 |
| GridAnd | 1 | 1 | 1 | 1 |
| GridEquals | 16 | 1 | 16 | 1 |
| GridNot | 1 | 1 | 1 | 0 |
| GridOpFree | 1 | 0 | 1 | 0 |
| GridMask | 1 | 0 | 1 | 0 |
| GridDest | 1 | 0 | 1 | 0 |

