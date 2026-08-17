#!/usr/bin/env python3
"""Score a full live replay of perimetercheck.py's compact stock-box union."""

from __future__ import annotations

import argparse
import hashlib
import json
import math
from pathlib import Path

import numpy as np

import perimetercheck
import propertycheck


HERE = Path(__file__).resolve().parent
DEFAULT_OUT_DIR = HERE / "out"
STAGES = ("baseline", "direct", "bare", "marker1", "marker2", "cleanup")


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
    result: dict[str, object] = {"maps": {}, "calibrations": [], "boxes": []}
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
        elif parts[0] == "hash":
            row = kv(parts[1:])
            maps.setdefault(row["env"], {})["hashes"] = row
    return result


def load_raw(base: Path, env: str, stage: str, gw: int, gh: int) -> np.ndarray:
    path = Path(f"{base}-{env}-{stage}.raw")
    data = np.fromfile(path, dtype=np.uint8)
    if data.size != gw * gh:
        raise RuntimeError(f"{path}: expected {gw * gh} bytes, got {data.size}")
    if bool(np.any(data > 1)):
        raise RuntimeError(f"{path}: non-binary passability value")
    return data.reshape((gh, gw)).astype(bool)


def score_map(
    env: str,
    probe: dict[str, object],
    probe_base: Path,
    vstamp: propertycheck.ProbeStamp,
    estamp: propertycheck.ProbeStamp,
    boxes: list[dict[str, int]],
) -> dict[str, object]:
    maps: dict[str, dict[str, object]] = probe["maps"]  # type: ignore[assignment]
    live = maps[env]
    meta: dict[str, str] = live["map"]  # type: ignore[assignment]
    hashes: dict[str, str] = live["hashes"]  # type: ignore[assignment]
    gw, gh = int(meta["gw"]), int(meta["gh"])
    expected_dims = propertycheck.dims(estamp, env)
    geometry = propertycheck.geometry_for(estamp, env)
    rasters = {stage: load_raw(probe_base, env, stage, gw, gh) for stage in STAGES}

    sy, sx = np.indices((gh, gw), dtype=np.float64)
    live_world = propertycheck.storage_to_world(geometry, sx.ravel(), sy.ravel())
    full_membership = perimetercheck.box_membership(live_world, boxes).reshape((gh, gw))
    predicted_direct = rasters["baseline"] & ~full_membership

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
    expected_mapped_direct = baseline_mapped & ~source_border

    full_prediction_diff = int(np.count_nonzero(rasters["direct"] != predicted_direct))
    mapped_membership_diff = int(np.count_nonzero(mapped_membership != source_border))
    mapped_direct_diff = int(np.count_nonzero(direct_mapped != expected_mapped_direct))
    direct_changes = int(np.count_nonzero(rasters["direct"] != rasters["baseline"]))
    checks = {
        "probe_dimensions_match_preserved_expanded_stamp": (gw, gh) == expected_dims,
        "all_engine_lattice_cells_match_closed_box_prediction": full_prediction_diff == 0,
        "all_corresponding_sites_match_source_border_membership": mapped_membership_diff == 0,
        "all_corresponding_live_verdicts_match_source_border_prediction": mapped_direct_diff == 0,
        "direct_write_observable": direct_changes > 0,
        "bare_rebuild_restores_raster": np.array_equal(rasters["bare"], rasters["baseline"]),
        "marker_rebuild_matches_direct_raster": np.array_equal(rasters["marker1"], rasters["direct"]),
        "marker_repeat_is_stable_raster": np.array_equal(rasters["marker2"], rasters["marker1"]),
        "cleanup_restores_raster": np.array_equal(rasters["cleanup"], rasters["baseline"]),
        "bare_rebuild_restores_hash": hashes["bare"] == hashes["baseline"],
        "marker_rebuild_matches_direct_hash": hashes["marker1"] == hashes["direct"],
        "marker_repeat_is_stable_hash": hashes["marker2"] == hashes["marker1"],
        "cleanup_restores_hash": hashes["cleanup"] == hashes["baseline"],
    }
    return {
        "storage": {"gw": gw, "gh": gh, "cells": gw * gh},
        "boxes": len(boxes),
        "mapped_sites": int(source_border.size),
        "source_border_sites": int(source_border.sum()),
        "engine_lattice_box_sites": int(full_membership.sum()),
        "direct_changes": direct_changes,
        "full_prediction_differences": full_prediction_diff,
        "mapped_membership_differences": mapped_membership_diff,
        "mapped_direct_differences": mapped_direct_diff,
        "hashes": {stage: hashes[stage] for stage in STAGES},
        "checks": checks,
        "gate_ok": all(checks.values()),
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--probe-base", type=Path, required=True)
    parser.add_argument("--box-report", type=Path, required=True)
    parser.add_argument("--vanilla", required=True)
    parser.add_argument("--expanded", required=True)
    parser.add_argument("--dump-dir", type=Path, default=DEFAULT_OUT_DIR)
    parser.add_argument("--out", type=Path, required=True)
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
    maps = {
        env: score_map(env, probe, args.probe_base, vstamp, estamp, boxes)
        for env in ("surface", "underground")
    }
    binding_checks = {
        "source_box_sha_matches": box_meta["source_sha"] == source_sha,
        "engine_box_sha_matches": box_meta["engine_sha"] == engine_sha,
        "probe_box_count_matches": int(box_meta["count"]) == len(boxes) == len(probe_boxes),
        "probe_boxes_match_quantized_report": probe_boxes == boxes,
        "offline_report_gate_ok": bool(json.loads(
            args.box_report.read_text(encoding="utf-8"))["gate_ok"]),
    }
    report = {
        "schema": "smr.perimeterfullcheck.v1",
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
            "surface_gate": maps["surface"]["gate_ok"],
            "underground_gate": maps["underground"]["gate_ok"],
        },
    }
    report["gate_ok"] = all(report["checks"].values())
    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(report, indent=2))
    return 0 if report["gate_ok"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
