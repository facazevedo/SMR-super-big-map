#!/usr/bin/env python3
"""Build a fail-closed, content-addressed Ralph review packet.

This accelerates repeated *pure* review gates only.  It never replaces a final cold acceptance run.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import time
from typing import Any


SCHEMA = "smr.ralph.accelerated-review-packet.v1"
SPEC_SCHEMA = "smr.ralph.accelerated-review-spec.v1"
TOOL = Path(__file__).resolve()
CORE_REVIEW_GROUPS = ("production", "task", "rules", "references", "tool_contract")


class PacketError(RuntimeError):
    pass


def canonical(value: Any) -> bytes:
    return json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode("utf-8")


def sha_bytes(value: bytes) -> str:
    return hashlib.sha256(value).hexdigest()


def sha_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        while True:
            block = handle.read(1024 * 1024)
            if not block:
                break
            digest.update(block)
    return digest.hexdigest()


def exact_path_receipt(path: Path) -> dict[str, Any]:
    path = path.resolve()
    if path.is_symlink():
        raise PacketError(f"symlink input is not allowed: {path}")
    if path.is_file():
        return {"kind": "file", "path": str(path), "bytes": path.stat().st_size,
                "sha256": sha_file(path)}
    if not path.is_dir():
        raise PacketError(f"required input is absent: {path}")
    files: dict[str, dict[str, Any]] = {}
    directories: list[str] = []
    for item in sorted(path.rglob("*"), key=lambda p: p.relative_to(path).as_posix()):
        if item.is_symlink():
            raise PacketError(f"symlink input is not allowed: {item}")
        relative = item.relative_to(path).as_posix()
        if item.is_dir():
            directories.append(relative)
        elif item.is_file():
            files[relative] = {"bytes": item.stat().st_size, "sha256": sha_file(item)}
        else:
            raise PacketError(f"unsupported input type: {item}")
    topology = {"files": files, "directories": directories}
    return {"kind": "directory", "path": str(path), **topology,
            "sha256": sha_bytes(canonical(topology))}


def resolve_path(raw: str, base: Path) -> Path:
    path = Path(raw)
    return (path if path.is_absolute() else base / path).resolve()


def interpreter_identity(executable: Path | None = None,
                         version: str | None = None) -> dict[str, Any]:
    executable = (executable or Path(sys.executable)).resolve()
    return {
        "path": str(executable),
        "bytes": executable.stat().st_size,
        "sha256": sha_file(executable),
        "version": version if version is not None else sys.version,
        "implementation": sys.implementation.name,
    }


def command_tool_identity(command: list[str], cwd: Path) -> dict[str, Any]:
    if not command or not isinstance(command[0], str):
        raise PacketError("gate command must be a non-empty string array")
    raw = command[0]
    candidate = resolve_path(raw, cwd)
    if not candidate.is_file():
        found = shutil.which(raw)
        if not found:
            raise PacketError(f"gate executable is unavailable: {raw}")
        candidate = Path(found).resolve()
    return {"path": str(candidate), "bytes": candidate.stat().st_size,
            "sha256": sha_file(candidate)}


def collect_declared_inputs(spec: dict[str, Any], gate: dict[str, Any], base: Path) -> list[dict[str, Any]]:
    paths: set[Path] = set()
    for section in ("task_inputs", "references", "context"):
        values = spec.get(section, [])
        if not isinstance(values, list):
            raise PacketError(f"{section} must be an array")
        paths.update(resolve_path(str(value), base) for value in values)
    if "inputs" not in gate or not isinstance(gate["inputs"], list):
        raise PacketError(f"gate {gate.get('id')} must declare its complete inputs array")
    paths.update(resolve_path(str(value), base) for value in gate["inputs"])
    cwd = resolve_path(str(gate.get("cwd", base)), base)
    for argument in gate.get("command", [])[1:]:
        if not isinstance(argument, str) or argument.startswith("-"):
            continue
        candidate = resolve_path(argument, cwd)
        if candidate.exists():
            paths.add(candidate)
    return [exact_path_receipt(path) for path in sorted(paths, key=lambda p: str(p).lower())]


def gate_key(spec: dict[str, Any], gate: dict[str, Any], base: Path,
             interpreter: dict[str, Any] | None = None) -> tuple[str, dict[str, Any]]:
    cwd = resolve_path(str(gate.get("cwd", base)), base)
    material = {
        "schema": SCHEMA,
        "tool": exact_path_receipt(TOOL),
        "interpreter": interpreter or interpreter_identity(),
        "command_tool": command_tool_identity(gate["command"], cwd),
        # Bind the shared semantic contract, not unrelated stage-only gate declarations. This
        # lets an unchanged core gate remain reusable when only a staged schema/oracle changes.
        "spec_contract_sha256": sha_bytes(canonical({
            "schema": spec.get("schema"), "task": spec.get("task"),
            "task_inputs": spec.get("task_inputs"), "references": spec.get("references"),
            "context": spec.get("context"),
        })),
        "gate": gate,
        "declared_inputs": collect_declared_inputs(spec, gate, base),
    }
    return sha_bytes(canonical(material)), material


def atomic_json(path: Path, value: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(path.name + f".tmp-{os.getpid()}")
    data = json.dumps(value, sort_keys=True, indent=2, ensure_ascii=False) + "\n"
    with temporary.open("w", encoding="utf-8", newline="\n") as handle:
        handle.write(data)
        handle.flush()
        os.fsync(handle.fileno())
    os.replace(temporary, path)


def cache_envelope(key: str, result: dict[str, Any]) -> dict[str, Any]:
    body = {"cache_key": key, "result": result}
    return {**body, "integrity_sha256": sha_bytes(canonical(body))}


def read_cache(path: Path, expected_key: str) -> dict[str, Any]:
    try:
        envelope = json.loads(path.read_text(encoding="utf-8"))
    except Exception as exc:
        raise PacketError(f"cache corruption at {path}: {exc}") from exc
    body = {"cache_key": envelope.get("cache_key"), "result": envelope.get("result")}
    if (envelope.get("cache_key") != expected_key
            or not isinstance(envelope.get("result"), dict)
            or envelope.get("integrity_sha256") != sha_bytes(canonical(body))):
        raise PacketError(f"cache integrity mismatch at {path}")
    return envelope["result"]


def run_gate(spec: dict[str, Any], gate: dict[str, Any], base: Path, cache: Path) -> dict[str, Any]:
    gate_id = gate.get("id")
    if not isinstance(gate_id, str) or not re.fullmatch(r"[A-Za-z0-9_.-]+", gate_id):
        raise PacketError("every gate needs a stable id")
    if gate.get("pure") is not True:
        raise PacketError(f"gate {gate_id} is not explicitly pure")
    command = gate.get("command")
    if not isinstance(command, list) or not all(isinstance(item, str) for item in command):
        raise PacketError(f"gate {gate_id} command is invalid")
    key, material = gate_key(spec, gate, base)
    cache_path = cache / f"{key}.json"
    if cache_path.exists():
        result = read_cache(cache_path, key)
        return {**result, "cache_hit": True, "cache_key": key,
                "key_material_sha256": sha_bytes(canonical(material))}
    cwd = resolve_path(str(gate.get("cwd", base)), base)
    started = time.monotonic()
    try:
        completed = subprocess.run(command, cwd=cwd, stdin=subprocess.DEVNULL,
                                   capture_output=True, text=False,
                                   timeout=int(gate.get("timeout_seconds", 300)), check=False)
        result = {
            "id": gate_id,
            "ok": completed.returncode == 0,
            "returncode": completed.returncode,
            "stdout_sha256": sha_bytes(completed.stdout),
            "stderr_sha256": sha_bytes(completed.stderr),
            "stdout": completed.stdout.decode("utf-8", errors="replace")[-16000:],
            "stderr": completed.stderr.decode("utf-8", errors="replace")[-16000:],
            "elapsed_ms": int((time.monotonic() - started) * 1000),
        }
    except subprocess.TimeoutExpired as exc:
        result = {"id": gate_id, "ok": False, "returncode": None,
                  "stdout_sha256": sha_bytes(exc.stdout or b""),
                  "stderr_sha256": sha_bytes(exc.stderr or b""),
                  "stdout": (exc.stdout or b"").decode("utf-8", errors="replace")[-16000:],
                  "stderr": (exc.stderr or b"").decode("utf-8", errors="replace")[-16000:],
                  "elapsed_ms": int((time.monotonic() - started) * 1000), "timeout": True}
    atomic_json(cache_path, cache_envelope(key, result))
    return {**result, "cache_hit": False, "cache_key": key,
            "key_material_sha256": sha_bytes(canonical(material))}


def compare_expected_topology(receipt: dict[str, Any], expected: dict[str, Any]) -> tuple[bool, list[str]]:
    failures: list[str] = []
    actual_files = receipt.get("files", {})
    actual_dirs = receipt.get("directories", [])
    expected_files = expected.get("files")
    expected_dirs = expected.get("directories")
    if not isinstance(expected_files, dict) or not isinstance(expected_dirs, list):
        return False, ["exact files/directories expectations are mandatory"]
    if set(actual_files) != set(expected_files):
        failures.append("file set mismatch")
    if actual_dirs != expected_dirs:
        failures.append("directory set mismatch")
    for name, wanted in expected_files.items():
        actual = actual_files.get(name)
        if (not actual or actual.get("bytes") != wanted.get("bytes")
                or actual.get("sha256", "").lower()
                != str(wanted.get("sha256", "")).lower()):
            failures.append(f"file mismatch: {name}")
    return not failures, failures


def collect_receipts(spec: dict[str, Any], base: Path) -> dict[str, Any]:
    configured = spec.get("receipts", {})
    result: dict[str, Any] = {"ok": True, "topologies": []}
    git = configured.get("git")
    if git:
        root = resolve_path(git["root"], base)
        head = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=root, text=True).strip()
        tree = subprocess.check_output(["git", "rev-parse", "HEAD^{tree}"], cwd=root, text=True).strip()
        status = subprocess.check_output(["git", "status", "--porcelain"], cwd=root, text=True)
        ok = head == git.get("head") and tree == git.get("tree")
        if git.get("clean") is True:
            ok = ok and status == ""
        result["git"] = {"ok": ok, "root": str(root), "head": head, "tree": tree,
                         "clean": status == "", "status_sha256": sha_bytes(status.encode())}
        result["ok"] = result["ok"] and ok
    for topology in configured.get("topologies", []):
        receipt = exact_path_receipt(resolve_path(topology["root"], base))
        ok, failures = compare_expected_topology(receipt, topology.get("expected", {}))
        item = {"id": topology["id"], "ok": ok, "failures": failures, "receipt": receipt}
        result["topologies"].append(item)
        result["ok"] = result["ok"] and ok
    deploy = configured.get("deploy")
    if deploy:
        source = resolve_path(deploy["source_root"], base)
        target = resolve_path(deploy["deployed_root"], base)
        files = deploy.get("files")
        if not isinstance(files, list) or len(files) != deploy.get("exact_count"):
            raise PacketError("deploy receipt requires an exact files/count contract")
        mismatches = []
        entries = {}
        for relative in files:
            left, right = source / relative, target / relative
            if not left.is_file() or not right.is_file():
                mismatches.append(relative)
                continue
            lh, rh = sha_file(left), sha_file(right)
            entries[relative] = {"source_sha256": lh, "deployed_sha256": rh,
                                 "bytes": left.stat().st_size}
            if lh != rh or left.stat().st_size != right.stat().st_size:
                mismatches.append(relative)
        result["deploy"] = {"ok": not mismatches, "exact_count": len(files),
                            "mismatches": mismatches, "files": entries}
        result["ok"] = result["ok"] and not mismatches
    cold = configured.get("cold_state")
    if cold:
        receipt = exact_path_receipt(resolve_path(cold["root"], base))
        expected = {"files": cold.get("files"), "directories": cold.get("directories")}
        ok, failures = compare_expected_topology(receipt, expected)
        result["cold_state"] = {"ok": ok, "failures": failures, "receipt": receipt}
        result["ok"] = result["ok"] and ok
    return result


def causal_windows(spec: dict[str, Any], base: Path) -> dict[str, Any]:
    output: list[dict[str, Any]] = []
    all_ok = True
    for config in spec.get("logs", []):
        path = resolve_path(config["path"], base)
        raw = path.read_bytes()
        lines = raw.decode("utf-8", errors="replace").splitlines()
        patterns = [re.compile(value) for value in config.get("causal_patterns", [])]
        rules = [(re.compile(item["pattern"]), item["severity"])
                 for item in config.get("severity_rules", [])]
        allowed = set(config.get("allowed_severities", ["trace", "debug", "info", "warning"]))
        before, after = int(config.get("before", 8)), int(config.get("after", 16))
        maximum = int(config.get("maximum_lines", 200))
        indices = [i for i, line in enumerate(lines) if any(pattern.search(line) for pattern in patterns)]
        selected: set[int] = set()
        for index in indices:
            selected.update(range(max(0, index - before), min(len(lines), index + after + 1)))
        requested_lines = len(selected)
        selected = set(sorted(selected)[:maximum])
        unknown, disallowed, rendered = [], [], []
        bracket = re.compile(r"^\s*\[([^\]]+)\]")
        for index in sorted(selected):
            line = lines[index]
            severity = next((value for regex, value in rules if regex.search(line)), None)
            if severity is None and bracket.search(line):
                unknown.append(index + 1)
            if severity is not None and severity not in allowed:
                disallowed.append({"line": index + 1, "severity": severity})
            rendered.append({"line": index + 1, "severity": severity or "neutral", "text": line[:2000]})
        truncated = requested_lines > maximum
        ok = bool(indices) and not unknown and not disallowed and not truncated
        item = {"id": config["id"], "ok": ok, "path": str(path), "bytes": len(raw),
                "sha256": sha_bytes(raw), "matches": len(indices), "lines": rendered,
                "unknown_severity_lines": unknown, "disallowed": disallowed,
                "requested_lines": requested_lines, "truncated": truncated}
        output.append(item)
        all_ok = all_ok and ok
    return {"ok": all_ok, "logs": output}


def semantic_view(packet: dict[str, Any]) -> dict[str, Any]:
    return {
        "gates": [{"id": gate["id"], "ok": gate["ok"], "returncode": gate["returncode"],
                   "stdout_sha256": gate["stdout_sha256"], "stderr_sha256": gate["stderr_sha256"]}
                  for gate in packet.get("gates", [])],
        "receipts_sha256": sha_bytes(canonical(packet.get("receipts"))),
        "causal_logs_sha256": sha_bytes(canonical(packet.get("causal_logs"))),
    }


def receipt_group(values: Any, base: Path, label: str) -> dict[str, Any]:
    if not isinstance(values, list):
        raise PacketError(f"review_tiering.{label} must be an array")
    receipts = [exact_path_receipt(resolve_path(str(value), base)) for value in values]
    return {"paths": receipts, "sha256": sha_bytes(canonical(receipts))}


def review_contract(spec: dict[str, Any], base: Path, packet: dict[str, Any]) -> dict[str, Any]:
    configured = spec.get("review_tiering")
    if not isinstance(configured, dict):
        raise PacketError("review_tiering contract is mandatory")
    groups = {name: receipt_group(configured.get(name), base, name)
              for name in (*CORE_REVIEW_GROUPS, "stage_only")}
    groups["task"]["task_identity_sha256"] = sha_bytes(canonical(spec.get("task")))
    groups["task"]["sha256"] = sha_bytes(canonical({
        "paths": groups["task"]["paths"], "task": spec.get("task")}))
    groups["interpreter"] = {
        "identity": packet["interpreter"],
        "sha256": sha_bytes(canonical(packet["interpreter"])),
    }
    return {"schema": "smr.ralph.review-tier-contract.v1", "groups": groups}


def classify_review(packet: dict[str, Any], approved_packet: dict[str, Any] | None) -> dict[str, Any]:
    full_reasons: list[str] = []
    short_reasons: list[str] = ["mandatory_short_independent_delta_review"]
    contract = packet.get("review_contract", {})
    groups = contract.get("groups", {}) if isinstance(contract, dict) else {}
    approved_groups: dict[str, Any] = {}
    if approved_packet is None:
        full_reasons.append("no_approved_review_baseline")
    else:
        approved_contract = approved_packet.get("review_contract", {})
        approved_groups = approved_contract.get("groups", {}) \
            if isinstance(approved_contract, dict) else {}
        if not approved_groups:
            full_reasons.append("approved_review_contract_absent")
    for name in (*CORE_REVIEW_GROUPS, "interpreter"):
        if approved_groups and groups.get(name, {}).get("sha256") \
                != approved_groups.get(name, {}).get("sha256"):
            full_reasons.append(f"{name}_contract_changed")
    if approved_groups and groups.get("stage_only", {}).get("sha256") \
            != approved_groups.get("stage_only", {}).get("sha256"):
        short_reasons.append("stage_only_schema_or_oracle_delta")

    core_misses = [gate.get("id") for gate in packet.get("gates", [])
                   if not gate.get("cache_hit") and gate.get("review_scope", "core") != "stage-only"]
    stage_misses = [gate.get("id") for gate in packet.get("gates", [])
                    if not gate.get("cache_hit") and gate.get("review_scope") == "stage-only"]
    if core_misses:
        full_reasons.append("core_cache_miss")
    if stage_misses:
        short_reasons.append("changed_stage_only_gate_rerun")

    receipts = packet.get("receipts", {})
    if not receipts.get("ok", False):
        full_reasons.append("evidence_or_topology_drift")
    logs = packet.get("causal_logs", {})
    for item in logs.get("logs", []):
        if item.get("unknown_severity_lines"):
            full_reasons.append("unknown_log_severity")
        if item.get("disallowed"):
            full_reasons.append("severe_or_disallowed_log")
        if any(row.get("severity") in {"error", "critical", "fatal"}
               for row in item.get("lines", [])):
            full_reasons.append("severe_or_disallowed_log")
        if not item.get("ok") and not item.get("unknown_severity_lines") \
                and not item.get("disallowed"):
            full_reasons.append("unexplained_log_failure")
    if any(not gate.get("ok", False) for gate in packet.get("gates", [])):
        full_reasons.append("unexplained_gate_failure")
    delta = packet.get("semantic_delta", {})
    if approved_packet is not None and delta.get("changed") is True:
        approved_semantic = approved_packet.get("approved_semantic") \
            or semantic_view(approved_packet)
        current_semantic = semantic_view(packet)
        if current_semantic.get("receipts_sha256") != approved_semantic.get("receipts_sha256"):
            full_reasons.append("evidence_receipt_changed")
        if current_semantic.get("causal_logs_sha256") \
                != approved_semantic.get("causal_logs_sha256"):
            full_reasons.append("causal_evidence_changed")

    full_reasons = list(dict.fromkeys(full_reasons))
    short_reasons = list(dict.fromkeys(short_reasons))
    return {
        "schema": "smr.ralph.review-tier-decision.v1",
        "ok": bool(groups),
        "minimum_review": "short-independent-delta",
        "independent_reviewer_required": True,
        "full_review_required": bool(full_reasons),
        "full_review_reasons": full_reasons,
        "short_review_reasons": short_reasons,
        "core_cache_misses": core_misses,
        "stage_only_cache_misses": stage_misses,
        "stage_only_delta_never_waives_short_review": True,
    }


def failure_review_decision(reason: str = "packet_or_cache_integrity_failure") -> dict[str, Any]:
    return {
        "schema": "smr.ralph.review-tier-decision.v1", "ok": False,
        "minimum_review": "short-independent-delta",
        "independent_reviewer_required": True, "full_review_required": True,
        "full_review_reasons": [reason],
    }


def build(spec_path: Path, output: Path, cache: Path, approved: Path | None) -> dict[str, Any]:
    raw_spec = spec_path.read_bytes()
    spec = json.loads(raw_spec)
    if spec.get("schema") != SPEC_SCHEMA:
        raise PacketError("review spec schema mismatch")
    base = spec_path.parent.resolve()
    gates = [run_gate(spec, gate, base, cache) for gate in spec.get("gates", [])]
    receipts = collect_receipts(spec, base)
    logs = causal_windows(spec, base)
    packet: dict[str, Any] = {
        "schema": SCHEMA, "ok": False, "task": spec.get("task"),
        "spec_path": str(spec_path.resolve()), "spec_bytes": len(raw_spec),
        "spec_sha256": sha_bytes(raw_spec), "tool_sha256": sha_file(TOOL),
        "interpreter": interpreter_identity(), "gates": gates,
        "receipts": receipts, "causal_logs": logs,
        "cache_hits": sum(gate["cache_hit"] for gate in gates),
        "cache_misses": sum(not gate["cache_hit"] for gate in gates),
        "final_cold_acceptance_unchanged": True,
    }
    for gate, configured in zip(packet["gates"], spec.get("gates", [])):
        scope = configured.get("review_scope", "core")
        if scope not in ("core", "stage-only"):
            raise PacketError(f"gate {gate.get('id')} review_scope is invalid")
        gate["review_scope"] = scope
    packet["review_contract"] = review_contract(spec, base, packet)
    semantic = semantic_view(packet)
    packet["semantic_sha256"] = sha_bytes(canonical(semantic))
    approved_packet = None
    if approved:
        approved_packet = json.loads(approved.read_text(encoding="utf-8"))
        approved_semantic = approved_packet.get("approved_semantic") or semantic_view(approved_packet)
        packet["semantic_delta"] = {
            "approved_path": str(approved.resolve()),
            "approved_sha256": sha_file(approved),
            "changed": semantic != approved_semantic,
            "current_sha256": packet["semantic_sha256"],
            "approved_semantic_sha256": sha_bytes(canonical(approved_semantic)),
        }
    else:
        packet["semantic_delta"] = {"approved_path": None, "changed": None,
                                     "reason": "no approved snapshot supplied"}
    packet["review_tier"] = classify_review(packet, approved_packet)
    packet["ok"] = (all(gate["ok"] for gate in gates) and receipts["ok"] and logs["ok"]
                    and packet["review_tier"]["ok"])
    atomic_json(output, packet)
    return packet


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--spec", required=True, type=Path)
    parser.add_argument("--out", required=True, type=Path)
    parser.add_argument("--cache", required=True, type=Path)
    parser.add_argument("--approved", type=Path)
    args = parser.parse_args()
    try:
        packet = build(args.spec.resolve(), args.out.resolve(), args.cache.resolve(),
                       args.approved.resolve() if args.approved else None)
    except Exception as exc:
        failure = {"schema": SCHEMA, "ok": False, "error": f"{type(exc).__name__}: {exc}",
                   "review_tier": failure_review_decision()}
        atomic_json(args.out.resolve(), failure)
        print(failure["error"], file=sys.stderr)
        return 2
    print(json.dumps({"ok": packet["ok"], "cache_hits": packet["cache_hits"],
                      "cache_misses": packet["cache_misses"],
                      "semantic_sha256": packet["semantic_sha256"]}, sort_keys=True))
    return 0 if packet["ok"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
