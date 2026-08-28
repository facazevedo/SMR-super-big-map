#!/usr/bin/env python3
"""Offline transaction and ownership certificate for v957 patch-local height install.

This checker does not launch the game. It fault-injects discovery, snapshot, write, and verification
failures into an executable grid model, then checks that production uses the stock editor
difference-box/GetGrid/SetGrid path with a complete pre-write journal, reverse rollback, literal
full-setter fallback, exact final verification, and the certified-or-canonical final grid path.
"""

from __future__ import annotations

import hashlib
import json
import math
import sys
from dataclasses import dataclass
from pathlib import Path


ROOT = Path(__file__).resolve().parents[3]
TERRAIN_PATH = ROOT / "Code" / "sbm_terrain_copy.lua"
CONFIG_PATH = ROOT / "Code" / "sbm_config.lua"
GENERATION_PATH = ROOT / "Code" / "sbm_map_generation.lua"
METADATA_PATH = ROOT / "metadata.lua"


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest().upper()


@dataclass(frozen=True, order=True)
class Box:
    y0: int
    x0: int
    y1: int
    x1: int

    @property
    def cells(self) -> int:
        return (self.x1 - self.x0) * (self.y1 - self.y0)


def make_grid(width: int, height: int) -> list[list[int]]:
    return [[1000 + x * 3 + y * 5 for x in range(width)] for y in range(height)]


def extract(grid: list[list[int]], box: Box) -> list[list[int]]:
    return [row[box.x0 : box.x1] for row in grid[box.y0 : box.y1]]


def install(grid: list[list[int]], box: Box, patch: list[list[int]]) -> None:
    for local_y, row in enumerate(patch):
        grid[box.y0 + local_y][box.x0 : box.x1] = row


BOXES = (
    Box(2, 3, 7, 11),
    Box(8, 53, 15, 60),
    Box(49, 4, 58, 12),
    Box(52, 47, 61, 57),
)

# Iter180's exact successful patch journal: eight disjoint boxes covered 1,890,334 of the
# 8192x8192 height cells. The engine's integral division serialized this non-zero ratio as zero.
ITER180_PATCH_BOXES = 8
ITER180_PATCH_CELLS = 1_890_334
ITER180_MAP_CELLS = 8_192 * 8_192
ITER180_LEGACY_INTEGRAL_RATIO = ITER180_PATCH_CELLS // ITER180_MAP_CELLS
ITER180_NORMALIZED_AREA_RATIO = (ITER180_PATCH_CELLS + 0.0) / ITER180_MAP_CELLS


def target_grid(source: list[list[int]]) -> list[list[int]]:
    target = [row[:] for row in source]
    for ordinal, box in enumerate(BOXES, 1):
        for y in range(box.y0, box.y1):
            for x in range(box.x0, box.x1):
                target[y][x] += ordinal * 17 + (x + y) % 5
    return target


def modeled_transaction(
    *,
    fail_snapshot_at: int | None = None,
    fail_write_at: int | None = None,
    corrupt_after_write: bool = False,
    malformed_discovery: bool = False,
    fail_rollback_at: int | None = None,
    mutate_then_throw_at: int | None = None,
    raw_alias_live: bool = False,
    corrupt_rollback_at: int | None = None,
) -> dict[str, object]:
    source = make_grid(64, 64)
    target = target_grid(source)
    live = [row[:] for row in source]
    raw = live if raw_alias_live else [row[:] for row in source]
    boxes = list(BOXES)
    if malformed_discovery:
        boxes.append(Box(4, 4, 10, 10))  # overlaps the first box and must fail pre-write
    boxes.sort()
    records: list[tuple[Box, list[list[int]], list[list[int]]]] = []
    applied = 0
    patch_used = False
    rollback_attempted = False
    rollback_ok = True
    rollback_verified = True
    rollback_exact_before_fallback = True
    raw_whole_grid_would_false_pass = False
    rollback_mismatch_error = ""
    failure = ""

    try:
        for index, box in enumerate(boxes):
            for prior in boxes[:index]:
                overlap = (
                    box.x0 < prior.x1
                    and prior.x0 < box.x1
                    and box.y0 < prior.y1
                    and prior.y0 < box.y1
                )
                if overlap:
                    raise RuntimeError("overlap")
        for index, box in enumerate(boxes, 1):
            if fail_snapshot_at == index:
                raise RuntimeError("snapshot")
            records.append((box, extract(raw, box), extract(target, box)))
        for index, (box, _before, after) in enumerate(records, 1):
            # Production treats a started native call as potentially mutating even if it reports
            # failure, so the current record joins the reverse rollback journal before invocation.
            applied += 1
            if fail_write_at == index:
                raise RuntimeError("write")
            install(live, box, after)
            if mutate_then_throw_at == index:
                raise RuntimeError("mutate-then-throw")
        if corrupt_after_write:
            live[BOXES[0].y0][BOXES[0].x0] += 1
        if live != target:
            raise RuntimeError("verify")
        patch_used = True
    except RuntimeError as exc:
        failure = str(exc)
        if applied:
            rollback_attempted = True
            for index, (box, before, _after) in enumerate(reversed(records[:applied]), 1):
                if fail_rollback_at == index:
                    rollback_ok = False
                else:
                    install(live, box, before)
                if corrupt_rollback_at == index:
                    live[box.y0][box.x0] += 1
            rollback_verified = all(
                extract(live, box) == before
                for box, before, _after in records[:applied]
            )
            if not rollback_verified:
                # Exact error text returned by the modeled difference comparator. Production must
                # preserve this second Lua return instead of collapsing it through an `and`.
                rollback_mismatch_error = "height-grid verification retained differences"
            raw_whole_grid_would_false_pass = (
                raw_alias_live and raw == live and not rollback_verified
            )
            rollback_exact_before_fallback = live == source
        # This is the unchanged canonical terrain.SetHeightGrid fallback model.
        live = [row[:] for row in target]

    return {
        "patch_used": patch_used,
        "fallback_used": not patch_used,
        "rollback_attempted": rollback_attempted,
        "rollback_ok": rollback_ok,
        "rollback_verified": rollback_verified,
        "rollback_exact_before_fallback": rollback_exact_before_fallback,
        "raw_whole_grid_would_false_pass": raw_whole_grid_would_false_pass,
        "rollback_mismatch_error": rollback_mismatch_error,
        "final_exact": live == target,
        "inner_exact": all(
            live[y][x] == source[y][x]
            for y in range(16, 48)
            for x in range(16, 48)
        ),
        "failure": failure,
    }


def modeled_owner_sequence(
    *, fail_write_at: int | None = None, fail_end_at: int | None = None,
    verification_succeeds: bool = True,
) -> dict[str, object]:
    """Model the eight exact synchronous patch-owner brackets and fail-closed acceptance."""
    started = completed = failed = 0
    first_serial = last_serial = 0
    for index in range(1, ITER180_PATCH_BOXES + 1):
        serial = index
        started += 1
        first_serial = first_serial or serial
        last_serial = serial
        write_ok = index != fail_write_at
        end_ok = index != fail_end_at
        if write_ok and end_ok:
            completed += 1
        else:
            failed += 1
            break
    accepted = (
        verification_succeeds
        and started == ITER180_PATCH_BOXES
        and completed == ITER180_PATCH_BOXES
        and failed == 0
        and first_serial == 1
        and last_serial == 8
    )
    return {
        "accepted": accepted,
        "started": started,
        "completed": completed,
        "failed": failed,
        "first_serial": first_serial,
        "last_serial": last_serial,
    }


def semantic_checks() -> tuple[dict[str, bool], list[dict[str, object]]]:
    cases = [{"case": "success", **modeled_transaction()}]
    cases.extend(
        {"case": f"snapshot-failure-{index}", **modeled_transaction(fail_snapshot_at=index)}
        for index in range(1, len(BOXES) + 1)
    )
    cases.extend(
        {"case": f"write-failure-{index}", **modeled_transaction(fail_write_at=index)}
        for index in range(1, len(BOXES) + 1)
    )
    cases.append({"case": "verification-failure", **modeled_transaction(corrupt_after_write=True)})
    cases.append(
        {
            "case": "rollback-failure",
            **modeled_transaction(fail_write_at=4, fail_rollback_at=1),
        }
    )
    cases.append(
        {
            "case": "setgrid-mutates-then-throws",
            **modeled_transaction(mutate_then_throw_at=2),
        }
    )
    cases.append(
        {
            "case": "raw-live-alias-regression",
            **modeled_transaction(
                mutate_then_throw_at=3,
                raw_alias_live=True,
                corrupt_rollback_at=1,
            ),
        }
    )
    cases.append({"case": "malformed-discovery", **modeled_transaction(malformed_discovery=True)})
    success = cases[0]
    failures = cases[1:]
    owner_success = modeled_owner_sequence()
    owner_write_failure = modeled_owner_sequence(fail_write_at=5)
    owner_end_failure = modeled_owner_sequence(fail_end_at=6)
    owner_verify_failure = modeled_owner_sequence(verification_succeeds=False)
    checks = {
        "success_installs_exact_target_without_full_fallback": (
            success["patch_used"] is True
            and success["fallback_used"] is False
            and success["final_exact"] is True
        ),
        "every_failure_falls_back_to_exact_target": all(
            case["fallback_used"] is True and case["final_exact"] is True
            for case in failures
        ),
        "partial_writes_restore_exact_preimage_before_fallback": all(
            case["rollback_exact_before_fallback"] is True
            for case in failures
            if case["case"] not in ("rollback-failure", "raw-live-alias-regression")
        ),
        "rollback_failure_still_reaches_exact_full_setter": (
            next(case for case in cases if case["case"] == "rollback-failure")["rollback_ok"]
            is False
            and next(case for case in cases if case["case"] == "rollback-failure")["final_exact"]
            is True
        ),
        "mutate_then_throw_is_rolled_back_from_started_write_journal": (
            next(case for case in cases if case["case"] == "setgrid-mutates-then-throws")[
                "rollback_verified"
            ]
            is True
            and next(
                case for case in cases if case["case"] == "setgrid-mutates-then-throws"
            )["rollback_exact_before_fallback"]
            is True
        ),
        "immutable_box_snapshots_detect_raw_live_alias_false_positive": (
            next(case for case in cases if case["case"] == "raw-live-alias-regression")[
                "raw_whole_grid_would_false_pass"
            ]
            is True
            and next(case for case in cases if case["case"] == "raw-live-alias-regression")[
                "rollback_verified"
            ]
            is False
        ),
        "rollback_mismatch_preserves_real_comparator_error": (
            next(case for case in cases if case["case"] == "raw-live-alias-regression")[
                "rollback_mismatch_error"
            ]
            == "height-grid verification retained differences"
        ),
        "iter180_32bit_integral_division_reproduces_false_zero": (
            ITER180_PATCH_BOXES == 8
            and ITER180_PATCH_CELLS < 2**31
            and ITER180_MAP_CELLS < 2**31
            and ITER180_LEGACY_INTEGRAL_RATIO == 0
        ),
        "iter180_early_float_area_ratio_matches_exact_oracle": (
            math.isclose(
                ITER180_NORMALIZED_AREA_RATIO,
                0.028168171644210815,
                rel_tol=0,
                abs_tol=1e-15,
            )
            and round(ITER180_NORMALIZED_AREA_RATIO * 1_000_000) == 28_168
            and 0 < ITER180_NORMALIZED_AREA_RATIO < 0.20
        ),
        "prewrite_failures_never_need_rollback": all(
            case["rollback_attempted"] is False
            for case in cases
            if case["case"].startswith("snapshot") or case["case"] == "malformed-discovery"
        ),
        "all_paths_preserve_inner_no_write_bytes": all(case["inner_exact"] for case in cases),
        "exact_eight_owner_sequence_is_accepted": (
            owner_success["accepted"] is True
            and owner_success["started"] == owner_success["completed"] == 8
            and owner_success["failed"] == 0
            and owner_success["first_serial"] == 1
            and owner_success["last_serial"] == 8
        ),
        "write_end_or_verification_failure_rejects_owner_sequence": (
            owner_write_failure["accepted"] is False
            and owner_end_failure["accepted"] is False
            and owner_verify_failure["accepted"] is False
            and owner_write_failure["failed"] == 1
            and owner_end_failure["failed"] == 1
        ),
    }
    return checks, cases


def structural_checks(terrain: str, config: str, generation: str, metadata: str) -> dict[str, bool]:
    start = terrain.index("local function PrepareOuterResourceTerrain")
    end = terrain.index("\n-- TEST-ONLY SEAM", start)
    section = terrain[start:end]
    transaction = section.index("local function install_native_height_patches")
    discovery = section.index("editor_api.GetGridDifferenceBoxes, map, \"height\", grid, raw", transaction)
    snapshot = section.index("editor_api.GetGrid, map, \"height\", record.box, raw", discovery)
    write = section.index("editor_api.SetGrid, map, \"height\", record.after", snapshot)
    verify = section.index("grids_are_equal(grid, live)", write)
    rollback = section.index("for index = #records, 1, -1 do", write)
    rollback_read = section.index('editor_api.GetGrid, map, "height", record.box)', rollback)
    rollback_compare = section.index(
        "record.before, record.rollback_live, local_box", rollback_read
    )
    cleanup = section.index("local cleanup_error = free_record_grids()", rollback_compare)
    fallback = section.index("pcall(terrain_api.SetHeightGrid, map, grid)", rollback)
    return {
        "default_on_config_is_compiled": (
            "config.OptimizeOuterResourceTerrainPatchInstall = true" in config
            and "C.OPTIMIZE_OUTER_RESOURCE_TERRAIN_PATCH_INSTALL" in config
            and '"OPTIMIZE_OUTER_RESOURCE_TERRAIN_PATCH_INSTALL", true' in section
        ),
        "stock_difference_snapshot_write_order_is_explicit": (
            transaction < discovery < snapshot < write < verify < rollback < fallback
        ),
        "all_snapshots_precede_first_live_write": (
            "Capture the entire rollback journal before the first live write." in section
            and section.index("for _, record in ipairs(records) do", snapshot - 200)
            < section.index("apply_started_ms = now_ms()", snapshot)
            < write
        ),
        "geometry_and_allocation_guards_fail_closed": all(
            token in section
            for token in (
                "difference entry is not a box",
                "difference box is outside the live height grid",
                "difference box is not height-tile aligned",
                "difference box does not intersect the outer resource ring",
                "difference box is not contained by the later ring rebuild",
                "stock difference discovery exceeded the bounded box budget",
                "stock difference boxes overlap",
                "local area_ratio = 0.0",
                "local width_ratio = (box_width + 0.0) / map_w",
                "local height_ratio = (box_height + 0.0) / map_h",
                "value == value",
                "value >= 0 and value <= 1",
                "valid_area_fraction(box_area_ratio)",
                "valid_area_fraction(area_ratio)",
                "value ~= math.huge and value ~= -math.huge",
                "difference-box normalized dimension ratio is invalid",
                "difference-box normalized area ratio is invalid",
                "cumulative difference-box area ratio is invalid",
                "area_ratio > 0.20",
                "difference-box area is outside the bounded outer-ring budget",
                "height snapshot does not match its world box",
            )
        ) and "((record.x1 - record.x0) / map_w)" not in section,
        "each_patch_write_has_exact_causal_owner_bracket": (
            all(
                token in section
                for token in (
                    'generation_grids.BeginSurfaceFinalOwnedPassRebuild(',
                    'map, "outer resource height patch install", record_index',
                    'editor_api.SetGrid, map, "height", record.after, record.box',
                    "generation_grids.EndSurfaceFinalOwnedPassRebuild,",
                    "map, owner_serial, write_succeeded",
                    "patch_install.owner_calls_started",
                    "patch_install.owner_calls_completed",
                    "patch_install.owner_calls_failed",
                    "patch_install_owner_first_serial = patch_install.owner_first_serial",
                    "patch_install_owner_last_serial = patch_install.owner_last_serial",
                )
            )
            and section.index("BeginSurfaceFinalOwnedPassRebuild(", write - 1200) < write
            < section.index("EndSurfaceFinalOwnedPassRebuild,", write)
        ),
        "ring_supersession_and_native_inner_restore_are_verified": all(
            token in section
            for token in (
                "y1 <= ring_inner_y or y0 >= ring_far_y",
                "x1 <= ring_inner_x or x0 >= ring_far_x",
                "patch_install.ring_supersession_verified = true",
                "grids_are_equal(grid, live)",
                "native target modified the exact inner no-write rectangle",
                "patch_install.native_inner_restore_exact = true",
                "patch_install_ring_supersession_verified = patch_install.ring_supersession_verified",
                "patch_install_native_inner_restore_exact = patch_install.native_inner_restore_exact",
            )
        ),
        "partial_failure_rolls_back_reverse_and_verifies": all(
            token in section
            for token in (
                "if not transaction_ok and applied_count > 0 then",
                "for index = #records, 1, -1 do",
                'editor_api.SetGrid, map, "height", record.before, record.box',
                'editor_api.GetGrid, map, "height", record.box)',
                'record.before, record.rollback_live, local_box',
                "patch_install.rollback_verified = verify_ok",
                "local equal, equality_error = grids_are_equal(",
                ".. tostring(equality_error)",
                "height patch snapshot cleanup failed: ",
            )
        ) and "grids_are_equal(raw, live)" not in section,
        "immutable_before_snapshots_survive_until_box_verification": (
            rollback < rollback_read < rollback_compare < cleanup < fallback
            and 'for _, name in ipairs({ "before", "after", "rollback_live" })' in section
            and "Keep those snapshots owned until this finishes." in section
        ),
        "literal_full_setter_is_the_fail_closed_fallback": (
            "if not set_ok then" in section[fallback - 800 : fallback + 200]
            and "patch_install.fallback = true" in section[fallback - 800 : fallback + 200]
            and "patch_install.full_setter_used = true" in section[fallback - 800 : fallback + 200]
        ),
        "no_editor_height_message_is_emitted": "EditorHeightChanged" not in section,
        "canonical_final_passability_and_buildable_rebuild_is_retained": all(
            token in generation
            for token in (
                "terrain_api.RebuildPassability(map, final_pass_box)",
                "local rebuild_buildable = Global(\"RebuildBuildableGrid\")",
                "rebuild_buildable, map",
                'map, "after last object-grid transaction"',
            )
        ),
        "telemetry_distinguishes_patch_fallback_and_rollback": all(
            token in section
            for token in (
                "patch_install_used = patch_install.used",
                "patch_install_verified = patch_install.verified",
                "patch_install_fallback = patch_install.fallback",
                "patch_install_full_setter_used = patch_install.full_setter_used",
                "patch_install_rollback_attempted = patch_install.rollback_attempted",
                "patch_install_rollback_verified = patch_install.rollback_verified",
                "patch_install_owner_calls_started = patch_install.owner_calls_started",
                "patch_install_owner_calls_completed = patch_install.owner_calls_completed",
                "patch_install_owner_calls_failed = patch_install.owner_calls_failed",
                "canonical_final_grid_rebuild_retained = true",
            )
        ),
        "metadata_is_v957": (
            "'version', 957" in metadata
            and "Causally certify patch-install passability notifications for the closing regional rebuild."
            in metadata
        ),
    }


def main() -> int:
    terrain = TERRAIN_PATH.read_text(encoding="utf-8")
    config = CONFIG_PATH.read_text(encoding="utf-8")
    generation = GENERATION_PATH.read_text(encoding="utf-8")
    metadata = METADATA_PATH.read_text(encoding="utf-8")
    semantic, cases = semantic_checks()
    structural = structural_checks(terrain, config, generation, metadata)
    result = {
        "schema": "smr.ralph.outer_resource_patch_install_check.v6",
        "ok": all(semantic.values()) and all(structural.values()),
        "semantic_checks": semantic,
        "structural_checks": structural,
        "fault_cases": cases,
        "iter180_area_oracle": {
            "boxes": ITER180_PATCH_BOXES,
            "patch_cells": ITER180_PATCH_CELLS,
            "map_cells": ITER180_MAP_CELLS,
            "legacy_integral_ratio": ITER180_LEGACY_INTEGRAL_RATIO,
            "normalized_area_ratio": ITER180_NORMALIZED_AREA_RATIO,
            "normalized_area_ppm": round(ITER180_NORMALIZED_AREA_RATIO * 1_000_000),
        },
        "terrain_sha256": sha256(TERRAIN_PATH),
        "config_sha256": sha256(CONFIG_PATH),
        "generation_sha256": sha256(GENERATION_PATH),
        "metadata_sha256": sha256(METADATA_PATH),
    }
    print(json.dumps(result, indent=2, sort_keys=True))
    return 0 if result["ok"] else 1


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (AssertionError, ValueError) as exc:
        print(json.dumps({"ok": False, "error": repr(exc)}, sort_keys=True), file=sys.stderr)
        raise SystemExit(1)
