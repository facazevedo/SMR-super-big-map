#!/usr/bin/env python3
"""Build, compare, and event-watch compact ordered checkpoint manifests.

Hash-only candidate runs discard each completed artifact immediately after its exact
size/SHA-256 is recorded.  A first mismatch writes an abort sentinel and stops scoring
later artifacts.  Observation modes are part of reference identity: a retaining Full
run may only be compared with an accepted-control reference recorded in Full mode.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import shutil
import subprocess
import sys
import time
from pathlib import Path


REFERENCE_SCHEMA = "smr.ralph.checkpoint_reference.v1"
COMPARE_SCHEMA = "smr.ralph.checkpoint_compare.v1"
OBSERVER_MODES = ("HashOnly", "Full")
STAGE_ORDER = (
    ("pre_stock_generation", ("rng_state", "prefab_order", "generation_inputs")),
    ("stock_surface_output", ("surface_height", "surface_terrain", "object_census")),
    ("pre_z_transform", ("surface_height", "surface_terrain", "object_census")),
    ("post_z_transform", ("surface_height", "surface_terrain", "zone_stamp")),
    ("post_object_transform", ("object_census", "collision_census")),
    ("pre_init_buildable", ("surface_height", "surface_terrain", "passability", "buildable", "collision_census")),
    ("post_init_buildable", ("surface_height", "surface_terrain", "passability", "buildable", "collision_census")),
    ("post_process_buildable", ("surface_height", "surface_terrain", "passability", "buildable", "collision_census")),
    ("final_stable", ("surface_height", "underground_height", "surface_passability", "surface_buildable",
                      "underground_passability", "underground_buildable", "object_census")),
)


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1 << 20), b""):
            digest.update(block)
    return digest.hexdigest().upper()


def canonical_sha256(payload: object) -> str:
    encoded = json.dumps(payload, ensure_ascii=False, separators=(",", ":"), sort_keys=True).encode()
    return hashlib.sha256(encoded).hexdigest().upper()


def extension(kind: str) -> str:
    return ".raw" if "height" in kind or "terrain" in kind else ".bin"


def checkpoint_rows(base: Path, *, require: bool) -> list[dict]:
    rows = []
    for stage, kinds in STAGE_ORDER:
        for kind in kinds:
            suffix = f"-{stage}-{kind}{extension(kind)}"
            path = Path(str(base) + suffix)
            if not path.is_file():
                if require:
                    raise ValueError(f"missing checkpoint artifact: {path}")
                rows.append({"id": f"{stage}:{kind}", "suffix": suffix, "path": str(path),
                             "present": False})
                continue
            rows.append({"id": f"{stage}:{kind}", "suffix": suffix, "path": str(path),
                         "present": True, "bytes": path.stat().st_size, "sha256": sha256(path)})
    return rows


def atomic_json(path: Path, payload: object) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(f".{path.name}.{os.getpid()}.{time.time_ns()}.tmp")
    temporary.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    temporary.replace(path)


def validate_sha(value: str, label: str) -> str:
    if len(value) != 64 or any(c not in "0123456789abcdefABCDEF" for c in value):
        raise ValueError(f"{label} must be a SHA-256")
    return value.upper()


def command_build(args: argparse.Namespace) -> int:
    base = args.reference_base.resolve()
    rows = checkpoint_rows(base, require=True)
    compact_rows = [{key: row[key] for key in ("id", "suffix", "bytes", "sha256")} for row in rows]
    identity = {
        "coordinate": "14N134W",
        "preset": "RoughTerrain",
        "source_commit": args.source_commit,
        "task_sha256": sha256(args.task.resolve()),
        "scenario_input_sha256": sha256(args.scenario_input.resolve()),
        "capture_tool_sha256": sha256(args.capture_tool.resolve()),
        "observer_mode": args.observer_mode,
    }
    if args.task_sha256:
        expected = validate_sha(args.task_sha256, "--task-sha256")
        if identity["task_sha256"] != expected:
            raise ValueError("task content does not match --task-sha256")
    manifest = {
        "schema": REFERENCE_SCHEMA, "ok": True, "identity": identity,
        "checkpoint_count": len(compact_rows), "checkpoints": compact_rows,
        "checkpoint_aggregate_sha256": canonical_sha256(compact_rows),
        "full_capture_bytes": sum(row["bytes"] for row in compact_rows),
    }
    atomic_json(args.out.resolve(), manifest)
    print(json.dumps(manifest, indent=2, sort_keys=True))
    return 0


def load_reference(path: Path) -> dict:
    manifest = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(manifest, dict) or manifest.get("schema") != REFERENCE_SCHEMA or manifest.get("ok") is not True:
        raise ValueError("invalid checkpoint reference manifest")
    rows = manifest.get("checkpoints")
    if not isinstance(rows, list) or len(rows) != sum(len(kinds) for _, kinds in STAGE_ORDER):
        raise ValueError("checkpoint reference has the wrong row count")
    if manifest.get("checkpoint_aggregate_sha256") != canonical_sha256(rows):
        raise ValueError("checkpoint reference aggregate is invalid")
    identity = manifest.get("identity", {})
    if identity.get("coordinate") != "14N134W" or identity.get("preset") != "RoughTerrain":
        raise ValueError("checkpoint reference identity is not 14N134W RoughTerrain")
    return manifest


def reference_observer_mode(manifest: dict) -> tuple[str, bool]:
    """Return the reference observation mode and whether it was inferred.

    The frozen v888 manifest predates explicit mode tagging.  It is retained only for
    the low-retention HashOnly screen that has reproduced it 36/36.  Treating an
    untagged reference as Full caused the checkpoint-13 false rejection, so legacy
    inference deliberately fails closed for every retaining comparison.
    """

    identity = manifest.get("identity", {})
    mode = identity.get("observer_mode")
    if mode is None:
        return "HashOnly", True
    if mode not in OBSERVER_MODES:
        raise ValueError(f"checkpoint reference has invalid observer_mode: {mode!r}")
    return mode, False


def verify_reference_inputs(
    manifest: dict, args: argparse.Namespace, candidate_mode: str
) -> tuple[str, bool]:
    identity = manifest["identity"]
    actual = {
        "source_commit": args.expected_reference_commit,
        "task_sha256": sha256(args.task.resolve()),
        "scenario_input_sha256": sha256(args.reference_scenario_input.resolve()),
        "capture_tool_sha256": sha256(args.capture_tool.resolve()),
    }
    mismatches = {
        key: {"expected": identity.get(key), "actual": value}
        for key, value in actual.items() if identity.get(key) != value
    }
    if mismatches:
        raise ValueError("checkpoint reference identity mismatch: "
                         + json.dumps(mismatches, sort_keys=True))
    reference_mode, inferred = reference_observer_mode(manifest)
    if reference_mode != candidate_mode:
        qualifier = "legacy untagged " if inferred else ""
        raise ValueError(
            f"observer-mode mismatch: {qualifier}reference is {reference_mode}, "
            f"candidate is {candidate_mode}; record an accepted-control "
            f"{candidate_mode} reference before comparing this mode"
        )
    return reference_mode, inferred


def command_compare(args: argparse.Namespace) -> int:
    reference = load_reference(args.reference.resolve())
    candidate_mode = "HashOnly" if args.discard else "Full"
    reference_mode, inferred_mode = verify_reference_inputs(reference, args, candidate_mode)
    actual_rows = checkpoint_rows(args.candidate_base.resolve(), require=False)
    checked = []
    first_mismatch = None
    for expected, actual in zip(reference["checkpoints"], actual_rows, strict=True):
        matched = (actual.get("present") is True and actual.get("bytes") == expected["bytes"]
                   and actual.get("sha256") == expected["sha256"])
        row = {"id": expected["id"], "suffix": expected["suffix"],
               "present": actual.get("present", False), "bytes": actual.get("bytes"),
               "sha256": actual.get("sha256"), "expected_bytes": expected["bytes"],
               "expected_sha256": expected["sha256"], "matched": matched}
        checked.append(row)
        if args.discard and actual.get("present"):
            Path(actual["path"]).unlink()
            row["discarded_after_hash"] = True
        if not matched:
            first_mismatch = row
            break
    result = {
        "schema": COMPARE_SCHEMA, "ok": first_mismatch is None,
        "mode": candidate_mode, "checked": len(checked),
        "candidate_observer_mode": candidate_mode,
        "reference_observer_mode": reference_mode,
        "reference_observer_mode_inferred": inferred_mode,
        "mode_matched_reference": True,
        "event_driven": False, "checkpoints": checked, "first_mismatch": first_mismatch,
        "full_capture_retained": not args.discard,
    }
    atomic_json(args.out.resolve(), result)
    print(json.dumps(result, indent=2, sort_keys=True))
    return 0 if result["ok"] else 1


def command_watch(args: argparse.Namespace) -> int:
    reference = load_reference(args.reference.resolve())
    reference_mode, inferred_mode = verify_reference_inputs(reference, args, args.mode)
    powershell = shutil.which("pwsh") or shutil.which("powershell")
    if powershell is None:
        raise ValueError("PowerShell is required for event-driven checkpoint watching")
    script = Path(__file__).with_name("watch_checkpoints.ps1")
    command = [powershell, "-NoProfile", "-NonInteractive", "-File", str(script),
               "-ReferenceManifest", str(args.reference.resolve()),
               "-CandidateBase", str(args.candidate_base.resolve()),
               "-Verdict", str(args.out.resolve()), "-Mode", args.mode,
               "-ExpectedReferenceMode", reference_mode,
               "-ReferenceModeInferred", str(inferred_mode),
               "-TimeoutSeconds", str(args.timeout_seconds)]
    if args.abort_sentinel:
        command.extend(["-AbortSentinel", str(args.abort_sentinel.resolve())])
    if args.ready_sentinel:
        command.extend(["-ReadySentinel", str(args.ready_sentinel.resolve())])
    return subprocess.run(command, check=False).returncode


def add_reference_identity_arguments(parser: argparse.ArgumentParser) -> None:
    parser.add_argument("--expected-reference-commit", required=True)
    parser.add_argument("--task", type=Path, required=True)
    parser.add_argument("--reference-scenario-input", type=Path, required=True)
    parser.add_argument("--capture-tool", type=Path, required=True)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)
    build = sub.add_parser("build-reference")
    build.add_argument("--reference-base", type=Path, required=True)
    build.add_argument("--source-commit", required=True)
    build.add_argument("--task", type=Path, required=True)
    build.add_argument("--task-sha256")
    build.add_argument("--scenario-input", type=Path, required=True)
    build.add_argument("--capture-tool", type=Path, required=True)
    build.add_argument("--observer-mode", choices=OBSERVER_MODES, required=True,
                       help="observation mode used while producing the reference files")
    build.add_argument("--out", type=Path, required=True)
    build.set_defaults(func=command_build)
    compare = sub.add_parser("compare-existing")
    compare.add_argument("--reference", type=Path, required=True)
    add_reference_identity_arguments(compare)
    compare.add_argument("--candidate-base", type=Path, required=True)
    compare.add_argument("--out", type=Path, required=True)
    compare.add_argument("--discard", action="store_true")
    compare.set_defaults(func=command_compare)
    watch = sub.add_parser("watch")
    watch.add_argument("--reference", type=Path, required=True)
    add_reference_identity_arguments(watch)
    watch.add_argument("--candidate-base", type=Path, required=True)
    watch.add_argument("--out", type=Path, required=True)
    watch.add_argument("--abort-sentinel", type=Path)
    watch.add_argument("--ready-sentinel", type=Path)
    watch.add_argument("--mode", choices=("HashOnly", "Full"), default="HashOnly")
    watch.add_argument("--timeout-seconds", type=int, default=1800)
    watch.set_defaults(func=command_watch)
    return parser.parse_args()


if __name__ == "__main__":
    try:
        args = parse_args()
        raise SystemExit(args.func(args))
    except (OSError, ValueError, json.JSONDecodeError, subprocess.SubprocessError) as exc:
        print(f"checkpoint artifact error: {exc}", file=sys.stderr)
        raise SystemExit(2)
