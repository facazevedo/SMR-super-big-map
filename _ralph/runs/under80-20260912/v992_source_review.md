# v992: native Filler mask cache, correctness passes; NOT promoted

Production implementation343bee6, cold checkpointb38f4c0; based only on accepted
56fbf44/v987, not combined with rejectedv988-v991. Exactly three production files:
sbm_map_generation.lua adds the scoped helper/transaction integration;
sbm_version.lua changes generator299->304 (sector76 unchanged); metadata987->992
and release text. All terrain/decor/rock/other production files remain accepted.

## Source and RNG review

See v992_filler_integration.md for the full source-lifetime/ownership proof and
conditional native API domain. The helper uses the supported global-owner bridge,
not debug/_ENV discovery. It composes current procedure boundaries, leaving class
Generate/DoGenerate/OnGenerateLogic identities unchanged. Only this generator's
Filler coroutine can use cached masks. Unsigned matching grids, native allocation/
distance-transform lineage, exact five-argument integer-subtype masks and bounded
memory qualify. Native source/caller grids are never owned/freed. Only full mask
copies substitute native thresholding; mutable placement/similarity intersections
and each original seeded selection remain live and in original order.

The actual stock Filler source at RandomMapGenerator.lua1771-1833 creates a distance
field once, reads it for radius masks and never mutates it. Prior native shadows
certified every request/source on reference and61N. Production conservatively
invalidates before known source mutations and checks a full final source guard.
The latter cannot detect arbitrary mutate-then-restore code; that behavior is
absent from the supported source/captures and is not assumed generally safe.
Fractional arguments, including3.0, pass to native rather than aliasing integer
cache keys. Supported hits return destination; native miss/fallback tuples retain
nil positions. Every resource and owned global/class hook restores on normal,
partial-install and native-error paths; errors latch explicitly and prohibit
continued expanded work after the required outer transactions are restored.

No new random call, alternative PRNG/selection, deferred write, changed candidate,
skipped terrain operation, truncated decor coverage or omitted object/support
sample. Immediate and scheduled pre-T1 rebuilds, eager native UG bootstrap, serial
raster/projection and source-view restoration remain in their original ordering.
No engine/OS/settings/other-mod change or scenario-specific optimization. Native
control does not install this expanded-UG path. Accepted visuals are inherited
through exact full outputs only; no new screenshot/visual inspection claim.

## Actual production verification

All83 accepted regression commands replayed unchanged, plus actual-helper and
source-transaction tests:85commands PASS, frozen source hashes retained in
v992_offline. Helper fixture2414 checks includes exact masks, tuple holes, native
fallback, LRU/bounds, cross-thread isolation/mutation, source-guard mismatch,
partial install, rebound hooks, clone/copy/free/native faults and missing ProcEnd.
Initial test-owned GridRepack scratch leak was fixed in the fixture, not hidden.

Integrated reference9429/PID50416 and61N66661/PID43328 at343bee6 CLOSED PASS,
full predecessor/grid/individualrock/four-private-field comparison,95/94 native
spans/two generations, normally flushed logs/no errors. Actual production cache
handled1524/1798 calls with1519/1793hits,5misses/clones; one source guard and no
invalidations. Maskpayload<=16MiB, total conservative scratch bound23592960B,
peak8owned/all8freed/live0, hooks restored. These are real production substitutions,
not shadow outputs. The prior private735..857ms kernel saving remains separate
from startup timing; integrated parity alone never qualified promotion.

## Frozen nine-process cold result

Reference session53616 and five-site session23298 CLOSED exit0. HEAD/deployment
remainedb38f4c0 throughout both finite batches, no code edits/heavy experiments,
rescue samples, erased regressions or pre-existing game reuse. Every owned process
closed normally with flushed logs; all sites have exact predecessor/private/rock
outputs. Reference full audit issues[], including repeated outputs and native
control. Complete automated gates and source/process reviews are recorded in
v992_all_ten_rules_review.json; pending raw source/process labels are not rewritten.

Reference84.147/83.445/86.400s, median84.147 versus86.606s:2.459s/2.839% observed
improvement. Native control29.835 versus29.156s. The entire reference difference
cannot be attributed causally to the narrower private mask gain from these runs.

| Site | Acceptedv987 s | Candidatev992 s | Saving s |
| --- | ---: | ---: | ---: |
| Reference median | 86.606 | 84.147 | 2.459 |
| 15S67E | 88.653 | 90.859 | -2.206 |
| 24S74W | 88.711 | 90.800 | -2.089 |
| 45S120W | 82.053 | 85.341 | -3.288 |
| 61N136W | 92.125 | 90.707 | 1.418 |
| 17S11W | 86.546 | 85.667 | 0.879 |

Three measured slowdowns, despite exact outputs and improvements on reference,
61N and17S. No statistical significance or causal attribution is inferred from
single-site deltas. all_scenarios_faster=false; all-site<80 and<85 both false.
Candidate NOT promoted. Restore exact accepted56fbf44/v987 production and normal
deployment after preserving this review and raw evidence. No unchanged cache
retry or combining rejected micro-optimizations is justified by these results.

Next independent Astra recommendation: a qualified decor rejection fast path,
first privately replaying complete candidate/outcome/cursor/RNG traces and timing
the whole pass including preparation. Preserve matcher failure retries, no_match
precedence, all cursor invocations and both append-only circle lifetimes. The
fresh61N9.617s decor span is a stage cost, not a promised saving. Goal remains ACTIVE.

Restoration completed: actualCode/metadata/items equals56fbf44/v987 exactly,
generator299/sector76, syntaxPASS, standard38-filedeployment auditPASS. Candidate
implementation and all raw evidence remain in history. No live game remains.
