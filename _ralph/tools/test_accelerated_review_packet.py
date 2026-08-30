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
    write(root / "rules.txt", "rules-v1\n")
    write(root / "tool-contract.txt", "tool-contract-v1\n")
    write(root / "stage-schema.txt", "stage-schema-v1\n")
    write(root / "reference.txt", "reference-bytes\n")
    write(root / "gate.py",
          "from pathlib import Path\nprint(Path('input.txt').read_text().strip())\n")
    write(root / "stage_gate.py",
          "from pathlib import Path\nprint(Path('stage-schema.txt').read_text().strip())\n")
    write(root / "causal.log", "[INFO] causal ready\nneutral context\n")
    spec = {
        "schema": packet.SPEC_SCHEMA,
        "task": {"id": "test-review", "context": "exact synthetic task bytes"},
        "task_inputs": ["input.txt"],
        "references": ["reference.txt"],
        "context": ["context.txt"],
        "review_tiering": {
            "production": ["input.txt"],
            "task": ["context.txt"],
            "rules": ["rules.txt"],
            "references": ["reference.txt"],
            "tool_contract": ["tool-contract.txt"],
            "stage_only": ["stage-schema.txt"],
        },
        "gates": [{
            "id": "pure-gate", "pure": True,
            "command": [sys.executable, "gate.py"], "cwd": ".",
            "inputs": ["input.txt", "gate.py"], "timeout_seconds": 30,
            "review_scope": "core",
        }, {
            "id": "stage-only-gate", "pure": True,
            "command": [sys.executable, "stage_gate.py"], "cwd": ".",
            "inputs": ["stage-schema.txt", "stage_gate.py"], "timeout_seconds": 30,
            "review_scope": "stage-only",
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
        assert first["ok"] and first["cache_hits"] == 0 and first["cache_misses"] == 2
        assert first["review_tier"]["full_review_required"] is True
        assert "no_approved_review_baseline" in first["review_tier"]["full_review_reasons"]
        assert first["review_tier"]["minimum_review"] == "short-independent-delta"
        first_key = first["gates"][0]["cache_key"]
        second = packet.build(spec_path, output, cache, None)
        assert second["ok"] and second["cache_hits"] == 2

        approved_baseline = root / "approved-baseline.json"
        packet.atomic_json(approved_baseline, second)
        baseline = packet.build(spec_path, output, cache, approved_baseline)
        assert baseline["review_tier"]["full_review_required"] is False
        assert baseline["review_tier"]["independent_reviewer_required"] is True

        write(root / "stage-schema.txt", "stage-schema-v2\n")
        stage_only = packet.build(spec_path, output, cache, approved_baseline)
        assert stage_only["review_tier"]["full_review_required"] is False
        assert "stage_only_schema_or_oracle_delta" in stage_only["review_tier"]["short_review_reasons"]
        assert stage_only["review_tier"]["core_cache_misses"] == []
        assert stage_only["review_tier"]["stage_only_cache_misses"] == ["stage-only-gate"]
        assert "changed_stage_only_gate_rerun" in stage_only["review_tier"]["short_review_reasons"]
        write(root / "stage-schema.txt", "stage-schema-v1\n")

        write(root / "input.txt", "beta\n")
        input_mutated = packet.build(spec_path, output, cache, None)
        assert input_mutated["ok"] and input_mutated["cache_misses"] == 2
        input_key = input_mutated["gates"][0]["cache_key"]
        assert input_key != first_key
        assert "core_cache_miss" in input_mutated["review_tier"]["full_review_reasons"]
        promoted = packet.build(spec_path, output, cache, approved_baseline)
        assert "production_contract_changed" in promoted["review_tier"]["full_review_reasons"]

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
        cache_failure = packet.failure_review_decision()
        assert cache_failure["full_review_required"] is True
        assert cache_failure["full_review_reasons"] == ["packet_or_cache_integrity_failure"]
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
        assert "unknown_log_severity" in unknown["review_tier"]["full_review_reasons"]

        # Direct tier classification covers each byte-contract trigger without conflating it with
        # the cache key, plus severe logs and unexplained gate failures.
        clean_for_tiers = packet.build(spec_path, output, cache, None)
        clean_for_tiers["causal_logs"] = baseline["causal_logs"]
        clean_for_tiers["receipts"] = baseline["receipts"]
        clean_for_tiers["gates"] = [dict(baseline["gates"][0], cache_hit=True, ok=True)]
        clean_for_tiers["semantic_delta"] = {"changed": False}
        for group in ("task", "rules", "references", "tool_contract", "interpreter"):
            candidate = json.loads(json.dumps(clean_for_tiers))
            candidate["review_contract"]["groups"][group]["sha256"] = "0" * 64
            decision = packet.classify_review(candidate, baseline)
            assert f"{group}_contract_changed" in decision["full_review_reasons"]
        severe_candidate = json.loads(json.dumps(clean_for_tiers))
        severe_candidate["causal_logs"]["logs"][0]["ok"] = False
        severe_candidate["causal_logs"]["logs"][0]["disallowed"] = [
            {"line": 1, "severity": "error"}]
        severe = packet.classify_review(severe_candidate, baseline)
        assert "severe_or_disallowed_log" in severe["full_review_reasons"]
        failed_candidate = json.loads(json.dumps(clean_for_tiers))
        failed_candidate["gates"][0]["ok"] = False
        unexplained = packet.classify_review(failed_candidate, baseline)
        assert "unexplained_gate_failure" in unexplained["full_review_reasons"]

    print("ok=true")
    print("cache_hit_paths=1")
    print("cache_corruption_rejections=1")
    print("input_mutation_invalidations=1")
    print("tool_mutation_invalidations=1")
    print("interpreter_version_invalidations=1")
    print("semantic_delta_detections=1")
    print("topology_drift_rejections=1")
    print("unknown_severity_rejections=1")
    print("mandatory_short_reviews=1")
    print("stage_only_non_promotions=1")
    print("full_review_trigger_classes=12")


if __name__ == "__main__":
    main()
