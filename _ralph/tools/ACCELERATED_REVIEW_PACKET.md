# Accelerated Ralph review packet

`build_accelerated_review_packet.py` shortens repeated review of an unchanged candidate. It does
not change, cache, or replace the final cold acceptance run.

The packet executes only gates declared `pure: true`. Each gate's cache key binds the review-tool
bytes, Python executable bytes and version, command executable bytes, canonical task/gate content,
and byte/topology receipts for every declared task input, reference, context, gate input, and local
path argument. A cache entry carries a second integrity hash; malformed, wrong-key, or modified cache
data is a hard error rather than a cache miss.

The spec also supplies exact receipts for the Git HEAD/tree/clean state, stage topology, deployed
file equality, and fresh-run cold state. Causal log extraction is bounded by line count. Bracketed
log records without a configured severity are rejected, as are known severities outside the spec's
explicit allow-list. The packet's normalized gate, receipt, and causal-log result is compared to the
last approved semantic snapshot when `--approved` is supplied.

Every live run requires a short independent delta review. The packet emits that minimum explicitly
as `review_tier.minimum_review=short-independent-delta`; a cache hit never waives it. It promotes the
run to `full_review_required=true` when production, task, rule, reference, interpreter, or review-tool
contract bytes change; when an unchanged core gate misses or cache integrity fails; when evidence or
topology drifts; when a causal window contains unknown/severe records; or when a gate/log failure is
unexplained. The decision includes machine-readable reasons and fails closed if its tier contract is
absent.

Specs classify complete byte inputs under `review_tiering.production`, `task`, `rules`, `references`,
`tool_contract`, and `stage_only`. Gates likewise use `review_scope: core` or `stage-only`. A change
confined to a staged schema/oracle reruns that gate and still requires the short independent delta
review, but does not by itself force a full production reread. All production/rule/reference/tool
gates remain core. The final cold acceptance is never cached in either tier.

Typical command:

```powershell
python _ralph/tools/build_accelerated_review_packet.py `
  --spec _ralph/tmp/<stage>/accelerated_review_spec.json `
  --out _ralph/runs/<run>/accelerated_review_packet.json `
  --cache _ralph/cache/accelerated-review `
  --approved _ralph/references/last_approved_review_packet.json
```

Future stage non-launch preflights should run this command before their ordinary uncached stage
contract checks and verify the packet schema, `ok=true`, exact packet hash, receipts, and semantic
delta. The first review after a production/stage/tool/context/reference change is intentionally a
cache miss; routine unchanged re-review should finish in roughly 2–5 minutes. A reviewer still runs
the normal cold generator acceptance afterward.

Run the adversarial executable test with:

```powershell
python _ralph/tools/test_accelerated_review_packet.py
```

It proves each full-review trigger plus the stage-only non-trigger, mandatory short review, cache hits,
and fail-closed handling of corruption, mutations, semantic/topology drift, and log severity.
