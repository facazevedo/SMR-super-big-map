#!/usr/bin/env python3
"""Audit frozen determinism checkpoints for guard-corpus boundary coverage.

This fail-closed source/reference audit answers only whether the accepted v888
36-checkpoint protocol already contains a snapshot immediately before every
initial/repair PrepareOuterResourceTerrain call with the inputs needed to
reconstruct its exact ordered guard and shaping-pass corpus.
"""

from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path


SCHEMA = "smr.ralph.guard_corpus_checkpoint_coverage.v1"
EXPECTED = (
    ("pre_stock_generation", ("rng_state", "prefab_order", "generation_inputs")),
    ("stock_surface_output", ("surface_height", "surface_terrain", "object_census")),
    ("pre_z_transform", ("surface_height", "surface_terrain", "object_census")),
    ("post_z_transform", ("surface_height", "surface_terrain", "zone_stamp")),
    ("post_object_transform", ("object_census", "collision_census")),
    ("pre_init_buildable", (
        "surface_height", "surface_terrain", "passability", "buildable",
        "collision_census",
    )),
    ("post_init_buildable", (
        "surface_height", "surface_terrain", "passability", "buildable",
        "collision_census",
    )),
    ("post_process_buildable", (
        "surface_height", "surface_terrain", "passability", "buildable",
        "collision_census",
    )),
    ("final_stable", (
        "surface_height", "underground_height", "surface_passability",
        "surface_buildable", "underground_passability", "underground_buildable",
        "object_census",
    )),
)


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest().upper()


def line_of(lines: list[str], needle: str, *, start: int = 0) -> int:
    for index in range(start, len(lines)):
        if needle in lines[index]:
            return index + 1
    raise ValueError(f"required source token is missing: {needle}")


def expected_ids() -> list[str]:
    return [f"{stage}:{name}" for stage, names in EXPECTED for name in names]


def audit(
    generation_path: Path,
    terrain_path: Path,
    producer_path: Path,
    reference_path: Path,
) -> dict:
    generation = generation_path.read_text(encoding="utf-8").splitlines()
    terrain = terrain_path.read_text(encoding="utf-8").splitlines()
    producer = producer_path.read_text(encoding="utf-8").splitlines()
    reference = json.loads(reference_path.read_text(encoding="utf-8"))

    post_object = line_of(
        generation, 'SuperBigMap.NotifyDeterminismCaptureForTest("post_object_transform"')
    topup = line_of(generation, "deposits.TopUpDeposits, map", start=post_object)
    initial_prepare = line_of(
        generation, "TerrainCopy.PrepareOuterResourceTerrain, map", start=topup)
    initial_audit = line_of(
        generation, "TerrainCopy.AuditOuterResourceTerrain(map)", start=initial_prepare)
    repair_loop = line_of(
        generation, "while resource_terrain_ok ~= true and terrain_repair_attempt < 2",
        start=initial_audit,
    )
    repair_prepare = line_of(
        generation, "TerrainCopy.PrepareOuterResourceTerrain, map", start=repair_loop)
    surface_done = line_of(
        generation, "map.SuperBigMapSurfaceStretchDone = true", start=repair_prepare)

    prepare_start = line_of(terrain, "local function PrepareOuterResourceTerrain(map)")
    prepare_end = line_of(terrain, "local function AuditOuterResourceTerrain(map)") - 1
    height_read = line_of(terrain, "local raw = terrain_api.GetHeightGrid(map)", start=prepare_start)
    previous_sites_read = line_of(
        terrain,
        'if type(map.SuperBigMapOuterResourceTerrainSites) == "table" then',
        start=prepare_start,
    )
    resource_enumeration = line_of(
        terrain, 'pcall(map.MapForEach, map, "map", "DepositMarker"', start=prepare_start)
    readiness_read = line_of(
        terrain, "local grid_ready = exact_extractor_offsets", start=prepare_start)
    guard_list = line_of(terrain, "local protected_ready_sites = {}", start=prepare_start)
    patch_list = line_of(
        terrain, "local patches, resource_sites, rocket_sites = {}, {}, {}", start=prepare_start)
    pass_radius_read = line_of(
        terrain, "local old = grid_value(patch.cx + dx, patch.cy + dy)", start=prepare_start)

    object_rows_start = line_of(producer, "local function object_rows(map, collision_only)")
    object_rows_end = line_of(producer, "local function save_objects", start=object_rows_start) - 1
    object_rows = "\n".join(producer[object_rows_start - 1:object_rows_end])
    finalizer = line_of(producer, 'rawset(_G, "g_FzpDeterminismCaptureFinalize", function()')
    completed_maps_required = line_of(
        producer, "maps.surface.SuperBigMapSurfaceStretchDone ~= true", start=finalizer)
    final_buildable_capture = line_of(
        producer, "capture_buildable_phases(maps.surface)", start=completed_maps_required)
    final_snapshot = line_of(producer, "save_final(maps)", start=final_buildable_capture)

    reference_ids = [row.get("id") for row in reference.get("checkpoints", [])]
    frozen_stages = [stage for stage, _ in EXPECTED]
    required_block_start = line_of(producer, "local required = {")
    required_block_end = line_of(
        producer, 'rawset(_G, "g_FzpDeterminismCaptureRequiredArtifacts", required)',
        start=required_block_start,
    )
    required_block = "\n".join(producer[required_block_start - 1:required_block_end])
    early_to_initial = "\n".join(generation[topup - 1:initial_prepare - 1])
    repair_entry = "\n".join(generation[repair_loop - 1:repair_prepare - 1])

    checks = {
        "reference_is_frozen_rough_v888": (
            reference.get("schema") == "smr.ralph.checkpoint_reference.v1"
            and reference.get("ok") is True
            and reference.get("checkpoint_count") == 36
            and reference.get("checkpoint_aggregate_sha256")
            == "BA68EAB4FB1BA0884DF16D31AFFA6A67C894AB64C79B67EDBF87730BF3552131"
            and reference.get("identity", {}).get("coordinate") == "14N134W"
            and reference.get("identity", {}).get("preset") == "RoughTerrain"
            and str(reference.get("identity", {}).get("source_commit", "")).startswith("f297615")
        ),
        "reference_ids_match_protocol_exactly": reference_ids == expected_ids(),
        "producer_declares_every_frozen_stage": all(
            f"\t{stage} = {{" in required_block for stage in frozen_stages
        ),
        "latest_early_hook_precedes_topup_and_initial_prepare": (
            post_object < topup < initial_prepare < initial_audit < repair_loop < repair_prepare
        ),
        "no_hook_between_topup_and_initial_prepare": (
            "NotifyDeterminismCaptureForTest" not in early_to_initial
        ),
        "no_hook_before_repair_prepare": (
            "NotifyDeterminismCaptureForTest" not in repair_entry
        ),
        "late_captures_require_completed_surface": (
            finalizer < completed_maps_required < final_buildable_capture < final_snapshot
        ),
        "surface_completes_after_all_prepare_calls": repair_prepare < surface_done,
        "object_census_discards_iteration_order": "table.sort(rows)" in object_rows,
        "object_census_omits_boundary_inputs": not any(token in object_rows for token in (
            "ready_before", "force_retry", "SuperBigMapOuterResourceTerrainSites",
            "SuperBigMapResourceClusterPlan", "SuperBigMapResourceClusterStrength",
            "SuperBigMapResourceClusterResourceTarget",
            "SuperBigMapResourceClusterExtractorTarget",
        )),
        "preparation_reads_all_missing_input_classes": all(
            prepare_start <= row <= prepare_end for row in (
                height_read, previous_sites_read, resource_enumeration, readiness_read,
                guard_list, patch_list, pass_radius_read,
            )
        ),
    }
    source_audit_ok = all(checks.values())

    requirements = {
        "height_at_each_pre_call_boundary": False,
        "resource_set_and_identity_at_each_pre_call_boundary": False,
        "passability_buildability_readiness_at_each_pre_call_boundary": False,
        "prior_failure_state_for_each_repair_call": False,
        "ordered_resource_guard_and_patch_inputs": False,
        "checkpoint_for_initial_and_every_possible_repair_call": False,
    }
    gaps = [
        {
            "id": "no_initial_boundary",
            "detail": (
                "The last in-pipeline checkpoint is post_object_transform, before TopUpDeposits; "
                "there is no notification after top-up and before the initial preparation call."
            ),
            "evidence_lines": {
                "post_object_transform": post_object,
                "top_up_deposits": topup,
                "initial_prepare": initial_prepare,
            },
        },
        {
            "id": "no_repair_boundary",
            "detail": (
                "The bounded repair loop can call preparation again, but has no checkpoint before "
                "that call and the frozen protocol contains no per-call stage."
            ),
            "evidence_lines": {
                "repair_loop": repair_loop,
                "repair_prepare": repair_prepare,
            },
        },
        {
            "id": "early_snapshots_are_incomplete_and_too_early",
            "detail": (
                "Early height/object snapshots precede top-up. The post-object census has no height, "
                "passability/buildability readiness, prior-failure table, cluster planning fields, "
                "or stable object identity, and it sorts rows so traversal order is discarded."
            ),
            "evidence_lines": {
                "object_rows_start": object_rows_start,
                "object_rows_end": object_rows_end,
            },
        },
        {
            "id": "complete_snapshots_are_too_late",
            "detail": (
                "Buildable/passability and final snapshots are generated only by a finalizer that "
                "requires SuperBigMapSurfaceStretchDone, after all initial/repair calls."
            ),
            "evidence_lines": {
                "finalizer": finalizer,
                "completed_surface_required": completed_maps_required,
                "buildable_capture": final_buildable_capture,
                "final_snapshot": final_snapshot,
            },
        },
    ]

    return {
        "schema": SCHEMA,
        "source_audit_ok": source_audit_ok,
        "existing_checkpoint_sufficient": False if source_audit_ok else None,
        "scope": (
            "accepted v888 determinism checkpoints versus exact pre-call inputs for every "
            "initial/repair PrepareOuterResourceTerrain invocation"
        ),
        "checks": checks,
        "required_input_coverage": requirements if source_audit_ok else None,
        "gaps": gaps,
        "frozen_reference": {
            "path": reference_path.as_posix(),
            "sha256": sha256(reference_path),
            "checkpoint_count": reference.get("checkpoint_count"),
            "checkpoint_aggregate_sha256": reference.get("checkpoint_aggregate_sha256"),
            "stage_order": frozen_stages,
        },
        "sources": {
            "generation": {"path": generation_path.as_posix(), "sha256": sha256(generation_path)},
            "terrain": {"path": terrain_path.as_posix(), "sha256": sha256(terrain_path)},
            "producer": {"path": producer_path.as_posix(), "sha256": sha256(producer_path)},
        },
        "conclusion": (
            "Disproved: no accepted checkpoint is aligned after TopUpDeposits and immediately "
            "before the initial call or every repair call, and no frozen checkpoint retains all "
            "height, resource, readiness, prior-failure, order, and identity inputs. Exact corpus "
            "capture still requires a new boundary-time observation or equivalent preserved snapshot."
        ) if source_audit_ok else "Source/reference shape changed; no conclusion is authorized.",
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--generation", type=Path, default=Path("Code/sbm_map_generation.lua"))
    parser.add_argument("--terrain", type=Path, default=Path("Code/sbm_terrain_copy.lua"))
    parser.add_argument(
        "--producer", type=Path,
        default=Path("_ralph/tools/parity/determinism_capture_probe.lua"),
    )
    parser.add_argument("--reference", type=Path, required=True)
    parser.add_argument("--out", type=Path, required=True)
    args = parser.parse_args()
    report = audit(
        args.generation.resolve(), args.terrain.resolve(), args.producer.resolve(),
        args.reference.resolve(),
    )
    output = args.out.resolve()
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    print(json.dumps(report, indent=2, sort_keys=True))
    return 0 if report["source_audit_ok"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
