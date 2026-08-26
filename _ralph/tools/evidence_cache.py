#!/usr/bin/env python3
"""Fail-closed, content-addressed cache for unchanged Ralph offline gates.

Only successful diagnostic/offline evidence is reusable.  The key includes the exact
command, working directory, every declared file/tree digest, existing command-file
digests, and mandatory source/task/scenario/schema/expected-output identities.  Cold
game captures, timings, visual verdicts, and final acceptance are never cacheable.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import subprocess
import sys
import time
from pathlib import Path


SCHEMA = "smr.ralph.evidence_cache.v1"
RECEIPT_SCHEMA = "smr.ralph.evidence_cache_receipt.v1"
REQUIRED_CONTEXT = {
    "source_commit",
    "task_sha256",
    "scenario_input_sha256",
    "schema",
    "expected_digest_sha256",
}
FORBIDDEN_GATE_WORDS = {"cold", "timing", "visual", "final"}
MAX_CAPTURE_CHARS = 1_000_000


def canonical(payload: object) -> bytes:
    return json.dumps(payload, ensure_ascii=False, separators=(",", ":"), sort_keys=True).encode()


def digest_bytes(payload: object) -> str:
    return hashlib.sha256(canonical(payload)).hexdigest().upper()


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1 << 20), b""):
            digest.update(block)
    return digest.hexdigest().upper()


def fingerprint(path: Path) -> dict:
    resolved = path.resolve(strict=True)
    if resolved.is_symlink():
        raise ValueError(f"cache input cannot be a symlink: {resolved}")
    if resolved.is_file():
        return {"path": str(resolved), "kind": "file", "bytes": resolved.stat().st_size,
                "sha256": sha256(resolved)}
    if not resolved.is_dir():
        raise ValueError(f"cache input is neither a file nor directory: {resolved}")
    rows = []
    for child in sorted(resolved.rglob("*")):
        if child.is_symlink():
            raise ValueError(f"cache input tree contains a symlink: {child}")
        if child.is_file():
            rows.append({"path": child.relative_to(resolved).as_posix(),
                         "bytes": child.stat().st_size, "sha256": sha256(child)})
    return {"path": str(resolved), "kind": "tree", "files": len(rows),
            "bytes": sum(row["bytes"] for row in rows), "sha256": digest_bytes(rows)}


def parse_context(values: list[str]) -> dict[str, str]:
    result = {}
    for value in values:
        if "=" not in value:
            raise ValueError(f"context must be key=value: {value!r}")
        key, item = value.split("=", 1)
        if not key or not item or key in result:
            raise ValueError(f"invalid or duplicate context: {value!r}")
        result[key] = item
    missing = sorted(REQUIRED_CONTEXT - set(result))
    if missing:
        raise ValueError("missing cache context: " + ", ".join(missing))
    for key in ("task_sha256", "scenario_input_sha256", "expected_digest_sha256"):
        value = result[key]
        if len(value) != 64 or any(c not in "0123456789abcdefABCDEF" for c in value):
            raise ValueError(f"context {key} must be a SHA-256")
        result[key] = value.upper()
    return dict(sorted(result.items()))


def existing_command_inputs(command: list[str], cwd: Path) -> list[Path]:
    paths = []
    seen = set()
    for token in command:
        candidate = Path(token)
        if not candidate.is_absolute():
            candidate = cwd / candidate
        try:
            resolved = candidate.resolve(strict=True)
        except OSError:
            continue
        if resolved.is_file() and resolved not in seen:
            seen.add(resolved)
            paths.append(resolved)
    return paths


def key_payload(gate_id: str, command: list[str], cwd: Path, inputs: list[Path], context: dict) -> dict:
    lowered = gate_id.lower()
    if any(word in lowered for word in FORBIDDEN_GATE_WORDS):
        raise ValueError(f"gate {gate_id!r} is final/live evidence and cannot be cached")
    all_inputs = []
    seen = set()
    for path in [*inputs, *existing_command_inputs(command, cwd)]:
        resolved = path.resolve(strict=True)
        if resolved not in seen:
            seen.add(resolved)
            all_inputs.append(resolved)
    return {
        "schema": SCHEMA,
        "gate_id": gate_id,
        "cwd": str(cwd.resolve(strict=True)),
        "command": command,
        "context": context,
        "inputs": [fingerprint(path) for path in all_inputs],
    }


def atomic_json(path: Path, payload: object) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(f".{path.name}.{os.getpid()}.{time.time_ns()}.tmp")
    temporary.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    temporary.replace(path)


def valid_cache_record(path: Path, key: str) -> dict | None:
    if not path.is_file():
        return None
    try:
        record = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return None
    stored = record.get("record_sha256")
    unsigned = dict(record)
    unsigned.pop("record_sha256", None)
    if (record.get("schema") != SCHEMA or record.get("cache_key") != key
            or record.get("exit_code") != 0 or record.get("ok") is not True
            or stored != digest_bytes(unsigned)):
        return None
    return record


def receipt(key: str, cache_hit: bool, cache_path: Path, record: dict) -> dict:
    return {
        "schema": RECEIPT_SCHEMA,
        "ok": True,
        "cache_hit": cache_hit,
        "cache_key": key,
        "cache_record": str(cache_path),
        "gate_id": record["gate_id"],
        "source_exit_code": record["exit_code"],
        "source_stdout_sha256": record["stdout_sha256"],
        "source_stderr_sha256": record["stderr_sha256"],
        "key_payload": record["key_payload"],
    }


def command_run(args: argparse.Namespace) -> int:
    command = list(args.command)
    if command and command[0] == "--":
        command.pop(0)
    if not command:
        raise ValueError("a gate command is required after --")
    cwd = args.cwd.resolve(strict=True)
    context = parse_context(args.context)
    payload = key_payload(args.gate_id, command, cwd, args.input, context)
    key = digest_bytes(payload)
    cache_path = args.cache_dir.resolve() / f"{key}.json"
    cached = valid_cache_record(cache_path, key)
    if cached is not None:
        result = receipt(key, True, cache_path, cached)
        atomic_json(args.evidence.resolve(), result)
        print(json.dumps(result, indent=2, sort_keys=True))
        return 0

    started = time.perf_counter_ns()
    completed = subprocess.run(command, cwd=cwd, capture_output=True, text=True,
                               encoding="utf-8", errors="replace", check=False)
    duration_ms = (time.perf_counter_ns() - started) / 1_000_000
    stdout = completed.stdout or ""
    stderr = completed.stderr or ""
    stdout_sha256 = hashlib.sha256(stdout.encode()).hexdigest().upper()
    stderr_sha256 = hashlib.sha256(stderr.encode()).hexdigest().upper()
    expected_output_matches = stdout_sha256 == context["expected_digest_sha256"]
    effective_exit_code = completed.returncode if completed.returncode != 0 else (
        0 if expected_output_matches else 3
    )
    record = {
        "schema": SCHEMA,
        "ok": effective_exit_code == 0,
        "cache_key": key,
        "gate_id": args.gate_id,
        "key_payload": payload,
        "exit_code": effective_exit_code,
        "command_exit_code": completed.returncode,
        "duration_ms": duration_ms,
        "stdout_sha256": stdout_sha256,
        "stderr_sha256": stderr_sha256,
        "expected_stdout_sha256": context["expected_digest_sha256"],
        "expected_output_matches": expected_output_matches,
        "stdout": stdout[:MAX_CAPTURE_CHARS],
        "stderr": stderr[:MAX_CAPTURE_CHARS],
        "output_truncated": len(stdout) > MAX_CAPTURE_CHARS or len(stderr) > MAX_CAPTURE_CHARS,
    }
    if effective_exit_code == 0:
        unsigned = dict(record)
        record["record_sha256"] = digest_bytes(unsigned)
        atomic_json(cache_path, record)
    result = receipt(key, False, cache_path, record) if effective_exit_code == 0 else {
        "schema": RECEIPT_SCHEMA, "ok": False, "cache_hit": False,
        "cache_key": key, "gate_id": args.gate_id, "source_exit_code": effective_exit_code,
        "command_exit_code": completed.returncode,
        "expected_stdout_sha256": context["expected_digest_sha256"],
        "expected_output_matches": expected_output_matches,
        "stdout_sha256": record["stdout_sha256"], "stderr_sha256": record["stderr_sha256"],
        "stdout": record["stdout"], "stderr": record["stderr"],
    }
    atomic_json(args.evidence.resolve(), result)
    print(json.dumps(result, indent=2, sort_keys=True))
    return effective_exit_code


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--gate-id", required=True)
    parser.add_argument("--cwd", type=Path, default=Path.cwd())
    parser.add_argument("--input", type=Path, action="append", default=[])
    parser.add_argument("--context", action="append", default=[])
    parser.add_argument("--cache-dir", type=Path, default=Path("_ralph/cache/evidence"))
    parser.add_argument("--evidence", type=Path, required=True)
    parser.add_argument("command", nargs=argparse.REMAINDER)
    return parser.parse_args()


if __name__ == "__main__":
    try:
        raise SystemExit(command_run(parse_args()))
    except (OSError, ValueError, subprocess.SubprocessError) as exc:
        print(f"evidence cache error: {exc}", file=sys.stderr)
        raise SystemExit(2)
