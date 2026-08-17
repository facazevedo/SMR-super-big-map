#!/usr/bin/env python3
"""Score a full live replay of perimetercheck.py's compact stock-box union."""

from __future__ import annotations

import argparse
import csv
import hashlib
import itertools
import json
import math
from pathlib import Path

import numpy as np

import perimetercheck
import propertycheck


HERE = Path(__file__).resolve().parent
DEFAULT_OUT_DIR = HERE / "out"
STAGES = (
    "baseline", "direct", "bare", "callback1", "callback2", "callback_cleanup",
    "marker1", "marker2", "marker_cleanup", "direct_plus1", "plus1_bare",
    "callback_plus1", "callback_plus1_repeat",
    "post_rebuild_plus1", "post_rebuild_plus1_repeat", "cleanup",
)
EDGE_NAMES = ("minx", "maxx", "miny", "maxy")
EXPECTED_REPLAY_VERSION = 3
RESIDUAL_FIELDS = (
    "env", "comparison", "sx", "sy", "wx", "wy", "baseline", "direct",
    "production",
    "callback1", "marker1", "direct_plus1", "callback_plus1",
    "post_rebuild_plus1", "post_rebuild_plus1_repeat",
    "closed_box_member", "nearest_box_id", "nearest_box_kind",
    "outside_dx", "outside_dy", "outside_chebyshev",
)


def canonical_sha(boxes: list[dict[str, int]]) -> str:
    serialized = json.dumps(boxes, sort_keys=True, separators=(",", ":"))
    return hashlib.sha256(serialized.encode("utf-8")).hexdigest()


def load_engine_boxes(report_path: Path) -> tuple[list[dict[str, int]], str, str]:
    report = json.loads(report_path.read_text(encoding="utf-8"))
    per_map: dict[str, list[dict[str, int]]] = {}
    source_shas: set[str] = set()
    for env in ("surface", "underground"):
        compact = report["maps"][env]["compact_closed_box_union"]
        source_shas.add(str(compact["box_union_sha256"]))
        per_map[env] = [
            {
                "minx": math.floor(float(row["minx"])),
                "miny": math.floor(float(row["miny"])),
                "maxx": math.ceil(float(row["maxx"])),
                "maxy": math.ceil(float(row["maxy"])),
            }
            for row in compact["boxes"]
        ]
    if len(source_shas) != 1:
        raise RuntimeError("surface and underground source box hashes differ")
    if per_map["surface"] != per_map["underground"]:
        raise RuntimeError("surface and underground engine box unions differ")
    boxes = per_map["surface"]
    return boxes, next(iter(source_shas)), canonical_sha(boxes)


def lua_boxes(boxes: list[dict[str, int]]) -> str:
    rows = [
        f"{{{b['minx']},{b['miny']},{b['maxx']},{b['maxy']}}}"
        for b in boxes
    ]
    return "{\n\t" + ",\n\t".join(rows) + "\n}"


def kv(parts: list[str]) -> dict[str, str]:
    return dict(part.split("=", 1) for part in parts)


def parse_probe(path: Path) -> dict[str, object]:
    result: dict[str, object] = {
        "maps": {}, "calibrations": [], "boxes": [], "traces": [],
    }
    maps: dict[str, dict[str, object]] = result["maps"]  # type: ignore[assignment]
    for line in path.read_text(encoding="utf-8").splitlines():
        parts = line.split(",")
        if parts[0] == "boxes":
            result["box_meta"] = kv(parts[1:])
        elif parts[0] == "box":
            result["boxes"].append(kv(parts[1:]))  # type: ignore[union-attr]
        elif parts[0] == "map":
            row = kv(parts[1:])
            maps.setdefault(row["env"], {})["map"] = row
        elif parts[0] == "calibration":
            result["calibrations"].append(kv(parts[1:]))  # type: ignore[union-attr]
        elif parts[0] == "snapshot":
            row = kv(parts[1:])
            maps.setdefault(row["env"], {}).setdefault("snapshots", {})[row["stage"]] = row
        elif parts[0] == "production":
            row = kv(parts[1:])
            maps.setdefault(row["env"], {})["production"] = row
        elif parts[0] == "hash":
            row = kv(parts[1:])
            maps.setdefault(row["env"], {})["hashes"] = row
        elif parts[0] == "passgrid":
            row = kv(parts[1:])
            maps.setdefault(row["env"], {}).setdefault("passgrids", {}).setdefault(
                row["stage"], {})[row["idx"]] = row
        elif parts[0] == "trace":
            result["traces"].append(kv(parts[1:]))  # type: ignore[union-attr]
    return result


def load_raw(base: Path, env: str, stage: str, gw: int, gh: int) -> np.ndarray:
    path = Path(f"{base}-{env}-{stage}.raw")
    data = np.fromfile(path, dtype=np.uint8)
    if data.size != gw * gh:
        raise RuntimeError(f"{path}: expected {gw * gh} bytes, got {data.size}")
    if bool(np.any(data > 1)):
        raise RuntimeError(f"{path}: non-binary passability value")
    return data.reshape((gh, gw)).astype(bool)


def edge_membership(
    world: np.ndarray,
    boxes: list[dict[str, int]],
    open_edges: tuple[bool, bool, bool, bool],
) -> np.ndarray:
    """Return box membership under one explicit four-edge convention."""
    x, y = world
    minx_open, maxx_open, miny_open, maxy_open = open_edges
    result = np.zeros(x.shape, dtype=bool)
    for box in boxes:
        result |= (
            ((x > box["minx"]) if minx_open else (x >= box["minx"]))
            & ((x < box["maxx"]) if maxx_open else (x <= box["maxx"]))
            & ((y > box["miny"]) if miny_open else (y >= box["miny"]))
            & ((y < box["maxy"]) if maxy_open else (y <= box["maxy"]))
        )
    return result


def edge_mode_name(open_edges: tuple[bool, bool, bool, bool]) -> str:
    return "_".join(
        f"{edge}_{'open' if is_open else 'closed'}"
        for edge, is_open in zip(EDGE_NAMES, open_edges)
    )


def nearest_box(
    x: float,
    y: float,
    boxes: list[dict[str, int]],
) -> tuple[int, float, float, float]:
    """Return 1-based box id and outside dx/dy/Chebyshev distance."""
    candidates = []
    for index, box in enumerate(boxes, 1):
        dx = max(float(box["minx"]) - x, 0.0, x - float(box["maxx"]))
        dy = max(float(box["miny"]) - y, 0.0, y - float(box["maxy"]))
        candidates.append((max(dx, dy), index, dx, dy))
    distance, index, dx, dy = min(candidates)
    return index, dx, dy, distance


def enumerate_residuals(
    env: str,
    comparison: str,
    differing: np.ndarray,
    world: np.ndarray,
    rasters: dict[str, np.ndarray],
    closed_membership: np.ndarray,
    boxes: list[dict[str, int]],
) -> list[dict[str, object]]:
    rows: list[dict[str, object]] = []
    gh, gw = differing.shape
    for sy, sx in zip(*np.nonzero(differing)):
        flat = int(sy) * gw + int(sx)
        x, y = float(world[0, flat]), float(world[1, flat])
        box_id, dx, dy, distance = nearest_box(x, y, boxes)
        rows.append({
            "env": env,
            "comparison": comparison,
            "sx": int(sx),
            "sy": int(sy),
            "wx": int(x),
            "wy": int(y),
            "baseline": int(rasters["baseline"][sy, sx]),
            "direct": int(rasters["direct"][sy, sx]),
            "production": int(rasters.get("production", rasters["baseline"])[sy, sx]),
            "callback1": int(rasters["callback1"][sy, sx]),
            "marker1": int(rasters["marker1"][sy, sx]),
            "direct_plus1": int(rasters["direct_plus1"][sy, sx]),
            "callback_plus1": int(rasters["callback_plus1"][sy, sx]),
            "post_rebuild_plus1": int(rasters["post_rebuild_plus1"][sy, sx]),
            "post_rebuild_plus1_repeat": int(
                rasters["post_rebuild_plus1_repeat"][sy, sx]),
            "closed_box_member": int(closed_membership[sy, sx]),
            "nearest_box_id": box_id,
            "nearest_box_kind": (
                ("core_left", "core_right", "core_top", "core_bottom")[box_id - 1]
                if box_id <= 4 else "fringe"
            ),
            "outside_dx": int(dx),
            "outside_dy": int(dy),
            "outside_chebyshev": int(distance),
        })
    return rows


def score_map(
    env: str,
    probe: dict[str, object],
    probe_base: Path,
    vstamp: propertycheck.ProbeStamp,
    estamp: propertycheck.ProbeStamp,
    boxes: list[dict[str, int]],
) -> tuple[dict[str, object], list[dict[str, object]]]:
    maps: dict[str, dict[str, object]] = probe["maps"]  # type: ignore[assignment]
    live = maps[env]
    meta: dict[str, str] = live["map"]  # type: ignore[assignment]
    hashes: dict[str, str] = live["hashes"]  # type: ignore[assignment]
    gw, gh = int(meta["gw"]), int(meta["gh"])
    expected_dims = propertycheck.dims(estamp, env)
    geometry = propertycheck.geometry_for(estamp, env)
    production_stamp = live.get("production")
    stages = (("production",) + STAGES) if production_stamp else STAGES
    rasters = {stage: load_raw(probe_base, env, stage, gw, gh) for stage in stages}

    passgrid_semantics = None
    passgrid_rows = live.get("passgrids")
    if passgrid_rows:
        expected_stages = ("production", "direct_plus1", "post_rebuild_plus1")
        stage_rows: dict[str, dict[str, dict[str, str]]] = passgrid_rows  # type: ignore[assignment]
        if set(stage_rows) != set(expected_stages):
            raise RuntimeError(f"{env}: incomplete pass-grid stages: {sorted(stage_rows)}")
        expected_indices = set(stage_rows["production"])
        if not expected_indices or any(set(stage_rows[stage]) != expected_indices
                                       for stage in expected_stages):
            raise RuntimeError(f"{env}: inconsistent pass-grid index sets")
        grid_reports = []
        serialized_controls_stable = True
        production_matches_control = True
        for idx_text in sorted(expected_indices, key=int):
            rows_by_stage = {stage: stage_rows[stage][idx_text] for stage in expected_stages}
            files = {
                stage: Path(f"{probe_base}-{env}-passgrid{idx_text}-{stage}.grid")
                for stage in expected_stages
            }
            for stage, path in files.items():
                if not path.is_file():
                    raise RuntimeError(f"{env}: missing serialized pass grid {path}")
                expected_bytes = int(rows_by_stage[stage]["bytes"])
                if path.stat().st_size != expected_bytes:
                    raise RuntimeError(
                        f"{env}: {path} expected {expected_bytes} bytes, got {path.stat().st_size}")
            blobs = {stage: path.read_bytes() for stage, path in files.items()}
            shas = {
                stage: hashlib.sha256(blob).hexdigest() for stage, blob in blobs.items()
            }
            prod_equal = blobs["production"] == blobs["direct_plus1"]
            control_equal = blobs["direct_plus1"] == blobs["post_rebuild_plus1"]
            repeat_equal = all(
                rows_by_stage[stage]["repeat_equal"] == "true" for stage in expected_stages)
            serialized_controls_stable &= control_equal and repeat_equal
            production_matches_control &= prod_equal
            idx = int(idx_text)
            grid_reports.append({
                "index": idx,
                "stock_name": ("DefaultPass", "DifficultTerrain")[idx]
                if idx < 2 else f"pass_grid_{idx}",
                "dimensions": {
                    "w": int(rows_by_stage["production"]["w"]),
                    "h": int(rows_by_stage["production"]["h"]),
                    "bits": int(rows_by_stage["production"]["bits"]),
                },
                "serialized_bytes": {
                    stage: len(blobs[stage]) for stage in expected_stages
                },
                "serialized_sha256": shas,
                "serialize_repeat_equal": repeat_equal,
                "production_matches_direct_plus1": prod_equal,
                "direct_plus1_matches_post_rebuild_plus1": control_equal,
            })
        aggregate_hash_equal = hashes["production"] == hashes["direct_plus1"]
        passgrid_semantics = {
            "stock_source": "Lua/Config/pathfind.lua:61-69",
            "hash_source": "CommonLua/Libs/Network/Network.lua:302-306",
            "exposed_grid_count": len(expected_indices),
            "grids": grid_reports,
            "serialization_controls_stable": serialized_controls_stable,
            "all_production_grids_match_independent_control": production_matches_control,
            "aggregate_hash_matches_independent_control": aggregate_hash_equal,
            "aggregate_hash_relation_matches_serialized_grids": (
                aggregate_hash_equal == production_matches_control),
            "gate_ok": serialized_controls_stable
            and production_matches_control
            and aggregate_hash_equal,
        }

    sy, sx = np.indices((gh, gw), dtype=np.float64)
    live_world = propertycheck.storage_to_world(geometry, sx.ravel(), sy.ravel())
    full_membership = perimetercheck.box_membership(live_world, boxes).reshape((gh, gw))
    predicted_direct = rasters["baseline"] & ~full_membership

    edge_controls = {}
    for open_edges in itertools.product((False, True), repeat=4):
        membership = edge_membership(live_world, boxes, open_edges).reshape((gh, gw))
        differences = int(np.count_nonzero(
            rasters["direct"] != (rasters["baseline"] & ~membership)))
        edge_controls[edge_mode_name(open_edges)] = differences
    exact_edge_modes = sorted(
        mode for mode, differences in edge_controls.items() if differences == 0)
    inferred_edges = (False, True, False, False)
    inferred_mode = edge_mode_name(inferred_edges)

    # Stock ForcedImpassableMarker:GetArea constructs inclusive editor extents by adding
    # one world unit to both maxima (CommonLua/Classes/marker.lua:749-762).  Applying that
    # stock convention to the supplied integer boxes compensates for the observed open
    # max-X raster edge without reaching another integer property-lattice site.
    stock_inclusive_boxes = [
        {**box, "maxx": box["maxx"] + 1, "maxy": box["maxy"] + 1}
        for box in boxes
    ]
    inferred_membership = edge_membership(
        live_world, boxes, inferred_edges).reshape((gh, gw))
    inclusive_membership = edge_membership(
        live_world, stock_inclusive_boxes, inferred_edges).reshape((gh, gw))
    inclusive_candidate_differences = int(np.count_nonzero(
        inclusive_membership != full_membership))

    mapping = propertycheck.map_sites(vstamp, estamp, env)
    ex = np.asarray(mapping["ex"])
    ey = np.asarray(mapping["ey"])
    vgeometry = propertycheck.geometry_for(vstamp, env)
    vgw, vgh = propertycheck.dims(vstamp, env)
    vsy, vsx = np.indices((vgh, vgw), dtype=np.float64)
    vanilla_world = propertycheck.storage_to_world(vgeometry, vsx.ravel(), vsy.ravel())
    vwidth, vheight = perimetercheck.map_size_wu(vstamp, env)
    border = float(vstamp.maps[env]["pass_border"])
    source_border = (
        (vanilla_world[0] < border)
        | (vanilla_world[0] > vwidth - border)
        | (vanilla_world[1] < border)
        | (vanilla_world[1] > vheight - border)
    ).reshape((vgh, vgw))
    mapped_membership = full_membership[ey, ex]
    baseline_mapped = rasters["baseline"][ey, ex]
    direct_mapped = rasters["direct"][ey, ex]
    direct_plus1_mapped = rasters["direct_plus1"][ey, ex]
    expected_mapped_direct = baseline_mapped & ~source_border

    full_prediction_diff = int(np.count_nonzero(rasters["direct"] != predicted_direct))
    mapped_membership_diff = int(np.count_nonzero(mapped_membership != source_border))
    mapped_direct_diff = int(np.count_nonzero(direct_mapped != expected_mapped_direct))
    mapped_direct_plus1_diff = int(np.count_nonzero(
        direct_plus1_mapped != expected_mapped_direct))
    direct_changes = int(np.count_nonzero(rasters["direct"] != rasters["baseline"]))
    direct_residual = rasters["direct"] != predicted_direct
    callback_direct_residual = rasters["callback1"] != rasters["direct"]
    marker_callback_residual = rasters["marker1"] != rasters["callback1"]
    plus1_prediction_residual = rasters["direct_plus1"] != predicted_direct
    plus1_callback_residual = rasters["callback_plus1"] != rasters["direct_plus1"]
    post_rebuild_residual = rasters["post_rebuild_plus1"] != rasters["direct_plus1"]
    post_rebuild_repeat_residual = (
        rasters["post_rebuild_plus1_repeat"] != rasters["direct_plus1"])
    marker_inside = int(np.count_nonzero(marker_callback_residual & full_membership))
    marker_outside = int(np.count_nonzero(marker_callback_residual & ~full_membership))
    residuals = enumerate_residuals(
        env, "direct_vs_closed_geometry", direct_residual, live_world,
        rasters, full_membership, boxes)
    residuals.extend(enumerate_residuals(
        env, "callback1_vs_direct", callback_direct_residual, live_world,
        rasters, full_membership, boxes))
    residuals.extend(enumerate_residuals(
        env, "marker1_vs_callback1", marker_callback_residual, live_world,
        rasters, full_membership, boxes))
    residuals.extend(enumerate_residuals(
        env, "direct_plus1_vs_closed_geometry", plus1_prediction_residual, live_world,
        rasters, full_membership, boxes))
    residuals.extend(enumerate_residuals(
        env, "callback_plus1_vs_direct_plus1", plus1_callback_residual, live_world,
        rasters, full_membership, boxes))
    residuals.extend(enumerate_residuals(
        env, "post_rebuild_plus1_vs_direct_plus1", post_rebuild_residual, live_world,
        rasters, full_membership, boxes))
    residuals.extend(enumerate_residuals(
        env, "post_rebuild_plus1_repeat_vs_direct_plus1",
        post_rebuild_repeat_residual, live_world, rasters, full_membership, boxes))
    checks = {
        "probe_dimensions_match_preserved_expanded_stamp": (gw, gh) == expected_dims,
        "original_all_closed_prediction_is_a_live_negative_control": full_prediction_diff > 0,
        "all_corresponding_sites_match_source_border_membership": mapped_membership_diff == 0,
        "original_corresponding_prediction_is_a_live_negative_control": mapped_direct_diff > 0,
        "direct_write_observable": direct_changes > 0,
        "bare_rebuild_restores_raster": np.array_equal(rasters["bare"], rasters["baseline"]),
        "marker_free_callback_phase_control": (
            bool(np.any(callback_direct_residual)) if env == "surface"
            else not np.any(callback_direct_residual)),
        "marker_free_callback_repeat_is_stable_raster": np.array_equal(
            rasters["callback2"], rasters["callback1"]),
        "callback_cleanup_restores_raster": np.array_equal(
            rasters["callback_cleanup"], rasters["baseline"]),
        "marker_repeat_is_stable_raster": np.array_equal(rasters["marker2"], rasters["marker1"]),
        "marker_cleanup_restores_raster": np.array_equal(
            rasters["marker_cleanup"], rasters["baseline"]),
        "max_plus_one_matches_closed_box_prediction": not np.any(plus1_prediction_residual),
        "max_plus_one_corresponding_sites_match_source_border_prediction":
            mapped_direct_plus1_diff == 0,
        "plus1_bare_rebuild_restores_raster": np.array_equal(
            rasters["plus1_bare"], rasters["baseline"]),
        "max_plus_one_callback_phase_control": (
            bool(np.any(plus1_callback_residual)) if env == "surface"
            else not np.any(plus1_callback_residual)),
        "max_plus_one_callback_repeat_is_stable_raster": np.array_equal(
            rasters["callback_plus1_repeat"], rasters["callback_plus1"]),
        "cleanup_restores_raster": np.array_equal(rasters["cleanup"], rasters["baseline"]),
        "bare_rebuild_restores_hash": hashes["bare"] == hashes["baseline"],
        "marker_free_callback_hash_phase_control": (
            (hashes["callback1"] != hashes["direct"])
            if env == "surface" else
            (hashes["callback1"] == hashes["direct"])),
        "marker_free_callback_repeat_is_stable_hash": hashes["callback2"] == hashes["callback1"],
        "callback_cleanup_restores_hash": hashes["callback_cleanup"] == hashes["baseline"],
        "marker_repeat_is_stable_hash": hashes["marker2"] == hashes["marker1"],
        "marker_cleanup_restores_hash": hashes["marker_cleanup"] == hashes["baseline"],
        "max_plus_one_write_is_hash_observable": hashes["direct_plus1"] != hashes["baseline"],
        "plus1_bare_rebuild_restores_hash": hashes["plus1_bare"] == hashes["baseline"],
        "max_plus_one_callback_hash_phase_control": (
            (hashes["callback_plus1"] != hashes["direct_plus1"])
            if env == "surface" else
            (hashes["callback_plus1"] == hashes["direct_plus1"])),
        "max_plus_one_callback_repeat_is_stable_hash": (
            hashes["callback_plus1_repeat"] == hashes["callback_plus1"]),
        "post_rebuild_replay_matches_direct_raster": not np.any(post_rebuild_residual),
        "post_rebuild_replay_matches_direct_hash": (
            hashes["post_rebuild_plus1"] == hashes["direct_plus1"]),
        "post_rebuild_replay_repeat_is_stable_raster": (
            not np.any(post_rebuild_repeat_residual)),
        "post_rebuild_replay_repeat_is_stable_hash": (
            hashes["post_rebuild_plus1_repeat"] == hashes["direct_plus1"]),
        "cleanup_restores_hash": hashes["cleanup"] == hashes["baseline"],
    }
    production_replay = None
    if production_stamp:
        production_stamp = dict(production_stamp)
        stamp_checks = {
            "version": int(production_stamp["version"]) == EXPECTED_REPLAY_VERSION,
            "stage_present": production_stamp["stage"] not in ("", "nil", "false", "?"),
            "apply_count_positive": int(production_stamp["apply_count"]) >= 1,
            "box_count": int(production_stamp["boxes"]) == len(boxes) == 162,
            "box_partition": (
                int(production_stamp["core_boxes"]) == 4
                and int(production_stamp["fringe_boxes"]) == 158
                and int(production_stamp["core_boxes"])
                + int(production_stamp["fringe_boxes"]) == len(boxes)
            ),
            "fringe_sites": int(production_stamp["fringe_sites"]) == 236,
            "orientation": production_stamp["orientation"] == "vertical",
            "mapped_sites": int(production_stamp["mapped_sites"]) == int(source_border.size),
            "border_sites": int(production_stamp["border_sites"]) == int(source_border.sum()),
        }
        production_residual = rasters["production"] != rasters["direct_plus1"]
        residuals.extend(enumerate_residuals(
            env, "production_vs_independent_plus1_control", production_residual,
            live_world, rasters, full_membership, boxes))
        production_replay = {
            "stamp": production_stamp,
            "stamp_checks": stamp_checks,
            "raster_differences_from_independent_plus1_control": int(
                np.count_nonzero(production_residual)),
            "hash_matches_independent_plus1_control": (
                hashes["production"] == hashes["direct_plus1"]),
            "passgrid_semantics": passgrid_semantics,
            "gate_ok": (
                all(stamp_checks.values())
                and not np.any(production_residual)
                and (passgrid_semantics is None or passgrid_semantics["gate_ok"])
                and hashes["production"] == hashes["direct_plus1"]
            ),
        }
        checks["production_replay_matches_independent_control"] = production_replay["gate_ok"]
    report = {
        "storage": {"gw": gw, "gh": gh, "cells": gw * gh},
        "boxes": len(boxes),
        "mapped_sites": int(source_border.size),
        "source_border_sites": int(source_border.sum()),
        "engine_lattice_box_sites": int(full_membership.sum()),
        "direct_changes": direct_changes,
        "full_prediction_differences": full_prediction_diff,
        "mapped_membership_differences": mapped_membership_diff,
        "mapped_direct_differences": mapped_direct_diff,
        "mapped_direct_plus1_differences": mapped_direct_plus1_diff,
        "direct_boundary_model": {
            "tested_edge_modes": len(edge_controls),
            "difference_counts": edge_controls,
            "exact_modes": exact_edge_modes,
            "unique_exact_mode": exact_edge_modes == [inferred_mode],
            "inferred_mode": inferred_mode,
            "inferred_prediction_differences": int(np.count_nonzero(
                rasters["direct"] != (rasters["baseline"] & ~inferred_membership))),
            "all_closed_prediction_differences": full_prediction_diff,
            "stock_inclusive_max_plus_one": {
                "source": "CommonLua/Classes/marker.lua:749-762",
                "candidate_membership_differences_from_intended_closed_union":
                    inclusive_candidate_differences,
                "model_gate_ok": inclusive_candidate_differences == 0,
            },
            "gate_ok": (
                exact_edge_modes == [inferred_mode]
                and inclusive_candidate_differences == 0
            ),
        },
        "marker_free_callback_residual": {
            "differences": int(np.count_nonzero(callback_direct_residual)),
        },
        "placed_marker_object_residual": {
            "differences": int(np.count_nonzero(marker_callback_residual)),
            "inside_closed_box_union": marker_inside,
            "outside_closed_box_union": marker_outside,
            "all_marker_changes_block": bool(np.all(
                ~rasters["marker1"][marker_callback_residual])),
            "isolated_from_callback_timing": not np.any(callback_direct_residual),
        },
        "max_plus_one_live_replay": {
            "direct_prediction_differences": int(np.count_nonzero(plus1_prediction_residual)),
            "callback_vs_direct_differences": int(np.count_nonzero(plus1_callback_residual)),
            "mapped_prediction_differences": mapped_direct_plus1_diff,
        },
        "rebuild_order_discriminator": {
            "stock_message": "OnPassabilityRebuilding (inside rebuild only)",
            "stock_source": "CommonLua/Classes/marker.lua:771-779",
            "post_rebuild_vs_direct_differences": int(
                np.count_nonzero(post_rebuild_residual)),
            "post_rebuild_repeat_vs_direct_differences": int(
                np.count_nonzero(post_rebuild_repeat_residual)),
            "gate_ok": not np.any(post_rebuild_residual)
            and not np.any(post_rebuild_repeat_residual),
        },
        "production_replay": production_replay,
        "residual_rows": len(residuals),
        "hashes": {stage: hashes[stage] for stage in stages},
        "checks": checks,
        "gate_ok": all(checks.values()),
    }
    return report, residuals


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--probe-base", type=Path, required=True)
    parser.add_argument("--box-report", type=Path, required=True)
    parser.add_argument("--vanilla", required=True)
    parser.add_argument("--expanded", required=True)
    parser.add_argument("--dump-dir", type=Path, default=DEFAULT_OUT_DIR)
    parser.add_argument("--out", type=Path, required=True)
    parser.add_argument("--residuals", type=Path)
    args = parser.parse_args()

    boxes, source_sha, engine_sha = load_engine_boxes(args.box_report)
    probe = parse_probe(Path(f"{args.probe_base}-probe.txt"))
    box_meta: dict[str, str] = probe["box_meta"]  # type: ignore[assignment]
    probe_boxes = [
        {key: int(row[key]) for key in ("minx", "miny", "maxx", "maxy")}
        for row in probe["boxes"]  # type: ignore[union-attr]
    ]
    vstamp = propertycheck.parse_probe_stamp(
        args.dump_dir / f"property-{args.vanilla}-property.txt")
    estamp = propertycheck.parse_probe_stamp(
        args.dump_dir / f"property-{args.expanded}-property.txt")
    maps = {}
    residuals = []
    for env in ("surface", "underground"):
        maps[env], env_residuals = score_map(
            env, probe, args.probe_base, vstamp, estamp, boxes)
        residuals.extend(env_residuals)
    binding_checks = {
        "source_box_sha_matches": box_meta["source_sha"] == source_sha,
        "engine_box_sha_matches": box_meta["engine_sha"] == engine_sha,
        "probe_box_count_matches": int(box_meta["count"]) == len(boxes) == len(probe_boxes),
        "probe_boxes_match_quantized_report": probe_boxes == boxes,
        "offline_report_gate_ok": bool(json.loads(
            args.box_report.read_text(encoding="utf-8"))["gate_ok"]),
    }
    report = {
        "schema": "smr.perimeterfullcheck.v5",
        "inputs": {
            "probe_base": str(args.probe_base),
            "box_report": str(args.box_report),
            "vanilla": args.vanilla,
            "expanded": args.expanded,
        },
        "box_binding": {
            "count": len(boxes),
            "source_sha256": source_sha,
            "engine_sha256": engine_sha,
            "checks": binding_checks,
        },
        "maps": maps,
        "checks": {
            "box_binding": all(binding_checks.values()),
            "direct_boundary_models": all(
                maps[env]["direct_boundary_model"]["gate_ok"]
                for env in ("surface", "underground")),
            "residuals_fully_enumerated": len(residuals) == sum(
                maps[env]["residual_rows"] for env in ("surface", "underground")),
            "placed_markers_add_nothing_beyond_callback": (
                maps["surface"]["placed_marker_object_residual"]["differences"] == 0
                and maps["underground"]["placed_marker_object_residual"]["differences"] == 0
            ),
            "surface_callback_phase_is_a_negative_control": (
                maps["surface"]["max_plus_one_live_replay"]
                    ["callback_vs_direct_differences"] > 0
            ),
            "post_rebuild_direct_replay_is_exact": all(
                maps[env]["rebuild_order_discriminator"]["gate_ok"]
                for env in ("surface", "underground")
            ),
            "surface_gate": maps["surface"]["gate_ok"],
            "underground_gate": maps["underground"]["gate_ok"],
        },
    }
    report["gate_ok"] = all(report["checks"].values())
    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    if args.residuals:
        args.residuals.parent.mkdir(parents=True, exist_ok=True)
        with args.residuals.open("w", encoding="utf-8", newline="") as stream:
            writer = csv.DictWriter(stream, fieldnames=RESIDUAL_FIELDS)
            writer.writeheader()
            writer.writerows(residuals)
    print(json.dumps(report, indent=2))
    return 0 if report["gate_ok"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
