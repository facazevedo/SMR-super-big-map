# Surface-loading Ralph fast lane

This pipeline rejects non-equivalent or unpromising candidates before another full
expanded-map capture. It is diagnostic only. A survivor still needs the ordinary
default-off, observer-free cold 36/36 comparison, independent cold T0-to-T1 timing,
and every placement, terrain, spacing, audit, and visual gate.

## Validation order

1. Run parsing and policy checks through `evidence_cache.py`. A cache hit is valid only
   when the command and every declared source/tool/task/scenario/expected digest match.
2. For an isolated hot operation, run its compact shadow oracle and microbenchmark.
   For protected-resource indexing, use the real corpus with
   `guard_shadow_oracle.py`.
3. Start `checkpoint_artifacts.py watch` in `HashOnly` mode before launching the game.
   It uses `FileSystemWatcher`, compares checkpoints in reference order, writes an
   abort sentinel on the first difference, and deletes each large candidate artifact
   immediately after hashing.
4. Terminate a red candidate as soon as the abort receipt exists. Do not generate or
   score later artifacts.
5. Only a hash-only 36/36 survivor may be rerun in `Full` mode. A Full verdict must use
   a separate accepted-control reference recorded under Full retention; cross-mode
   reference comparisons fail closed. Full evidence remains subject to the ordinary
   observer-free cold gates.

## Real protected-guard corpus

The default production path has no active observer. In a diagnostic-only game, set
`g_SbmGuardCorpusOutPath` to a fresh path and set `g_SbmGuardCorpusIdentity` with these
single-line fields before loading `guard_corpus_probe.lua`:

- `coordinate=14N134W`
- `preset=RoughTerrain`
- `source_commit`
- `terrain_source_sha256`
- `scenario_input_sha256`
- `task_sha256`

Load the probe after the mod modules exist and before expanded surface generation.
It records every preparation/repair call, preserving guard and pass order. Convert and
screen it with the commands below, then call `g_SbmGuardCorpusProbeDisarm()` before
using the session for any unrelated diagnostic work:

```powershell
python _ralph/tools/guard_shadow_oracle.py convert `
  --observation <guard-observation.tsv> --out <guard-corpus.json>
python _ralph/tools/guard_shadow_oracle.py run `
  --corpus <guard-corpus.json> --out <guard-oracle-report.json>
```

The analytic certificate is exhaustive: every pruned guard must have a strictly
positive center-distance margin beyond `visit_radius + guard.radius`, while retained
guards must be the exact ordered subsequence. Therefore no visited pixel can match a
pruned guard and the first matching identity is preserved. Integer sampling and four
known-bad mutations independently test the implementation.

## Content-addressed offline gates

Declare every file/tree input and all mandatory identity fields. Existing command-file
arguments are fingerprinted automatically.

```powershell
python _ralph/tools/evidence_cache.py `
  --gate-id offline-outer-ring-policy `
  --input Code --input _ralph/tools/parity/outer_ring_policy_check.py `
  --context source_commit=<commit> `
  --context task_sha256=<sha256> `
  --context scenario_input_sha256=<sha256> `
  --context schema=outer-ring-policy.v12 `
  --context expected_digest_sha256=<sha256> `
  --evidence <receipt.json> -- `
  python _ralph/tools/parity/outer_ring_policy_check.py
```

Gate IDs containing `cold`, `timing`, `visual`, or `final` are rejected. Failed gates
are never cached. Deployment audits may be cached only when both the source payload
and external Mods directory are declared tree inputs, so any file change invalidates
the key.

## Ordered checkpoint reference and watcher

Build the compact frozen reference once from the accepted 36-file capture:

```powershell
python _ralph/tools/checkpoint_artifacts.py build-reference `
  --reference-base <accepted-capture-prefix> --source-commit <commit> `
  --task _ralph/tasks/surface-loading-under-60s-rough.md `
  --scenario-input <pinned-generation-script> `
  --capture-tool _ralph/tools/parity/determinism_capture_probe.lua `
  --observer-mode HashOnly `
  --out <checkpoint-reference.json>
```

Start the watcher before candidate generation:

```powershell
python _ralph/tools/checkpoint_artifacts.py watch `
  --reference <checkpoint-reference.json> --candidate-base <fresh-prefix> `
  --expected-reference-commit <accepted-reference-commit> `
  --task _ralph/tasks/surface-loading-under-60s-rough.md `
  --reference-scenario-input <pinned-reference-generation-script> `
  --capture-tool _ralph/tools/parity/determinism_capture_probe.lua `
  --out <hash-verdict.json> --abort-sentinel <abort.json> --mode HashOnly
```

Use `--mode Full` only for a prior hash-only survivor and only with a reference built
from unchanged accepted production under the same Full observation protocol. Build
that reference with `--observer-mode Full`. Legacy untagged references are valid only
for HashOnly and are rejected for Full. The watcher is event-driven; it does not poll
checkpoint files on a timer.

## Optimization scheduling

Work on exactly one optimization family at a time. Select the phase with the largest
measured exclusive cold cost and a behavior-preserving implementation route. Exhaust
that family until it is accepted or code-level evidence shows no material remaining
savings, then re-profile the accepted build and choose the new largest candidate.
Never run two game instances or timing samples concurrently.
