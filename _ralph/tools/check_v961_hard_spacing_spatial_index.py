#!/usr/bin/env python3
"""Static, semantic, and projected-cost gate for v961's surface spacing index."""

from __future__ import annotations

import hashlib
import json
from pathlib import Path
import subprocess
import sys


ROOT = Path(__file__).resolve().parents[2]
DEPOSITS_PATH = ROOT / "Code" / "sbm_deposits.lua"
CONFIG_PATH = ROOT / "Code" / "sbm_config.lua"
GENERATION_PATH = ROOT / "Code" / "sbm_map_generation.lua"
VERSION_PATH = ROOT / "Code" / "sbm_version.lua"
METADATA_PATH = ROOT / "metadata.lua"
ORACLE_PATH = ROOT / "_ralph" / "tools" / "v961_hard_spacing_spatial_oracle.py"


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main() -> int:
    deposits = DEPOSITS_PATH.read_text(encoding="utf-8")
    config = CONFIG_PATH.read_text(encoding="utf-8")
    generation = GENERATION_PATH.read_text(encoding="utf-8")
    version_source = VERSION_PATH.read_text(encoding="utf-8")
    metadata = METADATA_PATH.read_text(encoding="utf-8")
    helper_start = deposits.index("local function BuildSurfaceHardSpacingCandidateRows")
    helper_end = deposits.index("-- Vanilla applies the family repulsion fields", helper_start)
    helper = deposits[helper_start:helper_end]
    audit_start = deposits.index("function DepositRules.AuditTopUpVanillaRepulsion")
    audit_end = deposits.index("function DepositRules.CensusFinalOuterResourceTopUps", audit_start)
    audit = deposits[audit_start:audit_end]

    oracle_process = subprocess.run(
        [sys.executable, str(ORACLE_PATH)],
        cwd=ROOT,
        capture_output=True,
        text=True,
        timeout=120,
        check=False,
    )
    oracle = {}
    if oracle_process.returncode == 0:
        oracle = json.loads(oracle_process.stdout)

    checks = {
        "metadata_v961_or_later": any(
            f"'version', {version}," in metadata for version in range(961, 1000)
        ),
        "generator_patch_identity_v273": "SuperBigMap.GENERATOR_PATCH_VERSION = 273" in version_source,
        "default_on": "config.OptimizeTopUpHardSpacingSpatialIndex = true" in config,
        "compiled_flag": "C.OPTIMIZE_TOPUP_HARD_SPACING_SPATIAL_INDEX" in config,
        "surface_only_guard": (
            "if spatial_index_requested and not underground then" in audit
            and '"underground literal path"' in audit
        ),
        "dual_coverage_indexes": all(
            token in helper
            for token in (
                "local world_buckets, hex_buckets = {}, {}",
                "maximum_world_radius = 2 * max_component",
                "minimum_hex_distance = math.max",
                "append_neighbourhood(world_buckets",
                "append_neighbourhood(hex_buckets",
            )
        ),
        "certificate_is_finite_and_fail_closed": all(
            token in helper + audit
            for token in (
                "local function finite_number(value)",
                'return nil, "non-finite world position at entry "',
                'return nil, "invalid maximum world radius"',
                "local build_ok, build_rows, build_report = pcall(",
                '"certificate error: " .. tostring(build_rows)',
            )
        ),
        "literal_quadratic_fallback_retained": all(
            token in audit
            for token in (
                "-- Literal exact fallback: preserve the original full pair order",
                "for i = 1, #entries - 1 do",
                "for j = i + 1, #entries do",
                "stats.native_pairs_skipped = stats.native_pairs_skipped + 1",
                "stats.checked_pairs = stats.checked_pairs + 1",
                "audit_checked_pair(a, b)",
            )
        ),
        "optimized_order_is_lexicographic": all(
            token in helper + audit
            for token in (
                "table.sort(nearby)",
                "for i = 1, #entries - 1 do",
                "for _, j in ipairs(candidate_rows[i] or {}) do",
                "audit_checked_pair(a, entries[j])",
            )
        ),
        "exact_pair_counters_are_combinatorial": all(
            token in audit
            for token in (
                "local total_pairs = #entries * (#entries - 1) / 2",
                "local native_pair_budget = native_entries * (native_entries - 1) / 2",
                "checked_pair_budget = total_pairs - native_pair_budget",
                "stats.native_pairs_skipped = native_entries * (native_entries - 1) / 2",
                "stats.checked_pairs = checked_pair_budget",
            )
        ),
        "candidate_builder_is_rng_neutral": not any(
            token in helper
            for token in ("AsyncRand", "InteractionRand", "BraidRandom", "table.shuffle", "Shuffle")
        ),
        "surface_runtime_allocation_is_post_object": (
            generation.index('NotifyDeterminismCaptureForTest("post_object_transform"')
            < generation.index('LoadingBegin("surface hard top-up spacing audit"')
        ),
        "telemetry_is_truthful": all(
            token in audit + generation
            for token in (
                "hard_spacing_spatial_index_requested",
                "hard_spacing_spatial_index_used",
                "hard_spacing_spatial_index_fallback_reason",
                "hard_spacing_spatial_index_candidate_pairs",
                "hard_spacing_spatial_index_pruned_pairs",
                "spatial_index_maximum_world_radius",
            )
        ),
        "oracle_passed": oracle_process.returncode == 0 and oracle.get("reports_exact") is True,
        "oracle_has_adversarial_and_random_corpora": oracle.get("corpora", 0) >= 66,
        "oracle_reproduces_iter189_pair_budget": (
            oracle.get("representative_markers") == 615
            and oracle.get("representative_checked_pairs") == 127730
        ),
        "projected_saving_at_least_500ms": oracle.get("projected_engine_saving_ms", 0) >= 500.0,
    }
    ok = all(checks.values())
    result = {
        "schema": "smr.ralph.v961.hard-spacing-spatial-index-check.v1",
        "ok": ok,
        "checks": checks,
        "oracle": oracle,
        "oracle_stderr": oracle_process.stderr,
        "files": {
            str(path.relative_to(ROOT)): sha256(path)
            for path in (
                DEPOSITS_PATH, CONFIG_PATH, GENERATION_PATH, VERSION_PATH, METADATA_PATH, ORACLE_PATH
            )
        },
    }
    print(json.dumps(result, indent=2, sort_keys=True))
    return 0 if ok else 1


if __name__ == "__main__":
    raise SystemExit(main())
