#!/usr/bin/env python3
"""Validate a v991 terminal causal bundle and rank evidence-backed root candidates."""

from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import re
import sys


HEX64 = re.compile(r"^[0-9a-f]{64}$")


class EvidenceError(RuntimeError):
    pass


def parse_exact(path: Path, maximum_bytes: int) -> tuple[dict[str, str], bytes]:
    raw = path.read_bytes()
    if not raw or len(raw) > maximum_bytes or b"\x00" in raw:
        raise EvidenceError(f"invalid bounded artifact: {path}")
    try:
        text = raw.decode("utf-8")
    except UnicodeDecodeError as exc:
        raise EvidenceError(f"non-UTF-8 artifact: {path}") from exc
    values: dict[str, str] = {}
    for line_number, line in enumerate(text.splitlines(), 1):
        if "=" not in line:
            raise EvidenceError(f"line {line_number} has no scalar assignment")
        key, value = line.split("=", 1)
        if not re.fullmatch(r"[A-Za-z0-9_]+", key) or key in values:
            raise EvidenceError(f"invalid/duplicate key at line {line_number}: {key!r}")
        values[key] = value
    return values, raw


def exact_bool(values: dict[str, str], key: str, expected: bool) -> None:
    wanted = "true" if expected else "false"
    if values.get(key) != wanted:
        raise EvidenceError(f"{key} must be exact {wanted}")


def integer(values: dict[str, str], key: str, minimum: int = 0) -> int:
    value = values.get(key, "")
    if not re.fullmatch(r"-?[0-9]+", value):
        raise EvidenceError(f"{key} is not an exact integer")
    parsed = int(value)
    if parsed < minimum:
        raise EvidenceError(f"{key} is below {minimum}")
    return parsed


def analyze(sentinel_path: Path, bundle_path: Path, nonce: str,
            manifest_sha256: str) -> dict[str, object]:
    if not HEX64.fullmatch(manifest_sha256):
        raise EvidenceError("expected manifest SHA-256 is invalid")
    sentinel, sentinel_raw = parse_exact(sentinel_path, 8192)
    bundle, bundle_raw = parse_exact(bundle_path, 65536)
    if sentinel.get("schema") != "smr.sbm.lazy-terminal-failure.v1":
        raise EvidenceError("terminal sentinel schema mismatch")
    if bundle.get("schema") != "smr.sbm.lazy-terminal-causal-bundle.v1":
        raise EvidenceError("causal bundle schema mismatch")
    for values in (sentinel, bundle):
        exact_bool(values, "ok", False)
        exact_bool(values, "diagnostic_only", True)
        exact_bool(values, "acceptance_timing_eligible", False)
        if values.get("nonce") != nonce:
            raise EvidenceError("nonce mismatch")
        if values.get("command_manifest_sha256") != manifest_sha256:
            raise EvidenceError("command-manifest mismatch")
    if Path(sentinel.get("bundle_path", "")).resolve() != bundle_path.resolve():
        raise EvidenceError("sentinel bundle path mismatch")
    if integer(sentinel, "bundle_bytes", 1) != len(bundle_raw):
        raise EvidenceError("bundle byte receipt mismatch")
    if sentinel.get("reason") != bundle.get("sentinel_reason"):
        raise EvidenceError("sentinel/bundle reason mismatch")
    required = {
        "descriptor_state", "failure_sticky", "report_access_blocked",
        "generation_count", "target_z_count", "target_z_digest", "validation_z_digest",
        "capability_phase_timeline", "branch_materialization_state",
        "branch_pair_certificate", "branch_enrichment_certificate",
        "relocation_debug_schema", "relocation_invalid", "relocation_moved",
        "relocation_unresolved", "relocation_candidates_built",
        "relocation_candidate_corpus_count", "relocation_candidate_corpus_digest",
        "live_before_hash", "live_after_hash", "private_clone_before_hash",
        "private_clone_after_hash", "live_state_mutated_by_diagnostic",
    }
    missing = sorted(required - bundle.keys())
    if missing:
        raise EvidenceError("incomplete diagnostic bundle: " + ",".join(missing))
    exact_bool(bundle, "failure_sticky", True)
    exact_bool(bundle, "report_access_blocked", True)
    exact_bool(bundle, "live_state_mutated_by_diagnostic", False)

    candidates: list[dict[str, object]] = []
    reason = bundle["sentinel_reason"].lower()
    unresolved = int(bundle["relocation_unresolved"]) if bundle["relocation_unresolved"].isdigit() else -1
    rejection_total = sum(int(value) for key, value in bundle.items()
                          if key.startswith("rejection_") and not key.startswith("rejection_example_")
                          and value.isdigit())
    if unresolved > 0 and int(bundle.get("relocation_candidates_built", "0") or 0) > 0:
        candidates.append({"rank": 1, "candidate": "enrichment-profile-candidate-intersection",
                           "evidence": [f"unresolved={unresolved}",
                                        f"rejections={rejection_total}",
                                        f"corpus_digest={bundle['relocation_candidate_corpus_digest']}"]})
    if "enrichment reachability" in reason:
        candidates.append({"rank": 2, "candidate": "enrichment-relocation-terminal-boundary",
                           "evidence": [bundle["sentinel_reason"]]})
    if bundle["branch_pair_certificate"] != "true":
        candidates.append({"rank": 3, "candidate": "passage-pair-certificate",
                           "evidence": ["branch_pair_certificate=" + bundle["branch_pair_certificate"]]})
    if bundle["target_z_count"] != "2":
        candidates.append({"rank": 4, "candidate": "target-z-certificate",
                           "evidence": ["target_z_count=" + bundle["target_z_count"]]})
    if not candidates:
        raise EvidenceError("diagnostics complete but root cause is unknown")
    candidates.sort(key=lambda item: int(item["rank"]))
    return {
        "schema": "smr.ralph.v991-ranked-terminal-root-candidates.v1",
        "ok": False,
        "diagnostic_only": True,
        "acceptance_timing_eligible": False,
        "evidence_complete": True,
        "sentinel_sha256": hashlib.sha256(sentinel_raw).hexdigest(),
        "bundle_sha256": hashlib.sha256(bundle_raw).hexdigest(),
        "root_cause_candidates": candidates,
        "raw_bounded_fields": bundle,
    }


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--sentinel", type=Path, required=True)
    parser.add_argument("--bundle", type=Path, required=True)
    parser.add_argument("--nonce", required=True)
    parser.add_argument("--manifest-sha256", required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    try:
        result = analyze(args.sentinel.resolve(), args.bundle.resolve(), args.nonce,
                         args.manifest_sha256.lower())
    except (OSError, EvidenceError, ValueError) as exc:
        print(f"diagnostic validation failed: {exc}", file=sys.stderr)
        raise SystemExit(1)
    args.output.write_text(json.dumps(result, sort_keys=True, indent=2) + "\n",
                           encoding="utf-8", newline="\n")
    print("ok=false")
    print("evidence_complete=true")
    print("acceptance_timing_eligible=false")


if __name__ == "__main__":
    main()
