# Accepted v994: reference START-to-T1 average84.666s

The user's revised goal is achieved: reference arithmetic mean strictly below85s,
with all five additional correctness scenarios and existing terrain fixes retained.
This is not a claim that every run/site is below85s or that any site is below80s.

Production implementation065ab3f5df24d9b902e56ac3e50f8746f3e19fa9, v994/generator306.
All nine cold acceptance runs used frozen1182750f36e39653b27382535ee01c5ca8d4533b.
Later commits record evidence only. Deployment38/38 matches; current production
also matches every hash from the passing85-command offline run.

## Timing

Reference A/B/C:84.212 /85.294 /84.492s; arithmetic mean84.666s. All scheduled
samples retained, none replaced. Native control28.701s is excluded from the mean.
Prior acceptedv987 samples88.557 /86.046 /86.606s average87.069667s; observed
difference2.403667s. Three-run acceptance is not a confidence bound or a guarantee
for future starts. Private actual-helper target-sequence savings235/231ms do not
explain the entire observed startup difference or establish causal significance.

Five-site timings, correctness PASS throughout:15S67E89.197s,24S74W87.921s,
45S120W80.965s,61N136W92.001s,17S11W87.049s. These are informational under the
user's revised scope; two sites were slightly slower than their recorded baseline.

## Requirement-by-requirement closure

| Requirement | Evidence and result |
| --- | --- |
| Reference arithmetic mean<85s, all three runs retained | v994_reference/reference_average_audit.json:84.666s,PASS |
| Reference predecessor/repeat/native-control preservation | v994_reference/reference_audit.json: no issues, complete grids/placements/individual rocks/private streams |
| Five fresh correctness scenarios | v994_matrix/verification.json and five judgments: all exact predecessor pairs and eight automated gates PASS |
| Seed parity | Four private fields unchanged in every expanded reference/site; complete paired outputs; unchanged native weighting/similarity/random consumers reviewed in v994_playable_distance_integration.md |
| Process/provenance | v994_review.json: nine unique fresh hidden owned identities, same checkpoint, correct loaded payload, normal flushed shutdowns, no error signatures |
| Existing terrain fixes and required work | Only sbm_map_generation.lua and version metadata differ from acceptedv987; no terrain/rock/seed engine changes; raw unions, individual records, eager bootstrap, serial projection/raster and both required pre-T1 rebuilds retained |
| Offline regressions | v994_offline_2/all_results.json: all85PASS, including all83 accepted commands unchanged; current source matches source_hashes.json |
| Actual cached outputs, not only model inference | v994_native_reference and v994_native_61n full audits: every observed primary/secondary/raw field exact; all guards, writes, eight allocations/frees, restored hooks, no invalidations |
| Helper performance qualification | v994_helper_replay_reference: actual helper with calibration/guards/allocation/cleanup, both orders faster; limits explicitly stated in v994_cold_protocol.md |
| Final accepted deployment | v994_review.json deployment38/38PASS; measured production/current-worktree diff empty |

The eight automated rule names are entrances-glued, entrances-not-in-ring,
ring-content, single-start-reveal, badges-pre-reveal, decor-rules, no-errors and
underground-first-access. Raw seed-parity/process gates remain marked pending
because those deliberately require the separate source/provenance review, which
v994_review.json closes. Historical raw judgments were not rewritten.

## What changed

The Playable placement loop reuses D(place) within each placement epoch and one
fixed D(bounds), preserving the raw union boundary and constructing its distance
with native minimum. Secondary destinations receive complete independent copies
before native weighting. First calls calibrate native return shapes; bounded
procedure/coroutine scope, source guards, fallback and owned cleanup remain active.
No diagnostic oracle/profiler code is deployed. All diagnostic artifacts and the
initial comparator/fixture failures are preserved, separate from cold acceptance.

Reference batch63426 and five-site batch68206 both CLOSEDexit0. Final fresh-game
guard confirms no live game. No required implementation, acceptance scenario or
review remains outstanding for the revised goal.
