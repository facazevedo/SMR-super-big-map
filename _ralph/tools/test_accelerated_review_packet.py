#!/usr/bin/env python3
"""Executable adversarial tests for build_accelerated_review_packet.py."""

from __future__ import annotations

import json
from pathlib import Path
import sys
import tempfile

import build_accelerated_review_packet as packet


def write(path: Path, text: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text, encoding="utf-8", newline="\n")


def file_expectation(path: Path) -> dict[str, object]:
    return {"bytes": path.stat().st_size, "sha256": packet.sha_file(path)}


def make_spec(root: Path) -> Path:
    stage = root / "stage"
    run = root / "run"
    write(stage / "asset.txt", "stage-asset\n")
    write(run / "reference.json", "{\"reference\":true}\n")
    write(root / "input.txt", "alpha\n")
    write(root / "context.txt", "task-context\n")
    write(root / "reference.txt", "reference-bytes\n")
    write(root / "gate.py",
          "from pathlib import Path\nprint(Path('input.txt').read_text().strip())\n")
    write(root / "causal.log", "[INFO] causal ready\nneutral context\n")
    spec = {
        "schema": packet.SPEC_SCHEMA,
        "task": {"id": "test-review", "context": "exact synthetic task bytes"},
        "task_inputs": ["input.txt"],
        "references": ["reference.txt"],
        "context": ["context.txt"],
        "gates": [{
            "id": "pure-gate", "pure": True,
            "command": [sys.executable, "gate.py"], "cwd": ".",
            "inputs": ["input.txt", "gate.py"], "timeout_seconds": 30,
        }],
        "receipts": {
            "topologies": [{
                "id": "stage", "root": "stage",
                "expected": {"directories": [], "files": {
                    "asset.txt": file_expectation(stage / "asset.txt")}},
            }],
            "cold_state": {"root": "run", "directories": [], "files": {
                "reference.json": file_expectation(run / "reference.json")}},
        },
        "logs": [{
            "id": "causal", "path": "causal.log", "causal_patterns": ["causal"],
            "severity_rules": [{"pattern": r"^\[INFO\]", "severity": "info"}],
            "allowed_severities": ["info"], "before": 0, "after": 1,
            "maximum_lines": 8,
        }],
    }
    spec_path = root / "spec.json"
    packet.atomic_json(spec_path, spec)
    return spec_path


def main() -> None:
    with tempfile.TemporaryDirectory(prefix="sbm-review-packet-") as temporary:
        root = Path(temporary)
        spec_path = make_spec(root)
        cache = root / "cache"
        output = root / "packet.json"

        first = packet.build(spec_path, output, cache, None)
        assert first["ok"] and first["cache_hits"] == 0 and first["cache_misses"] == 1
        first_key = first["gates"][0]["cache_key"]
        second = packet.build(spec_path, output, cache, None)
        assert second["ok"] and second["cache_hits"] == 1

        write(root / "input.txt", "beta\n")
        input_mutated = packet.build(spec_path, output, cache, None)
        assert input_mutated["ok"] and input_mutated["cache_misses"] == 1
        input_key = input_mutated["gates"][0]["cache_key"]
        assert input_key != first_key

        write(root / "gate.py",
              "from pathlib import Path\nprint('tool-v2:' + Path('input.txt').read_text().strip())\n")
        tool_mutated = packet.build(spec_path, output, cache, None)
        tool_key = tool_mutated["gates"][0]["cache_key"]
        assert tool_key not in (first_key, input_key)

        spec = json.loads(spec_path.read_text(encoding="utf-8"))
        gate = spec["gates"][0]
        identity = packet.interpreter_identity()
        normal_key, _ = packet.gate_key(spec, gate, root, identity)
        changed_identity = dict(identity)
        changed_identity["version"] += "-mutated"
        changed_key, _ = packet.gate_key(spec, gate, root, changed_identity)
        assert normal_key != changed_key

        corrupt = cache / f"{tool_key}.json"
        write(corrupt, "{\"cache_key\":\"corrupt\"}\n")
        try:
            packet.build(spec_path, output, cache, None)
        except packet.PacketError as exc:
            assert "cache" in str(exc).lower()
        else:
            raise AssertionError("corrupt cache did not fail closed")
        corrupt.unlink()

        clean = packet.build(spec_path, output, cache, None)
        approved = root / "approved.json"
        packet.atomic_json(approved, {"approved_semantic": packet.semantic_view(clean)})
        write(root / "input.txt", "gamma\n")
        changed = packet.build(spec_path, output, cache, approved)
        assert changed["semantic_delta"]["changed"] is True

        write(root / "stage" / "unexpected.txt", "drift\n")
        topology_drift = packet.build(spec_path, output, cache, None)
        assert topology_drift["ok"] is False
        assert topology_drift["receipts"]["topologies"][0]["ok"] is False

        (root / "stage" / "unexpected.txt").unlink()
        write(root / "causal.log", "[MYSTERY] causal ready\n")
        unknown = packet.build(spec_path, output, cache, None)
        assert unknown["ok"] is False
        assert unknown["causal_logs"]["logs"][0]["unknown_severity_lines"] == [1]

    print("ok=true")
    print("cache_hit_paths=1")
    print("cache_corruption_rejections=1")
    print("input_mutation_invalidations=1")
    print("tool_mutation_invalidations=1")
    print("interpreter_version_invalidations=1")
    print("semantic_delta_detections=1")
    print("topology_drift_rejections=1")
    print("unknown_severity_rejections=1")


if __name__ == "__main__":
    main()
