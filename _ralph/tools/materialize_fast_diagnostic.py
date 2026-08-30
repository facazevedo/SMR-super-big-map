#!/usr/bin/env python3
"""Materialize a hash-bound, non-promoting Ralph diagnostic candidate.

The immutable base is referenced in place; it is never copied or retargeted.  A candidate stage
contains exactly one canonical manifest.  This command validates every identity, creates a fresh
run, executes the content-addressed review packet when requested, and publishes a bounded
mechanical-overhead receipt.  It never launches or controls the game.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import time
from typing import Any


BASE_SCHEMA = "smr.ralph.fast-diagnostic-base.v1"
CANDIDATE_SCHEMA = "smr.ralph.fast-diagnostic-candidate.v1"
RECEIPT_SCHEMA = "smr.ralph.fast-diagnostic-mechanical-overhead.v1"
MAX_MECHANICAL_MS = 300_000


class DiagnosticError(RuntimeError):
    pass


def canonical(value: Any) -> bytes:
    return json.dumps(value, sort_keys=True, separators=(",", ":"),
                      ensure_ascii=False).encode("utf-8")


def digest_bytes(value: bytes) -> str:
    return hashlib.sha256(value).hexdigest()


def digest_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for block in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def file_receipt(path: Path) -> dict[str, Any]:
    if not path.is_file() or path.is_symlink():
        raise DiagnosticError(f"required ordinary file is absent: {path}")
    return {"bytes": path.stat().st_size, "sha256": digest_file(path)}


def signed_payload(value: dict[str, Any]) -> dict[str, Any]:
    payload = dict(value)
    payload.pop("payload_sha256", None)
    return {**payload, "payload_sha256": digest_bytes(canonical(payload))}


def validate_signature(value: dict[str, Any], label: str) -> None:
    supplied = value.get("payload_sha256")
    if not isinstance(supplied, str) or len(supplied) != 64:
        raise DiagnosticError(f"{label} payload signature is absent")
    expected = signed_payload(value)["payload_sha256"]
    if supplied.lower() != expected:
        raise DiagnosticError(f"{label} payload signature mismatch")


def atomic_json(path: Path, value: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(path.name + f".tmp-{os.getpid()}")
    data = json.dumps(value, sort_keys=True, indent=2, ensure_ascii=False) + "\n"
    with temporary.open("w", encoding="utf-8", newline="\n") as handle:
        handle.write(data)
        handle.flush()
        os.fsync(handle.fileno())
    os.replace(temporary, path)


def exact_inventory(root: Path) -> dict[str, dict[str, Any]]:
    if not root.is_dir() or root.is_symlink():
        raise DiagnosticError(f"base root is absent or unsafe: {root}")
    inventory: dict[str, dict[str, Any]] = {}
    for path in sorted(root.rglob("*"), key=lambda item: item.relative_to(root).as_posix()):
        if path.is_symlink():
            raise DiagnosticError(f"base symlink is forbidden: {path}")
        if path.is_file():
            inventory[path.relative_to(root).as_posix()] = file_receipt(path)
        elif not path.is_dir():
            raise DiagnosticError(f"unsupported base entry: {path}")
    return inventory


def seal_base(args: argparse.Namespace) -> int:
    root = args.base.resolve()
    inventory = exact_inventory(root)
    if not inventory:
        raise DiagnosticError("immutable base cannot be empty")
    manifest = signed_payload({
        "schema": BASE_SCHEMA,
        "base_root": str(root),
        "files": inventory,
        "topology_sha256": digest_bytes(canonical(inventory)),
        "immutable": True,
    })
    atomic_json(args.out.resolve(), manifest)
    print(json.dumps(manifest, sort_keys=True))
    return 0


def validate_base(path: Path) -> tuple[dict[str, Any], Path]:
    manifest = json.loads(path.read_text(encoding="utf-8"))
    if manifest.get("schema") != BASE_SCHEMA or manifest.get("immutable") is not True:
        raise DiagnosticError("immutable base schema/flag mismatch")
    validate_signature(manifest, "base")
    root = Path(manifest.get("base_root", "")).resolve()
    actual = exact_inventory(root)
    if actual != manifest.get("files"):
        raise DiagnosticError("immutable base topology or content changed")
    if digest_bytes(canonical(actual)) != manifest.get("topology_sha256"):
        raise DiagnosticError("immutable base topology digest mismatch")
    return manifest, root


def git_identity(repo: Path) -> tuple[str, str, str]:
    head = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=repo,
                                   text=True, timeout=30).strip()
    tree = subprocess.check_output(["git", "rev-parse", "HEAD^{tree}"], cwd=repo,
                                   text=True, timeout=30).strip()
    status = subprocess.check_output(["git", "status", "--porcelain"], cwd=repo,
                                     text=True, timeout=30)
    return head, tree, status


def validate_candidate(candidate: dict[str, Any], repo: Path,
                       base_manifest: dict[str, Any], base_manifest_path: Path) -> None:
    validate_signature(candidate, "candidate")
    if candidate.get("schema") != CANDIDATE_SCHEMA:
        raise DiagnosticError("candidate schema mismatch")
    exact_false = ("acceptance_timing_eligible", "can_promote", "can_release_underground",
                   "can_materialize_underground", "can_mutate_live_state")
    if candidate.get("diagnostic_only") is not True or any(
            candidate.get(field) is not False for field in exact_false):
        raise DiagnosticError("candidate can accept, promote, access, materialize, or mutate")
    if candidate.get("mode") != "post-t1-heartbeat-handshake-only":
        raise DiagnosticError("candidate is not handshake-only")
    heartbeat = candidate.get("heartbeat_contract")
    if heartbeat != {
        "phase": "diagnostic-heartbeat-handshake", "records": 2,
        "edges": ["BEFORE", "AFTER"], "underground_access_closed": True,
    }:
        raise DiagnosticError("heartbeat promotion contract mismatch")
    expected_base = candidate.get("base")
    actual_base = file_receipt(base_manifest_path)
    if expected_base != {**actual_base, "payload_sha256": base_manifest["payload_sha256"]}:
        raise DiagnosticError("candidate immutable-base identity mismatch")
    production = candidate.get("production")
    if not isinstance(production, dict):
        raise DiagnosticError("candidate production identity is absent")
    head, tree, status = git_identity(repo)
    if status:
        raise DiagnosticError("production worktree is not clean")
    if production.get("head") != head or production.get("tree") != tree:
        raise DiagnosticError("candidate production Git identity is stale")
    files = production.get("files")
    if not isinstance(files, dict) or not files:
        raise DiagnosticError("candidate production file identities are absent")
    for relative, expected in files.items():
        path = (repo / relative).resolve()
        if repo not in path.parents or file_receipt(path) != expected:
            raise DiagnosticError(f"candidate production file drift: {relative}")
    shell = candidate.get("runtime_shell")
    if not isinstance(shell, dict) or shell.get("edition") != "Desktop" \
            or shell.get("major") != 5 or shell.get("path") != (
                r"C:\windows\System32\WindowsPowerShell\v1.0\powershell.exe"):
        raise DiagnosticError("candidate runtime is not exact Windows PowerShell 5.1")


def require_fresh(path: Path) -> None:
    if path.exists():
        entries = list(path.iterdir()) if path.is_dir() else [path]
        if entries:
            raise DiagnosticError(f"fresh target is not empty: {path}")
    path.mkdir(parents=True, exist_ok=True)


def materialize(args: argparse.Namespace) -> int:
    started = time.monotonic()
    repo = args.repo.resolve()
    base_manifest_path = args.base_manifest.resolve()
    base_manifest, _ = validate_base(base_manifest_path)
    candidate_path = args.candidate.resolve()
    candidate = json.loads(candidate_path.read_text(encoding="utf-8"))
    validate_candidate(candidate, repo, base_manifest, base_manifest_path)
    stage = args.stage.resolve()
    run = args.run.resolve()
    if stage.exists():
        stage_entries = list(stage.iterdir()) if stage.is_dir() else []
        if (not stage.is_dir() or len(stage_entries) != 1
                or stage_entries[0].name != "candidate_manifest.json"
                or stage_entries[0].read_bytes() != candidate_path.read_bytes()):
            raise DiagnosticError("candidate stage is not the exact one-manifest topology")
    else:
        stage.mkdir(parents=True)
        shutil.copyfile(candidate_path, stage / "candidate_manifest.json")
    require_fresh(run)
    reference = args.reference.resolve()
    shutil.copyfile(reference, run / reference.name)
    shutil.copyfile(candidate_path, run / "candidate_manifest.json")

    review: dict[str, Any] = {"requested": False, "ok": True}
    if args.review_spec:
        if not args.review_output or not args.review_cache:
            raise DiagnosticError("review spec requires output and cache paths")
        command = [sys.executable, str(repo / "_ralph/tools/build_accelerated_review_packet.py"),
                   "--spec", str(args.review_spec.resolve()), "--out",
                   str(args.review_output.resolve()), "--cache", str(args.review_cache.resolve())]
        if args.review_approved:
            command.extend(["--approved", str(args.review_approved.resolve())])
        completed = subprocess.run(command, cwd=repo, capture_output=True, timeout=240)
        if completed.returncode:
            raise DiagnosticError("accelerated review packet was not ready")
        packet = json.loads(args.review_output.read_text(encoding="utf-8"))
        if packet.get("ok") is not True:
            raise DiagnosticError("accelerated review packet failed closed")
        review = {"requested": True, "ok": True,
                  "packet": file_receipt(args.review_output.resolve()),
                  "cache_hits": packet.get("cache_hits"),
                  "cache_misses": packet.get("cache_misses")}

    elapsed_ms = int((time.monotonic() - started) * 1000)
    if elapsed_ms >= min(args.timeout_ms, MAX_MECHANICAL_MS):
        raise DiagnosticError(f"mechanical stage generation exceeded budget: {elapsed_ms}ms")
    receipt_path = run / "mechanical_overhead.json"
    receipt = {
        "schema": RECEIPT_SCHEMA, "ok": True, "elapsed_ms": elapsed_ms,
        "budget_ms": min(args.timeout_ms, MAX_MECHANICAL_MS),
        "excludes_code_diagnosis_implementation_and_t0_t1": True,
        "stage_generation": "one-manifest-no-base-copy",
        "base_payload_sha256": base_manifest["payload_sha256"],
        "candidate_payload_sha256": candidate["payload_sha256"],
        "review_packet_ready": review,
        "diagnostic_only": True, "acceptance_timing_eligible": False,
        "can_promote": False, "can_release_underground": False,
    }
    atomic_json(receipt_path, receipt)
    print(json.dumps(receipt, sort_keys=True))
    return 0


def parser() -> argparse.ArgumentParser:
    result = argparse.ArgumentParser(description=__doc__)
    commands = result.add_subparsers(dest="command", required=True)
    seal = commands.add_parser("seal-base")
    seal.add_argument("--base", type=Path, required=True)
    seal.add_argument("--out", type=Path, required=True)
    seal.set_defaults(function=seal_base)
    create = commands.add_parser("create")
    create.add_argument("--repo", type=Path, required=True)
    create.add_argument("--base-manifest", type=Path, required=True)
    create.add_argument("--candidate", type=Path, required=True)
    create.add_argument("--stage", type=Path, required=True)
    create.add_argument("--run", type=Path, required=True)
    create.add_argument("--reference", type=Path, required=True)
    create.add_argument("--review-spec", type=Path)
    create.add_argument("--review-output", type=Path)
    create.add_argument("--review-cache", type=Path)
    create.add_argument("--review-approved", type=Path)
    create.add_argument("--timeout-ms", type=int, default=60_000)
    create.set_defaults(function=materialize)
    return result


def main() -> int:
    args = parser().parse_args()
    try:
        return args.function(args)
    except (OSError, ValueError, KeyError, subprocess.SubprocessError,
            DiagnosticError) as error:
        print(f"ERROR: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
