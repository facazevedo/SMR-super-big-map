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

It proves cache hits and fail-closed handling of corruption, input/tool/interpreter-version mutation,
semantic drift, topology drift, and unknown log severity.
