#!/usr/bin/env python3
"""Adversarial executable tests for the v991 terminal diagnostic analyzer."""

from pathlib import Path
import tempfile

import analyze_v991_terminal_bundle as analyzer


MANIFEST = "a" * 64
NONCE = "iter234-v991-test"


def render(values: dict[str, object]) -> bytes:
    return ("\n".join(f"{key}={value}" for key, value in values.items()) + "\n").encode()


def main() -> None:
    with tempfile.TemporaryDirectory(prefix="sbm-v991-terminal-") as temporary:
        root = Path(temporary)
        bundle_path = root / "bundle.txt"
        sentinel_path = root / "sentinel.txt"
        bundle = {
            "schema": "smr.sbm.lazy-terminal-causal-bundle.v1", "ok": "false",
            "diagnostic_only": "true", "acceptance_timing_eligible": "false",
            "nonce": NONCE, "command_manifest_sha256": MANIFEST,
            "sentinel_reason": "underground enrichment reachability audit left 4 unresolved markers",
            "descriptor_state": "blocked", "failure_sticky": "true",
            "report_access_blocked": "true", "generation_count": "1",
            "target_z_count": "2", "target_z_digest": "552785219",
            "validation_z_digest": "400807124", "capability_phase_timeline": "1:owner>2:pipeline",
            "branch_materialization_state": "blocked", "branch_materialization_complete": "false",
            "branch_pair_certificate": "true", "branch_enrichment_certificate": "false",
            "relocation_debug_schema": "2", "relocation_invalid": "4",
            "relocation_moved": "0", "relocation_unresolved": "4",
            "relocation_candidates_built": "512", "relocation_candidate_corpus_count": "256",
            "relocation_candidate_corpus_digest": "12345", "live_before_hash": "71",
            "live_after_hash": "71", "private_clone_before_hash": "not-run-production",
            "private_clone_after_hash": "not-run-production",
            "live_state_mutated_by_diagnostic": "false", "rejection_repulsion": "29",
        }
        bundle_raw = render(bundle)
        bundle_path.write_bytes(bundle_raw)
        sentinel = {
            "schema": "smr.sbm.lazy-terminal-failure.v1", "ok": "false",
            "diagnostic_only": "true", "acceptance_timing_eligible": "false",
            "nonce": NONCE, "command_manifest_sha256": MANIFEST,
            "bundle_path": str(bundle_path.resolve()), "bundle_bytes": str(len(bundle_raw)),
            "bundle_digest": "123", "reason": bundle["sentinel_reason"],
        }
        sentinel_path.write_bytes(render(sentinel))
        result = analyzer.analyze(sentinel_path, bundle_path, NONCE, MANIFEST)
        assert result["ok"] is False and result["evidence_complete"] is True
        assert result["root_cause_candidates"][0]["candidate"] == \
            "enrichment-profile-candidate-intersection"
        assert result["raw_bounded_fields"]["relocation_unresolved"] == "4"

        original = bundle_path.read_bytes()
        for mutation in (
            original + b"failure_sticky=true\n",
            original.replace(b"live_state_mutated_by_diagnostic=false\n", b""),
            original.replace(b"failure_sticky=true", b"failure_sticky=false"),
        ):
            bundle_path.write_bytes(mutation)
            try:
                analyzer.analyze(sentinel_path, bundle_path, NONCE, MANIFEST)
            except analyzer.EvidenceError:
                pass
            else:
                raise AssertionError("malformed/incomplete evidence did not fail closed")
        bundle_path.write_bytes(original)

        unknown = dict(bundle)
        unknown["sentinel_reason"] = "unclassified fatal"
        unknown["relocation_unresolved"] = "0"
        unknown["branch_enrichment_certificate"] = "true"
        unknown_raw = render(unknown)
        bundle_path.write_bytes(unknown_raw)
        sentinel["bundle_bytes"] = str(len(unknown_raw))
        sentinel["reason"] = unknown["sentinel_reason"]
        sentinel_path.write_bytes(render(sentinel))
        try:
            analyzer.analyze(sentinel_path, bundle_path, NONCE, MANIFEST)
        except analyzer.EvidenceError as exc:
            assert "unknown" in str(exc)
        else:
            raise AssertionError("unknown diagnostic root auto-promoted")

    print("ok=true")
    print("valid_bundle_ranked=true")
    print("duplicate_missing_falsegreen_rejections=3")
    print("unknown_root_rejections=1")


if __name__ == "__main__":
    main()
