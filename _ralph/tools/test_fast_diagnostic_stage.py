#!/usr/bin/env python3
"""Adversarial self-test for the immutable fast diagnostic materializer."""

from __future__ import annotations

import json
from pathlib import Path
import subprocess
import tempfile

import materialize_fast_diagnostic as fast


def write(path: Path, value: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(value, encoding="utf-8", newline="\n")


def rejected(callable_) -> None:
    try:
        callable_()
    except fast.DiagnosticError:
        return
    raise AssertionError("adversarial input did not fail closed")


def main() -> None:
    with tempfile.TemporaryDirectory(prefix="sbm-fast-diagnostic-") as temporary:
        root = Path(temporary)
        repo = root / "repo"
        repo.mkdir()
        subprocess.check_call(["git", "init", "-q"], cwd=repo)
        subprocess.check_call(["git", "config", "user.email", "oracle@example.invalid"], cwd=repo)
        subprocess.check_call(["git", "config", "user.name", "oracle"], cwd=repo)
        write(repo / "production.lua", "return 995\n")
        subprocess.check_call(["git", "add", "."], cwd=repo)
        subprocess.check_call(["git", "commit", "-qm", "fixture"], cwd=repo)
        head, tree, _ = fast.git_identity(repo)
        base = root / "base"
        write(base / "executor.ps1", "param([switch]$Launch)\n")
        write(base / "generator.lua", "return 'diagnostic'\n")
        base_manifest_path = root / "base.json"
        base_manifest = fast.signed_payload({
            "schema": fast.BASE_SCHEMA, "base_root": str(base.resolve()),
            "files": fast.exact_inventory(base),
            "topology_sha256": fast.digest_bytes(fast.canonical(fast.exact_inventory(base))),
            "immutable": True,
        })
        fast.atomic_json(base_manifest_path, base_manifest)
        candidate = fast.signed_payload({
            "schema": fast.CANDIDATE_SCHEMA, "iteration": 238, "version": 995,
            "mode": "post-t1-heartbeat-handshake-only", "diagnostic_only": True,
            "acceptance_timing_eligible": False, "can_promote": False,
            "can_release_underground": False, "can_materialize_underground": False,
            "can_mutate_live_state": False,
            "heartbeat_contract": {"phase": "diagnostic-heartbeat-handshake", "records": 2,
                                   "edges": ["BEFORE", "AFTER"],
                                   "underground_access_closed": True},
            "base": {**fast.file_receipt(base_manifest_path),
                     "payload_sha256": base_manifest["payload_sha256"]},
            "production": {"head": head, "tree": tree,
                           "files": {"production.lua": fast.file_receipt(repo / "production.lua")}},
            "runtime_shell": {"edition": "Desktop", "major": 5,
                              "path": r"C:\windows\System32\WindowsPowerShell\v1.0\powershell.exe"},
        })
        fast.validate_candidate(candidate, repo, base_manifest, base_manifest_path)

        stale = dict(candidate); stale["production"] = dict(stale["production"], head="0" * 40)
        stale = fast.signed_payload(stale)
        rejected(lambda: fast.validate_candidate(stale, repo, base_manifest, base_manifest_path))
        unsigned = dict(candidate); unsigned["iteration"] = 239
        rejected(lambda: fast.validate_candidate(unsigned, repo, base_manifest, base_manifest_path))
        for field in ("can_promote", "can_release_underground",
                      "can_materialize_underground", "can_mutate_live_state"):
            forged = fast.signed_payload({**candidate, field: True})
            rejected(lambda forged=forged: fast.validate_candidate(
                forged, repo, base_manifest, base_manifest_path))
        changed = (base / "generator.lua").read_text(encoding="utf-8")
        write(base / "generator.lua", changed + "-- drift\n")
        rejected(lambda: fast.validate_base(base_manifest_path))
        write(base / "generator.lua", changed)
        fast.validate_base(base_manifest_path)

        # Cache corruption is already fail-closed by the invoked review packet; assert its reader.
        from build_accelerated_review_packet import PacketError, read_cache
        corrupt = root / "cache.json"
        write(corrupt, '{"cache_key":"wrong"}\n')
        try:
            read_cache(corrupt, "expected")
        except PacketError:
            pass
        else:
            raise AssertionError("corrupt packet cache accepted")
        assert fast.MAX_MECHANICAL_MS == 300_000

    print("ok=true")
    print("stale_manifest_rejected=true")
    print("changed_base_rejected=true")
    print("signature_mismatch_rejected=true")
    print("forbidden_access_promotion_mutation_cases=4")
    print("timeout_cap_ms=300000")
    print("cache_corruption_rejected=true")
    print("candidate_stage_files=1")


if __name__ == "__main__":
    main()
