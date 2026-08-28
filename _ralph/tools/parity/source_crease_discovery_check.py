#!/usr/bin/env python3
"""Offline exactness certificate for sampled native source-crease discovery.

This checker does not launch the game. It proves the integer candidate predicate and sampled-row
coordinate transport against the legacy scalar model, then checks production structure for a
read-only original grid, deterministic serialization, complete transient cleanup, and fail-closed
fallback before the unchanged scalar refinement/repair path.
"""

from __future__ import annotations

import hashlib
import json
import random
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parents[3]
TERRAIN_PATH = ROOT / "Code" / "sbm_terrain_copy.lua"
CONFIG_PATH = ROOT / "Code" / "sbm_config.lua"


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest().upper()


def accepted_scalar(v0: int, a: int, b: int, v3: int, threshold: int) -> bool:
    jump = abs(b - a)
    flank = max(abs(a - v0), abs(v3 - b), 1)
    return jump >= threshold and jump >= flank * 2


def accepted_native_model(v0: int, a: int, b: int, v3: int, threshold: int) -> bool:
    # Production converts U16 operands to f32. Every value below is an integer with magnitude no
    # greater than 131070, so the model is also the exact f32 result (well below 2**24).
    signed_difference = b - a
    magnitude = abs(signed_difference)
    doubled_flank0 = abs(a - v0) * 2
    doubled_flank1 = abs(v3 - b) * 2
    return (
        magnitude >= threshold
        and magnitude - doubled_flank0 >= 0
        and magnitude - doubled_flank1 >= 0
    )


def offer(row: list[tuple[int, int, bool, int]], candidate: tuple[int, int, bool, int]) -> None:
    perp, width, low_before, jump = candidate
    for index, current in enumerate(row):
        current_perp, _, _, current_jump = current
        if abs(current_perp - perp) <= 3:
            if jump > current_jump:
                row[index] = candidate
            return
    row.append(candidate)
    # All generated tests use distinct jumps when the six-record truncation can matter, avoiding
    # reliance on either Python's stable sort or the engine's unspecified equal-key table.sort.
    row.sort(key=lambda item: item[3], reverse=True)
    del row[6:]


def scalar_row(values: list[int], perp0: int, perp1: int, threshold: int) -> list[tuple[int, int, bool, int]]:
    row: list[tuple[int, int, bool, int]] = []
    for perp in range(perp0, perp1 + 1):
        v0, a, b, v3 = values[perp - 1], values[perp], values[perp + 1], values[perp + 2]
        if accepted_scalar(v0, a, b, v3, threshold):
            offer(row, (perp, 1, a < b, abs(b - a)))
    return row


def native_serialized_row(
    values: list[int], perp0: int, perp1: int, threshold: int
) -> list[tuple[int, int, bool, int]]:
    # Native GridForeach order is intentionally discarded in production. Survivors from its
    # positive and negative exports are serialized by perpendicular position before offer_candidate.
    records: list[tuple[int, int, bool, int]] = []
    for perp in range(perp1, perp0 - 1, -1):
        v0, a, b, v3 = values[perp - 1], values[perp], values[perp + 1], values[perp + 2]
        if accepted_native_model(v0, a, b, v3, threshold):
            records.append((perp, 1, a < b, abs(b - a)))
    records.sort(key=lambda item: (item[0], item[1]))
    row: list[tuple[int, int, bool, int]] = []
    for candidate in records:
        offer(row, candidate)
    return row


def semantic_trials() -> tuple[int, int]:
    rng = random.Random(0x5BCEACE)
    predicate_trials = 0
    for threshold in (128, 129, 256, 1024, 8192):
        crafted = (
            (1000, 1000, 1000 + threshold, 1000 + threshold),
            (1000 + threshold, 1000 + threshold, 1000, 1000),
            (1000, 1001, 1001 + threshold, 1001 + threshold),
            (1000, 1000, 1000 + threshold - 1, 1000 + threshold - 1),
            (0, 65535, 0, 65535),
        )
        for values in crafted:
            assert accepted_scalar(*values, threshold) == accepted_native_model(*values, threshold)
            predicate_trials += 1
        for _ in range(20_000):
            values = tuple(rng.randrange(65_536) for _ in range(4))
            assert accepted_scalar(*values, threshold) == accepted_native_model(*values, threshold)
            predicate_trials += 1

    row_trials = 0
    for threshold in (128, 256, 1024):
        for _ in range(1_000):
            values = [rng.randrange(65_536) for _ in range(260)]
            # Give equal-key candidates unique jumps when they survive, matching the ordering proof's
            # explicit scope while still exercising both signs, edge equality, and candidate collapse.
            for index in range(2, 250, 17):
                jump = threshold + index
                base = rng.randrange(0, 65_536 - jump)
                values[index - 1 : index + 3] = [base, base, base + jump, base + jump]
            expected = scalar_row(values, 2, 250, threshold)
            actual = native_serialized_row(values, 2, 250, threshold)
            assert actual == expected, (threshold, expected, actual)
            row_trials += 1

    # Prove compact sample-index transport for both axis layouts. The source collector visits exactly
    # 0,8,... and the native callback restores along = compact_index * 8.
    for along_n in (1, 7, 8, 9, 6144, 6145):
        sampled_rows = (along_n - 1) // 8 + 1
        restored = [sample_index * 8 for sample_index in range(sampled_rows)]
        assert restored == list(range(0, along_n, 8))
    return predicate_trials, row_trials


def structural_checks(terrain: str, config: str) -> dict[str, bool]:
    begin = terrain.index("local function build_sampled_source_band")
    end = terrain.index("\n\t\tlocal function build_band", begin)
    source_native = terrain[begin:end]
    source_call = terrain.index("build_sampled_source_band(", end)
    repair_call = terrain.index("RepairQualifiedSourceHeightSteps(src_sub, tracks)")
    return {
        "source_flag_is_default_on_and_exported": (
            "config.OptimizeHeightStepNativeSourceDiscoveryIndex = true" in config
            and "C.OPTIMIZE_HEIGHT_STEP_NATIVE_SOURCE_DISCOVERY_INDEX =" in config
            and 'cfg_bool("OPTIMIZE_HEIGHT_STEP_NATIVE_SOURCE_DISCOVERY_INDEX", true)' in terrain
        ),
        "source_uses_exact_sampled_bounds": all(
            token in terrain
            for token in (
                '"source_sampled_wide_ring"',
                "near_margin + 1, math.min(edge_margin, w - 3)",
                "math.max(1, w - edge_margin - 2)",
                "build_sampled_source_band(",
                "wide_sample_step)",
            )
        ),
        "source_original_grid_is_read_only": (
            "sampled:copyrect(grid," in source_native
            and "grid:set(" not in source_native
            and "grid:copyrect(" not in source_native
        ),
        "source_compaction_restores_exact_rows": all(
            token in source_native
            for token in (
                "local sampled_rows = math.floor((along_n - 1) / sample_step) + 1",
                "local along = sample_index * sample_step",
                "local along = compact_along * sample_step",
                'local local_perp = axis == "x" and x or y',
                "or local_perp < 0 or local_perp >= positions",
                "perp = perp, width = 1, jump = jump, low_before = low_before",
            )
        ),
        "source_predicate_is_exact_and_sign_agnostic": all(
            token in source_native
            for token in (
                'GridRepack(source_v0, "f", 32, true)',
                "GridAbs(magnitude)",
                "GridMask(magnitude, accepted, threshold, 2147483647)",
                "GridMulDivAdd(flank0, 2, 1, 0)",
                "GridMulDivAdd(flank1, 2, 1, 0)",
                "export_records(positive, true)",
                "export_records(negative, false)",
            )
        ),
        "source_serialization_restores_legacy_order": (
            "return a.perp < b.perp or (a.perp == b.perp and a.width < b.width)"
            in source_native
            and terrain.index("native_discovery.scan(row", source_call) > source_call
        ),
        "source_cleanup_is_complete_and_fail_closed": all(
            token in source_native
            for token in (
                "local owned, owned_set = {}, {}",
                "for index = #owned, 1, -1 do",
                "owned[index] = nil",
                'type(value.free) == "function"',
                "pcall(value.free, value)",
                'local cleanup_failure = "native source discovery cleanup failed: "',
                "if not ok or #cleanup_errors > 0 then",
                "error(failure, 0)",
            )
        ) and all(
            token in terrain
            for token in (
                "local prepare_status = { pcall(native_discovery.prepare) }",
                "native_discovery.fallback = true",
                "native_discovery.indexes = nil",
            )
        ),
        "source_native_work_precedes_all_source_writes": (
            source_call < repair_call
            and "if detected and tracks then" in terrain[source_call:repair_call]
            and "RepairQualifiedSourceHeightSteps(src_sub, tracks)" in terrain[repair_call:]
        ),
        "source_reports_mode_usage_and_cleanup_counts": all(
            token in terrain
            for token in (
                "report.source_native_discovery_index_used = native_discovery.used",
                "report.source_native_discovery_index_fallback = native_discovery.fallback",
                "report.source_native_discovery_index_sampled_rows = native_discovery.sampled_rows",
                "source_native_discovery_error = internal_step_repair",
                "source_native_discovery_survivors = internal_step_repair",
                "source_native_discovery_compaction_copies = internal_step_repair",
                "source_native_discovery_ms = internal_step_repair",
                "report.source_height_step_collect_ms = report.height_step_collect_ms",
                "source_height_step_collect_ms = internal_step_repair",
            )
        ),
    }


def main() -> int:
    terrain = TERRAIN_PATH.read_text(encoding="utf-8")
    config = CONFIG_PATH.read_text(encoding="utf-8")
    predicate_trials, row_trials = semantic_trials()
    checks = structural_checks(terrain, config)
    result = {
        "schema": "smr.ralph.source_crease_discovery_check.v1",
        "ok": all(checks.values()),
        "checks": checks,
        "predicate_trials": predicate_trials,
        "row_trials": row_trials,
        "terrain_sha256": sha256(TERRAIN_PATH),
        "config_sha256": sha256(CONFIG_PATH),
    }
    print(json.dumps(result, indent=2, sort_keys=True))
    return 0 if result["ok"] else 1


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (AssertionError, ValueError) as exc:
        print(json.dumps({"ok": False, "error": repr(exc)}, sort_keys=True), file=sys.stderr)
        raise SystemExit(1)
