#!/usr/bin/env python3
"""Validate a fully captured repeated-run determinism cohort.

The validator is deliberately independent of the live launcher.  A future harness-only
capture writes one manifest plus uniquely named files for each run; this tool verifies
that the evidence can answer either branch of the 42S85E determinism ruling before any
result is interpreted.
"""

from __future__ import annotations

import argparse
import copy
import hashlib
import json
import re
import tempfile
from pathlib import Path
from typing import Any


EXPECTED_DISPLAYS = (
    "DISPLAY1 3840x2160@60 x=0 y=0",
    "DISPLAY2 2560x1440@59 x=3840 y=1",
    "DISPLAY3 2560x1440@59 x=-2560 y=14",
)
DISPLAY_READS = ("prelaunch", "startup", "shutdown_immediate", "shutdown_settled")
IMMUTABLE_FIELDS = (
    "source_head",
    "payload_sha256",
    "profile_sha256",
    "game_binary_sha256",
    "loaded_mods_sha256",
    "generated_script_sha256",
    "mission_inputs_sha256",
)
SEED_FIELDS = ("session", "initial_session", "surface", "underground", "passage")
PROCESS_ZERO_FIELDS = (
    "prelaunch_marsdebug_count",
    "prelaunch_listener_count",
    "postshutdown_marsdebug_count",
    "postshutdown_listener_count",
)
LOG_ZERO_FIELDS = ("lua_errors", "console_errors", "assertions", "crashes", "timeouts")
CHECKPOINTS = (
    ("pre_stock_generation", ("rng_state", "prefab_order", "generation_inputs")),
    ("stock_surface_output", ("surface_height", "surface_terrain", "object_census")),
    ("pre_z_transform", ("surface_height", "surface_terrain", "object_census")),
    ("post_z_transform", ("surface_height", "surface_terrain", "zone_stamp")),
    ("post_object_transform", ("object_census", "collision_census")),
    (
        "pre_init_buildable",
        ("surface_height", "surface_terrain", "passability", "buildable", "collision_census"),
    ),
    (
        "post_init_buildable",
        ("surface_height", "surface_terrain", "passability", "buildable", "collision_census"),
    ),
    (
        "post_process_buildable",
        ("surface_height", "surface_terrain", "passability", "buildable", "collision_census"),
    ),
    (
        "final_stable",
        (
            "surface_height",
            "underground_height",
            "surface_passability",
            "surface_buildable",
            "underground_passability",
            "underground_buildable",
            "object_census",
        ),
    ),
)
SHA256_RE = re.compile(r"^[0-9a-fA-F]{64}$")


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest().upper()


def nested(mapping: Any, key: str, errors: list[str], context: str) -> Any:
    if not isinstance(mapping, dict) or key not in mapping:
        errors.append(f"{context}: missing {key}")
        return None
    return mapping[key]


def checked_artifact(
    item: Any,
    artifact_root: Path,
    errors: list[str],
    context: str,
    used_paths: set[str],
) -> str | None:
    if not isinstance(item, dict):
        errors.append(f"{context}: artifact record is not an object")
        return None
    relative = item.get("path")
    expected_hash = item.get("sha256")
    expected_bytes = item.get("bytes")
    if not isinstance(relative, str) or not relative:
        errors.append(f"{context}: missing relative artifact path")
        return None
    relative_path = Path(relative)
    if relative_path.is_absolute():
        errors.append(f"{context}: artifact path must be relative: {relative}")
        return None
    resolved = (artifact_root / relative_path).resolve()
    try:
        resolved.relative_to(artifact_root)
    except ValueError:
        errors.append(f"{context}: artifact path escapes root: {relative}")
        return None
    normalized = relative_path.as_posix()
    if normalized in used_paths:
        errors.append(f"{context}: artifact path reused across capture records: {normalized}")
    used_paths.add(normalized)
    if not resolved.is_file():
        errors.append(f"{context}: artifact is missing: {normalized}")
        return None
    if not isinstance(expected_bytes, int) or expected_bytes <= 0:
        errors.append(f"{context}: bytes must be a positive integer")
    elif resolved.stat().st_size != expected_bytes:
        errors.append(
            f"{context}: byte mismatch {resolved.stat().st_size} != {expected_bytes}"
        )
    if not isinstance(expected_hash, str) or not SHA256_RE.fullmatch(expected_hash):
        errors.append(f"{context}: sha256 must be 64 hexadecimal characters")
        return None
    actual_hash = sha256(resolved)
    if actual_hash != expected_hash.upper():
        errors.append(f"{context}: sha256 mismatch {actual_hash} != {expected_hash.upper()}")
    return actual_hash


def analyze(manifest: dict[str, Any], artifact_root: Path) -> dict[str, Any]:
    artifact_root = artifact_root.resolve()
    errors: list[str] = []
    used_paths: set[str] = set()
    runs = manifest.get("runs")
    if manifest.get("schema") != "smr.ralph.determinism_capture_cohort.v1":
        errors.append("manifest: wrong schema")
    if not isinstance(runs, list) or len(runs) < 3:
        errors.append("manifest: at least three repeated runs are required")
        runs = []

    run_ids: set[str] = set()
    incident_ids: set[str] = set()
    immutable_rows: list[dict[str, Any]] = []
    seed_rows: list[dict[str, Any]] = []
    checkpoint_rows: list[list[dict[str, str | None]]] = []

    for index, run in enumerate(runs):
        context = f"run[{index}]"
        if not isinstance(run, dict):
            errors.append(f"{context}: run is not an object")
            continue
        run_id = run.get("run_id")
        if not isinstance(run_id, str) or not run_id:
            errors.append(f"{context}: missing run_id")
        elif run_id in run_ids:
            errors.append(f"{context}: duplicate run_id {run_id}")
        else:
            run_ids.add(run_id)
        if run.get("launcher") != "smr" or run.get("expanded") is not True:
            errors.append(f"{context}: run must be expanded and launched only through smr")

        immutable = nested(run, "immutable", errors, context)
        immutable_row: dict[str, Any] = {}
        for field in IMMUTABLE_FIELDS:
            value = nested(immutable, field, errors, f"{context}.immutable")
            immutable_row[field] = value
            if field.endswith("_sha256") and (
                not isinstance(value, str) or not SHA256_RE.fullmatch(value)
            ):
                errors.append(f"{context}.immutable.{field}: invalid sha256")
        immutable_rows.append(immutable_row)

        seeds = nested(run, "seeds", errors, context)
        seed_rows.append(
            {field: nested(seeds, field, errors, f"{context}.seeds") for field in SEED_FIELDS}
        )

        process = nested(run, "process", errors, context)
        for field in PROCESS_ZERO_FIELDS:
            if nested(process, field, errors, f"{context}.process") != 0:
                errors.append(f"{context}.process.{field}: expected zero")
        incident_id = nested(process, "tracked_incident_id", errors, f"{context}.process")
        if not isinstance(incident_id, str) or not incident_id:
            errors.append(f"{context}.process.tracked_incident_id: missing")
        elif incident_id in incident_ids:
            errors.append(f"{context}.process.tracked_incident_id: reused {incident_id}")
        else:
            incident_ids.add(incident_id)
        if nested(process, "stop_ok", errors, f"{context}.process") is not True:
            errors.append(f"{context}.process.stop_ok: expected true")

        log = nested(run, "log", errors, context)
        for field in LOG_ZERO_FIELDS:
            if nested(log, field, errors, f"{context}.log") != 0:
                errors.append(f"{context}.log.{field}: expected zero")

        display_reads = nested(run, "display_reads", errors, context)
        for state in DISPLAY_READS:
            actual = nested(display_reads, state, errors, f"{context}.display_reads")
            if actual != list(EXPECTED_DISPLAYS):
                errors.append(f"{context}.display_reads.{state}: exact tuple required")

        checkpoints = nested(run, "checkpoints", errors, context)
        if not isinstance(checkpoints, list):
            errors.append(f"{context}.checkpoints: expected ordered list")
            checkpoints = []
        actual_order = [item.get("name") if isinstance(item, dict) else None for item in checkpoints]
        required_order = [name for name, _ in CHECKPOINTS]
        if actual_order != required_order:
            errors.append(f"{context}.checkpoints: wrong order or set")
        capture_row: list[dict[str, str | None]] = []
        for checkpoint_index, (name, required_artifacts) in enumerate(CHECKPOINTS):
            if checkpoint_index >= len(checkpoints) or not isinstance(
                checkpoints[checkpoint_index], dict
            ):
                capture_row.append({})
                continue
            checkpoint = checkpoints[checkpoint_index]
            artifacts = nested(
                checkpoint, "artifacts", errors, f"{context}.checkpoints.{name}"
            )
            if not isinstance(artifacts, dict):
                artifacts = {}
            missing = sorted(set(required_artifacts) - set(artifacts))
            if missing:
                errors.append(f"{context}.checkpoints.{name}: missing artifacts {missing}")
            checkpoint_hashes: dict[str, str | None] = {}
            for artifact_name in sorted(artifacts):
                checkpoint_hashes[artifact_name] = checked_artifact(
                    artifacts[artifact_name],
                    artifact_root,
                    errors,
                    f"{context}.checkpoints.{name}.{artifact_name}",
                    used_paths,
                )
            capture_row.append(checkpoint_hashes)
        checkpoint_rows.append(capture_row)

    if immutable_rows and any(row != immutable_rows[0] for row in immutable_rows[1:]):
        errors.append("cohort: immutable inputs differ between runs")
    if seed_rows and any(row != seed_rows[0] for row in seed_rows[1:]):
        errors.append("cohort: exact seeds differ between runs")
    if checkpoint_rows:
        for checkpoint_index, (name, _) in enumerate(CHECKPOINTS):
            keysets = [set(row[checkpoint_index]) for row in checkpoint_rows]
            if any(keys != keysets[0] for keys in keysets[1:]):
                errors.append(f"cohort: instrumentation differs at {name}")

    earliest_divergence = None
    if not errors and checkpoint_rows:
        for checkpoint_index, (name, _) in enumerate(CHECKPOINTS):
            rows = [row[checkpoint_index] for row in checkpoint_rows]
            differing = [key for key in sorted(rows[0]) if len({row[key] for row in rows}) > 1]
            if differing:
                earliest_divergence = {"checkpoint": name, "artifacts": differing}
                break

    ok = not errors
    if not ok:
        classification = "invalid_capture"
        next_action = "repair the manifest or recapture; do not interpret determinism"
    elif earliest_divergence:
        classification = "divergence_reproduced"
        next_action = "isolate the differing producer and run the identical held-out cohort"
    else:
        classification = "three_repeats_identical"
        next_action = "identify and prove the uncontrolled field in the historical runs"
    return {
        "schema": "smr.ralph.determinism_capture_protocol_check.v1",
        "ok": ok,
        "classification": classification,
        "run_count": len(runs),
        "checkpoint_count": len(CHECKPOINTS),
        "earliest_divergence": earliest_divergence,
        "errors": errors,
        "next_action": next_action,
    }


def artifact_record(path: Path, root: Path) -> dict[str, Any]:
    return {
        "path": path.relative_to(root).as_posix(),
        "bytes": path.stat().st_size,
        "sha256": sha256(path),
    }


def self_test() -> dict[str, Any]:
    with tempfile.TemporaryDirectory() as directory:
        root = Path(directory).resolve()
        hash_a = "A" * 64
        base_run: dict[str, Any] = {
            "run_id": "repeat-1",
            "launcher": "smr",
            "expanded": True,
            "immutable": {
                "source_head": "1" * 40,
                "payload_sha256": hash_a,
                "profile_sha256": hash_a,
                "game_binary_sha256": hash_a,
                "loaded_mods_sha256": hash_a,
                "generated_script_sha256": hash_a,
                "mission_inputs_sha256": hash_a,
            },
            "seeds": {field: index for index, field in enumerate(SEED_FIELDS)},
            "process": {
                **{field: 0 for field in PROCESS_ZERO_FIELDS},
                "tracked_incident_id": "incident-1",
                "stop_ok": True,
            },
            "log": {field: 0 for field in LOG_ZERO_FIELDS},
            "display_reads": {state: list(EXPECTED_DISPLAYS) for state in DISPLAY_READS},
            "checkpoints": [],
        }
        runs = []
        for run_index in range(3):
            run = copy.deepcopy(base_run)
            run["run_id"] = f"repeat-{run_index + 1}"
            run["process"]["tracked_incident_id"] = f"incident-{run_index + 1}"
            for checkpoint_name, artifact_names in CHECKPOINTS:
                artifacts = {}
                for artifact_name in artifact_names:
                    path = root / f"r{run_index + 1}_{checkpoint_name}_{artifact_name}.bin"
                    path.write_bytes(f"{checkpoint_name}:{artifact_name}".encode("utf-8"))
                    artifacts[artifact_name] = artifact_record(path, root)
                run["checkpoints"].append({"name": checkpoint_name, "artifacts": artifacts})
            runs.append(run)
        manifest = {"schema": "smr.ralph.determinism_capture_cohort.v1", "runs": runs}

        results: dict[str, bool] = {}
        report = analyze(copy.deepcopy(manifest), root)
        results["three_identical_runs_green"] = (
            report["ok"] and report["classification"] == "three_repeats_identical"
        )

        divergent = copy.deepcopy(manifest)
        item = divergent["runs"][2]["checkpoints"][1]["artifacts"]["surface_height"]
        divergent_path = root / item["path"]
        divergent_path.write_bytes(b"different-stock-surface")
        divergent["runs"][2]["checkpoints"][1]["artifacts"]["surface_height"] = artifact_record(
            divergent_path, root
        )
        report = analyze(divergent, root)
        results["earliest_divergence_detected"] = report["earliest_divergence"] == {
            "checkpoint": "stock_surface_output",
            "artifacts": ["surface_height"],
        }

        # Restore the shared fixture before testing independent invalid cases.
        divergent_path.write_bytes(b"stock_surface_output:surface_height")
        manifest["runs"][2]["checkpoints"][1]["artifacts"]["surface_height"] = artifact_record(
            divergent_path, root
        )
        mismatched = copy.deepcopy(manifest)
        mismatched["runs"][2]["immutable"]["profile_sha256"] = "B" * 64
        results["immutable_mismatch_red"] = not analyze(mismatched, root)["ok"]

        missing = copy.deepcopy(manifest)
        del missing["runs"][1]["checkpoints"][5]["artifacts"]["buildable"]
        results["missing_checkpoint_artifact_red"] = not analyze(missing, root)["ok"]

        reused = copy.deepcopy(manifest)
        reused["runs"][1]["checkpoints"][0]["artifacts"]["rng_state"] = copy.deepcopy(
            reused["runs"][0]["checkpoints"][0]["artifacts"]["rng_state"]
        )
        results["reused_capture_path_red"] = not analyze(reused, root)["ok"]

        corrupt = copy.deepcopy(manifest)
        corrupt["runs"][0]["checkpoints"][0]["artifacts"]["rng_state"]["sha256"] = "C" * 64
        results["content_hash_mismatch_red"] = not analyze(corrupt, root)["ok"]

        return {
            "schema": "smr.ralph.determinism_capture_protocol_self_test.v1",
            "checks": results,
            "passed": sum(results.values()),
            "total": len(results),
            "ok": all(results.values()),
        }


def main() -> int:
    parser = argparse.ArgumentParser()
    group = parser.add_mutually_exclusive_group(required=True)
    group.add_argument("--manifest", type=Path)
    group.add_argument("--self-test", action="store_true")
    parser.add_argument("--artifact-root", type=Path)
    parser.add_argument("--out", type=Path)
    args = parser.parse_args()

    if args.self_test:
        report = self_test()
    else:
        if args.artifact_root is None:
            parser.error("--artifact-root is required with --manifest")
        manifest = json.loads(args.manifest.read_text(encoding="utf-8"))
        report = analyze(manifest, args.artifact_root)
    rendered = json.dumps(report, indent=2, sort_keys=True) + "\n"
    if args.out:
        args.out.parent.mkdir(parents=True, exist_ok=True)
        args.out.write_text(rendered, encoding="utf-8")
    print(rendered, end="")
    return 0 if report["ok"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
