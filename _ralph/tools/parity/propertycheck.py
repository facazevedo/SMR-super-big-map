"""Score the floor sweep's exhaustive passability/buildability ruling.

``property_probe.lua`` writes dense shipped/fresh/repeat property rasters for both
twins, plus a self-restoring bank of one-height-node sensitivity controls.  This scorer:

* rebuilds the expanded twin's exact massif components from its pre-transform
  height grid and stamp;
* narrows that set to height nodes whose actual post-transform value differs from
  the clipped affine image (the exact spatial-normalisation set);
* requires a multi-phase bank of live sensitivity controls to cross-replay exactly,
  then derives separate passability and buildability reverse footprints and applies
  them to every normalised height node;
* maps every vanilla property-storage site to one unique expanded site by the
  probes' own ``HexToWorld`` calibration and the measured height-grid ratio;
* requires zero shipped-verdict differences outside the footprint-aware set; and
* requires shipped == fresh on every affected verdict, plus fresh == repeat (and
  restored == fresh where present), so the exception was freshly and idempotently
  judged by the stock rules without rejecting unrelated stock staleness elsewhere.

Every cross-twin difference is written to CSV.  There is no tolerance or allowlist.
The scorer intentionally requires exact pre/post stretch dumps; a bbox-only massif
stamp cannot satisfy the current ruling.

Typical use::

  python propertycheck.py --vanilla vanilla_tag --expanded expanded_tag \
    --out artifacts/property_case.json --differences artifacts/property_case.csv

Run ``--self-test`` before live use.  It injects one outside-mask pass difference,
one outside-mask build difference, and one stale in-mask verdict and requires the
same production comparison helpers to reject all three.
"""

from __future__ import annotations

import argparse
import csv
import json
import math
import sys
from dataclasses import dataclass
from pathlib import Path

import numpy as np
from scipy import ndimage

import zonecheck


HERE = Path(__file__).resolve().parent
DEFAULT_OUT_DIR = HERE / "out"
CAP = 65535


def fail(message: str) -> "NoReturn":
    raise SystemExit(message)


def parse_fields(parts: list[str]) -> dict[str, str]:
    return dict(part.split("=", 1) for part in parts if "=" in part)


@dataclass
class ProbeStamp:
    maps: dict[str, dict[str, str]]
    calibration: dict[str, dict[tuple[int, int], tuple[float, float]]]
    freshness: dict[str, dict[str, str]]
    controls: list[dict[str, str]]


@dataclass
class HexGeometry:
    """Measured parity-aware conversion between property storage and world space."""

    origin: np.ndarray
    axis_x: np.ndarray
    row_axis: np.ndarray
    inverse: np.ndarray
    calibration_max_error: float


def parse_probe_stamp(path: Path) -> ProbeStamp:
    maps: dict[str, dict[str, str]] = {}
    calibration: dict[str, dict[tuple[int, int], tuple[float, float]]] = {}
    freshness: dict[str, dict[str, str]] = {}
    controls: list[dict[str, str]] = []
    for raw in path.read_text(encoding="utf-8").splitlines():
        parts = raw.strip().split(",")
        if len(parts) < 2:
            continue
        kind, env = parts[0], parts[1]
        fields = parse_fields(parts[2:])
        if kind == "map":
            maps[env] = fields
        elif kind == "calibration":
            sx, sy = int(fields["sx"]), int(fields["sy"])
            calibration.setdefault(env, {})[(sx, sy)] = (
                float(fields["wx"]), float(fields["wy"]))
        elif kind == "freshness":
            freshness[env] = fields
        elif kind == "control":
            controls.append(fields)
    missing = {"surface", "underground"} - maps.keys()
    if missing:
        fail(f"{path}: missing map rows for {sorted(missing)}")
    for env in ("surface", "underground"):
        need = {(0, 0), (1, 0), (0, 1), (1, 1), (0, 2), (1, 2)}
        if need - calibration.get(env, {}).keys():
            fail(f"{path}: incomplete parity-aware {env} HexToWorld calibration")
    return ProbeStamp(maps, calibration, freshness, controls)


def load_property(path: Path, gw: int, gh: int) -> np.ndarray:
    raw = np.fromfile(path, dtype=np.uint8)
    if raw.size != gw * gh:
        fail(f"{path}: {raw.size} bytes, expected {gw}x{gh}={gw * gh}")
    if raw.size and int(raw.max()) > 3:
        fail(f"{path}: property byte outside bit mask 0..3")
    return raw.reshape((gh, gw))


def storage_to_world(geometry: HexGeometry, sx: np.ndarray, sy: np.ndarray) -> np.ndarray:
    """Apply the engine's alternating-row storage convention without an affine shortcut."""
    sx = np.asarray(sx, dtype=np.float64)
    sy = np.asarray(sy, dtype=np.float64)
    parity = np.remainder(sy.astype(np.int64), 2).astype(np.float64)
    return np.stack((
        geometry.origin[0] + geometry.axis_x[0] * sx + geometry.row_axis[0] * sy
        + geometry.axis_x[0] * parity / 2.0,
        geometry.origin[1] + geometry.axis_x[1] * sx + geometry.row_axis[1] * sy
        + geometry.axis_x[1] * parity / 2.0,
    ), axis=0)


def geometry_for(stamp: ProbeStamp, env: str) -> HexGeometry:
    cal = stamp.calibration[env]
    origin = np.asarray(cal[(0, 0)], dtype=np.float64)
    axis_x = np.asarray(cal[(1, 0)], dtype=np.float64) - origin
    row_axis = (np.asarray(cal[(0, 2)], dtype=np.float64) - origin) / 2.0
    matrix = np.column_stack((axis_x, row_axis))
    if abs(float(np.linalg.det(matrix))) < 1e-9:
        fail(f"{env}: singular HexToWorld calibration")
    geometry = HexGeometry(origin, axis_x, row_axis, np.linalg.inv(matrix), 0.0)
    errors = []
    for (sx, sy), measured in cal.items():
        predicted = storage_to_world(geometry, np.asarray(sx), np.asarray(sy))
        errors.append(float(np.linalg.norm(predicted - np.asarray(measured, dtype=np.float64))))
    geometry.calibration_max_error = max(errors, default=0.0)
    if geometry.calibration_max_error > 1e-9:
        fail(f"{env}: HexToWorld calibration does not fit alternating-row storage "
             f"(max error {geometry.calibration_max_error})")
    return geometry


def world_to_storage(geometry: HexGeometry, world: np.ndarray) -> tuple[np.ndarray, np.ndarray]:
    """Nearest storage row/column, applying the selected row's measured parity offset."""
    world = np.asarray(world, dtype=np.float64)
    if world.ndim == 1:
        world = world[:, None]
    continuous = geometry.inverse @ (world - geometry.origin[:, None])
    sy_float = continuous[1]
    sy = round_storage(sy_float)
    parity_offset = geometry.axis_x[:, None] * (np.remainder(sy, 2)[None, :] / 2.0)
    deparitied = geometry.inverse @ (world - geometry.origin[:, None] - parity_offset)
    sx_float = deparitied[0]
    sx = round_storage(sx_float)
    return np.vstack((sx, sy)), np.vstack((sx_float, sy_float))


def dims(stamp: ProbeStamp, env: str) -> tuple[int, int]:
    row = stamp.maps[env]
    return int(row["gw"]), int(row["gh"])


def round_storage(values: np.ndarray) -> np.ndarray:
    """Nearest storage integer; calibration coordinates in this task are non-negative."""
    return np.floor(values + 0.5).astype(np.int64)


def map_sites(van: ProbeStamp, exp: ProbeStamp, env: str) -> dict[str, np.ndarray | float | int]:
    vgw, vgh = dims(van, env)
    egw, egh = dims(exp, env)
    vrow, erow = van.maps[env], exp.maps[env]
    vh, eh = int(vrow["height_gw"]), int(erow["height_gw"])
    if vh <= 0 or eh <= vh:
        fail(f"{env}: expected expanded height grid larger than vanilla ({vh}, {eh})")
    scale = eh / vh
    vgeometry = geometry_for(van, env)
    egeometry = geometry_for(exp, env)

    sy, sx = np.indices((vgh, vgw), dtype=np.float64)
    world = storage_to_world(vgeometry, sx.ravel(), sy.ravel())
    target, target_float = world_to_storage(egeometry, world * scale)
    ex = target[0].reshape((vgh, vgw))
    ey = target[1].reshape((vgh, vgw))
    in_bounds = (ex >= 0) & (ex < egw) & (ey >= 0) & (ey < egh)
    if not bool(in_bounds.all()):
        bad = int((~in_bounds).sum())
        fail(f"{env}: {bad} geometrically corresponding sites fall outside expanded storage")
    linear = ey * egw + ex
    unique = int(np.unique(linear).size)
    if unique != vgw * vgh:
        fail(f"{env}: mapping is not one-to-one ({unique}/{vgw * vgh} unique)")

    rounded_world = storage_to_world(egeometry, target[0], target[1])
    residual = np.linalg.norm(rounded_world - world * scale, axis=0)
    return {
        "ex": ex,
        "ey": ey,
        "scale": scale,
        "sites": vgw * vgh,
        "expanded_unmapped": egw * egh - unique,
        "geometry": "alternating_row_parity",
        "vanilla_calibration_max_error": vgeometry.calibration_max_error,
        "expanded_calibration_max_error": egeometry.calibration_max_error,
        "max_world_rounding_residual": float(residual.max(initial=0.0)),
        "p99_world_rounding_residual": float(np.percentile(residual, 99)) if residual.size else 0.0,
    }


def parse_control_csv(path: Path) -> list[dict[str, int]]:
    rows: list[dict[str, int]] = []
    with path.open("r", encoding="utf-8", newline="") as fh:
        for row in csv.DictReader(fh):
            rows.append({key: int(value) for key, value in row.items()})
    return rows


def replay_cells(geometry: HexGeometry, source: dict[str, object],
                 target: dict[str, object], property_name: str) -> set[tuple[int, int]]:
    key = "pass_rows" if property_name == "passability" else "build_rows"
    source_node = np.asarray(source["node_world"], dtype=np.float64)
    target_node = np.asarray(target["node_world"], dtype=np.float64)
    rows = source[key]
    if not rows:
        return set()
    storage = np.asarray([[row["sx"], row["sy"]] for row in rows], dtype=np.int64)
    observed_world = storage_to_world(geometry, storage[:, 0], storage[:, 1]).T
    offsets = observed_world - source_node[None, :]
    replay, _ = world_to_storage(geometry, target_node[:, None] + offsets.T)
    return set(zip(replay[0].tolist(), replay[1].tolist()))


def validate_probe_controls(out_dir: Path, tag: str, stamp: ProbeStamp,
                            grids: dict[str, np.ndarray]) -> dict[str, object]:
    if len(stamp.controls) < 4:
        fail(f"property-{tag}-property.txt: fewer than four phase controls")
    required = {"site_sx", "site_sy", "site_wx", "site_wy", "node_gx", "node_gy",
                "node_wx", "node_wy", "diff", "pass_diff", "build_diff", "restore_diff", "id"}
    geometry = geometry_for(stamp, "surface")
    tile = float(stamp.maps["surface"]["tile"])
    fresh = grids["surface:fresh"]
    controls: list[dict[str, object]] = []
    ids: set[str] = set()
    for meta in stamp.controls:
        if required - meta.keys():
            fail(f"property-{tag}-property.txt: missing phase-control fields")
        control_id = meta["id"]
        if control_id in ids:
            fail(f"property-{tag}-property.txt: duplicate phase-control id {control_id}")
        ids.add(control_id)
        rows = parse_control_csv(
            out_dir / f"property-{tag}-surface-property-control-{control_id}.csv")
        control = grids[f"surface:control-{control_id}"]
        raw_diff = fresh != control
        csv_cells = {(row["sx"], row["sy"]) for row in rows}
        raw_y, raw_x = np.nonzero(raw_diff)
        raw_cells = set(zip(raw_x.tolist(), raw_y.tolist()))
        pass_rows = [row for row in rows if (row["fresh_bits"] ^ row["control_bits"]) & 1]
        build_rows = [row for row in rows if (row["fresh_bits"] ^ row["control_bits"]) & 2]
        measured_site = np.asarray([float(meta["site_wx"]), float(meta["site_wy"])])
        modelled_site = storage_to_world(
            geometry, np.asarray(int(meta["site_sx"])), np.asarray(int(meta["site_sy"])))
        measured_node = np.asarray([float(meta["node_wx"]), float(meta["node_wy"])])
        modelled_node = np.asarray([int(meta["node_gx"]) * tile, int(meta["node_gy"]) * tile])
        checks = {
            "csv_is_complete": csv_cells == raw_cells,
            "diff_matches_stamp": len(rows) == int(meta["diff"]),
            "pass_diff_matches_stamp": len(pass_rows) == int(meta["pass_diff"]),
            "build_diff_matches_stamp": len(build_rows) == int(meta["build_diff"]),
            "both_properties_moved": bool(pass_rows) and bool(build_rows),
            "restore_diff_zero": int(meta["restore_diff"]) == 0,
            "site_storage_world_exact": bool(np.allclose(
                modelled_site, measured_site, rtol=0, atol=1e-9)),
            "node_storage_world_exact": bool(np.allclose(
                modelled_node, measured_node, rtol=0, atol=1e-9)),
        }
        controls.append({
            "id": control_id,
            "checks": checks,
            "ok": all(checks.values()),
            "rows": rows,
            "pass_rows": pass_rows,
            "build_rows": build_rows,
            "node_world": measured_node.tolist(),
            "site_row_parity": int(meta["site_sy"]) % 2,
            "counts": {"all": len(rows), "passability": len(pass_rows),
                       "buildability": len(build_rows)},
        })

    cross_checks: list[dict[str, object]] = []
    for source in controls:
        for target in controls:
            row = {"source": source["id"], "target": target["id"]}
            for property_name in ("passability", "buildability"):
                predicted = replay_cells(geometry, source, target, property_name)
                key = "pass_rows" if property_name == "passability" else "build_rows"
                observed = {(item["sx"], item["sy"]) for item in target[key]}
                row[property_name] = predicted == observed
            row["ok"] = bool(row["passability"] and row["buildability"])
            cross_checks.append(row)
    parities = {int(control["site_row_parity"]) for control in controls}
    all_cross_exact = all(bool(row["ok"]) for row in cross_checks)
    checks = {
        "all_controls_valid": all(bool(control["ok"]) for control in controls),
        "both_row_parities_present": parities == {0, 1},
        "all_phase_kernels_cross_replay_exact": all_cross_exact,
    }
    anchor = controls[0]
    return {
        "checks": checks,
        "ok": all(checks.values()),
        "controls": controls,
        "cross_checks": cross_checks,
        "anchor": anchor,
        "phase_count": len(controls),
        "cross_replays": len(cross_checks),
    }


def compact_controls(control: dict[str, object]) -> dict[str, object]:
    compact = {key: value for key, value in control.items()
               if key not in {"controls", "anchor"}}
    compact["controls"] = [
        {key: value for key, value in item.items()
         if key not in {"rows", "pass_rows", "build_rows"}}
        for item in control["controls"]  # type: ignore[index,union-attr]
    ]
    return compact


def load_probe_grids(out_dir: Path, tag: str, stamp: ProbeStamp) -> dict[str, np.ndarray]:
    grids: dict[str, np.ndarray] = {}
    for env in ("surface", "underground"):
        gw, gh = dims(stamp, env)
        for stage in ("shipped", "fresh", "repeat"):
            path = out_dir / f"property-{tag}-{env}-property-{stage}.raw"
            grids[f"{env}:{stage}"] = load_property(path, gw, gh)
        if env == "surface":
            for meta in stamp.controls:
                stage = f"control-{meta['id']}"
                path = out_dir / f"property-{tag}-{env}-property-{stage}.raw"
                grids[f"{env}:{stage}"] = load_property(path, gw, gh)
            stage = "restored"
            path = out_dir / f"property-{tag}-{env}-property-{stage}.raw"
            grids[f"{env}:{stage}"] = load_property(path, gw, gh)
    return grids


def freshness_report(grids: dict[str, np.ndarray]) -> dict[str, dict[str, int | bool]]:
    report: dict[str, dict[str, int | bool]] = {}
    for env in ("surface", "underground"):
        fresh = grids[f"{env}:fresh"]
        shipped = int((grids[f"{env}:shipped"] != fresh).sum())
        repeat = int((grids[f"{env}:repeat"] != fresh).sum())
        restored = int((grids[f"{env}:restored"] != fresh).sum()) if env == "surface" else 0
        report[env] = {
            "shipped_vs_fresh": shipped,
            "repeat_vs_fresh": repeat,
            "restored_vs_fresh": restored,
            "stable": repeat == 0 and restored == 0,
        }
    return report


def exact_normalised_nodes(pre_path: Path, post_path: Path, stamp_path: Path) -> tuple[np.ndarray, dict]:
    pre = zonecheck.load(str(pre_path), 0).astype(np.int64)
    post = zonecheck.load(str(post_path), pre.shape[1]).astype(np.int64)
    maps, massifs = zonecheck.parse_stamp(str(stamp_path))
    surf = maps.get("surface")
    if surf is None:
        fail(f"{stamp_path}: missing surface stamp")
    mul, div, add = int(surf["zmul"]), int(surf["zdiv"]), int(surf["zadd"])
    structure = ndimage.generate_binary_structure(2, 1)
    components = np.zeros(pre.shape, dtype=bool)
    overlaps = np.zeros(pre.shape, dtype=bool)
    rebuilt: list[dict[str, int | bool]] = []
    for massif in (m for m in massifs if m["tag"] == "surface"):
        x0, y0, x1, y1 = (massif[key] for key in ("x0", "y0", "x1", "y1"))
        sub = pre[y0:y1, x0:x1]
        labels, _ = ndimage.label(sub >= massif["base"], structure=structure)
        wanted = labels[massif["peak_y"] - y0, massif["peak_x"] - x0]
        mask = labels == wanted if wanted else np.zeros(sub.shape, dtype=bool)
        prior = components[y0:y1, x0:x1]
        overlaps[y0:y1, x0:x1] |= prior & mask
        prior |= mask
        area = int(mask.sum())
        rebuilt.append({
            "index": massif["index"],
            "stamped_cells": massif["cells"],
            "rebuilt_cells": area,
            "cells_match": area == massif["cells"],
        })
    affine = np.clip(pre * mul // div + add, 0, CAP)
    normalised = components & (post != affine)
    outside_post_diff = int(((post != affine) & ~components).sum())
    summary = {
        "shape": list(pre.shape),
        "massifs": len(rebuilt),
        "component_cells": int(components.sum()),
        "normalised_height_nodes": int(normalised.sum()),
        "affine_equal_nodes_inside_components": int((components & (post == affine)).sum()),
        "overlap_nodes": int(overlaps.sum()),
        "outside_component_post_vs_affine": outside_post_diff,
        "component_counts_match": all(row["cells_match"] for row in rebuilt),
        "detail": rebuilt,
    }
    summary["ok"] = bool(summary["component_counts_match"] and not summary["overlap_nodes"]
                         and not outside_post_diff)
    return normalised, summary


def footprint_mask(nodes: np.ndarray, stamp: ProbeStamp, env: str,
                   control: dict[str, object], property_name: str) -> tuple[np.ndarray, dict]:
    gw, gh = dims(stamp, env)
    geometry = geometry_for(stamp, env)
    node_world = np.asarray(control["node_world"], dtype=np.float64)
    key = "pass_rows" if property_name == "passability" else "build_rows"
    rows = control[key]
    observed_storage = np.asarray([[row["sx"], row["sy"]] for row in rows], dtype=np.int64)
    observed_world = storage_to_world(geometry, observed_storage[:, 0], observed_storage[:, 1]).T
    world_offsets = observed_world - node_world[None, :]
    affected = np.zeros((gh, gw), dtype=bool)
    ny, nx = np.nonzero(nodes)
    chunk = 250_000
    tile = float(stamp.maps[env]["tile"])
    for start in range(0, nx.size, chunk):
        stop = min(start + chunk, nx.size)
        world = np.vstack((nx[start:stop] * tile, ny[start:stop] * tile)).astype(np.float64)
        for offset in world_offsets:
            cell, _ = world_to_storage(geometry, world + offset[:, None])
            sx, sy = cell[0], cell[1]
            valid = (sx >= 0) & (sx < gw) & (sy >= 0) & (sy < gh)
            affected[sy[valid], sx[valid]] = True

    # Reapplying the derived footprint to the control node must reproduce every observed
    # changed property cell, exactly.  This is the live footprint anti-vacuity check.
    replay, _ = world_to_storage(geometry, node_world[:, None] + world_offsets.T)
    replay_cells = set(zip(replay[0].tolist(), replay[1].tolist()))
    observed = {(row["sx"], row["sy"]) for row in rows}
    detail = {
        "kernel_cells": len(rows),
        "geometry": "world_delta_over_alternating_row_parity",
        "calibration_max_error": geometry.calibration_max_error,
        "control_replay_exact": replay_cells == observed,
        "affected_cells": int(affected.sum()),
        "height_nodes": int(nodes.sum()),
    }
    detail["ok"] = bool(rows and detail["control_replay_exact"])
    return affected, detail


def compare_bits(van_bits: np.ndarray, exp_bits: np.ndarray, ex: np.ndarray, ey: np.ndarray,
                 affected: np.ndarray, bit: int) -> tuple[dict[str, int | bool], np.ndarray]:
    vanilla = (van_bits & bit) != 0
    expanded = (exp_bits[ey, ex] & bit) != 0
    scope = affected[ey, ex]
    different = vanilla != expanded
    outside = different & ~scope
    inside = different & scope
    report = {
        "corresponding_sites": int(different.size),
        "affected_sites": int(scope.sum()),
        "outside_sites": int((~scope).sum()),
        "differences_total": int(different.sum()),
        "differences_outside": int(outside.sum()),
        "differences_inside": int(inside.sum()),
        "outside_false_to_true": int((~vanilla & expanded & ~scope).sum()),
        "outside_true_to_false": int((vanilla & ~expanded & ~scope).sum()),
        "outside_zero": int(outside.sum()) == 0,
    }
    return report, different


def affected_staleness(van_shipped: np.ndarray, van_fresh: np.ndarray,
                       exp_shipped: np.ndarray, exp_fresh: np.ndarray,
                       ex: np.ndarray, ey: np.ndarray, affected: np.ndarray,
                       bit: int) -> dict[str, int | bool]:
    source_scope = affected[ey, ex]
    van_changed = ((van_shipped ^ van_fresh) & bit) != 0
    exp_changed = ((exp_shipped ^ exp_fresh) & bit) != 0
    van_stale = int((van_changed & source_scope).sum())
    exp_stale = int((exp_changed & affected).sum())
    return {
        "vanilla_affected_sites": int(source_scope.sum()),
        "expanded_affected_sites": int(affected.sum()),
        "vanilla_shipped_vs_fresh_inside": van_stale,
        "expanded_shipped_vs_fresh_inside": exp_stale,
        "inside_fresh": van_stale == 0 and exp_stale == 0,
    }


def synthetic_controls() -> dict[str, object]:
    shape = (6, 7)
    ex, ey = np.indices(shape, dtype=np.int64)[1], np.indices(shape, dtype=np.int64)[0]
    baseline = np.full(shape, 3, dtype=np.uint8)
    pass_mask = np.zeros(shape, dtype=bool)
    build_mask = np.zeros(shape, dtype=bool)
    pass_mask[2, 2] = True
    build_mask[3, 3] = True

    green_exp = baseline.copy()
    green_exp[2, 2] ^= 1
    green_exp[3, 3] ^= 2
    p_green, _ = compare_bits(baseline, green_exp, ex, ey, pass_mask, 1)
    b_green, _ = compare_bits(baseline, green_exp, ex, ey, build_mask, 2)

    bad_pass = green_exp.copy()
    bad_pass[0, 0] ^= 1
    p_bad, _ = compare_bits(baseline, bad_pass, ex, ey, pass_mask, 1)
    bad_build = green_exp.copy()
    bad_build[5, 6] ^= 2
    b_bad, _ = compare_bits(baseline, bad_build, ex, ey, build_mask, 2)

    stale = baseline.copy()
    stale[2, 2] ^= 1
    stale_report = affected_staleness(stale, baseline, baseline, baseline,
                                      ex, ey, pass_mask, 1)
    geometry_calibration = {
        (0, 0): (0.0, 0.0), (1, 0): (1000.0, 0.0),
        (0, 1): (500.0, 866.0), (1, 1): (1500.0, 866.0),
        (0, 2): (0.0, 1732.0), (1, 2): (1000.0, 1732.0),
    }
    vmaps = {env: {"gw": "15", "gh": "18", "height_gw": "150", "height_gh": "150",
                    "tile": "100"} for env in ("surface", "underground")}
    emaps = {env: {"gw": "20", "gh": "24", "height_gw": "200", "height_gh": "200",
                    "tile": "100"} for env in ("surface", "underground")}
    calibrations = {env: geometry_calibration for env in ("surface", "underground")}
    vstamp = ProbeStamp(vmaps, calibrations, {}, [])
    estamp = ProbeStamp(emaps, calibrations, {}, [])
    geometry = geometry_for(vstamp, "surface")
    test_sx = np.asarray([0, 1, 0, 1, 7, 7], dtype=np.int64)
    test_sy = np.asarray([0, 0, 1, 2, 9, 10], dtype=np.int64)
    test_world = storage_to_world(geometry, test_sx, test_sy)
    roundtrip, _ = world_to_storage(geometry, test_world)
    mapping = map_sites(vstamp, estamp, "surface")
    mapped_x = mapping["ex"]
    mapped_y = mapping["ey"]
    assert isinstance(mapped_x, np.ndarray) and isinstance(mapped_y, np.ndarray)
    src_y, src_x = np.indices((18, 15), dtype=np.float64)
    old_affine_x = round_storage(src_x * (4.0 / 3.0))
    parity_discriminator = int((old_affine_x != mapped_x).sum())
    phase_source = {
        "node_world": storage_to_world(
            geometry, np.asarray(5), np.asarray(4)).tolist(),
        "pass_rows": [{"sx": 5, "sy": 4}],
        "build_rows": [{"sx": 5, "sy": 4}],
    }
    phase_target = {
        "node_world": storage_to_world(
            geometry, np.asarray(6), np.asarray(5)).tolist(),
        "pass_rows": [{"sx": 6, "sy": 5}],
        "build_rows": [{"sx": 6, "sy": 5}],
    }
    phase_replay = replay_cells(geometry, phase_source, phase_target, "passability")

    checks = {
        "inside_differences_are_classified_inside": (
            p_green["differences_inside"] == 1 and p_green["differences_outside"] == 0
            and b_green["differences_inside"] == 1 and b_green["differences_outside"] == 0),
        "outside_pass_injection_rejected": p_bad["differences_outside"] == 1,
        "outside_build_injection_rejected": b_bad["differences_outside"] == 1,
        "stale_in_mask_injection_rejected": (
            stale_report["vanilla_shipped_vs_fresh_inside"] == 1
            and not stale_report["inside_fresh"]),
        "parity_geometry_roundtrips": bool(np.array_equal(
            roundtrip, np.vstack((test_sx, test_sy)))),
        "row_two_rejects_global_affine_model": parity_discriminator > 0,
        "odd_row_twin_mapping_is_parity_aware": (
            int(mapped_x[1, 1]) == 2 and int(mapped_y[1, 1]) == 1),
        "even_row_twin_mapping_is_parity_aware": (
            int(mapped_x[2, 2]) == 2 and int(mapped_y[2, 2]) == 3),
        "phase_kernel_cross_replays_across_row_parity": phase_replay == {(6, 5)},
        "phase_kernel_mismatch_is_rejected": phase_replay != {(7, 5)},
    }
    return {"ok": all(checks.values()), "checks": checks,
            "geometry_control": {
                "calibration_max_error": geometry.calibration_max_error,
                "roundtrip_sites": int(test_sx.size),
                "global_affine_disagreements": parity_discriminator,
                "mapping_sites": int(mapping["sites"]),
            },
            "injected_counts": {"outside_pass": p_bad["differences_outside"],
                                "outside_build": b_bad["differences_outside"],
                                "stale": stale_report["vanilla_shipped_vs_fresh_inside"]}}


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--vanilla", default="")
    ap.add_argument("--expanded", default="")
    ap.add_argument("--probe-tag", default="")
    ap.add_argument("--out-dir", type=Path, default=DEFAULT_OUT_DIR)
    ap.add_argument("--pre", type=Path, default=None)
    ap.add_argument("--post", type=Path, default=None)
    ap.add_argument("--stamp", type=Path, default=None)
    ap.add_argument("--out", type=Path, default=None)
    ap.add_argument("--differences", type=Path, default=None)
    ap.add_argument("--self-test", action="store_true")
    args = ap.parse_args(argv)

    self_test = synthetic_controls()
    if args.self_test:
        payload = {"schema": "smr.propertycheck.selftest.v3", **self_test}
        rendered = json.dumps(payload, indent=2) + "\n"
        if args.out is not None:
            args.out.parent.mkdir(parents=True, exist_ok=True)
            args.out.write_text(rendered, encoding="utf-8")
        print(rendered, end="")
        return 0 if self_test["ok"] else 1
    if args.probe_tag:
        if args.out is None:
            fail("single-tag probe validation needs --out")
        tag = args.probe_tag
        stamp = parse_probe_stamp(args.out_dir / f"property-{tag}-property.txt")
        grids = load_probe_grids(args.out_dir, tag, stamp)
        control = validate_probe_controls(args.out_dir, tag, stamp, grids)
        freshness = freshness_report(grids)
        stable = all(bool(row["stable"]) for row in freshness.values())
        gate_ok = bool(self_test["ok"] and control["ok"] and stable)
        payload = {
            "schema": "smr.propertycheck.probe.v3",
            "tag": tag,
            "gate_ok": gate_ok,
            "failed_checks": ([] if gate_ok else [
                name for name, ok in (
                    ("synthetic_controls", self_test["ok"]),
                    ("live_phase_controls", control["ok"]),
                    ("fresh_repeat_restore", stable),
                ) if not ok]),
            "self_test": self_test,
            "probe_controls": compact_controls(control),
            "freshness": freshness,
        }
        rendered = json.dumps(payload, indent=2) + "\n"
        args.out.parent.mkdir(parents=True, exist_ok=True)
        args.out.write_text(rendered, encoding="utf-8")
        print(rendered, end="")
        return 0 if gate_ok else 1
    if not args.vanilla or not args.expanded or args.out is None or args.differences is None:
        fail("live scoring needs --vanilla, --expanded, --out, and --differences")

    out_dir = args.out_dir
    vtag, etag = args.vanilla, args.expanded
    pre = args.pre or out_dir / f"stretch-{etag}-surface-pre.raw"
    post = args.post or out_dir / f"stretch-{etag}-surface-post.raw"
    zone_stamp = args.stamp or out_dir / f"height-{etag}-zones.txt"
    vstamp = parse_probe_stamp(out_dir / f"property-{vtag}-property.txt")
    estamp = parse_probe_stamp(out_dir / f"property-{etag}-property.txt")
    vgrids = load_probe_grids(out_dir, vtag, vstamp)
    egrids = load_probe_grids(out_dir, etag, estamp)
    vcontrol = validate_probe_controls(out_dir, vtag, vstamp, vgrids)
    econtrol = validate_probe_controls(out_dir, etag, estamp, egrids)
    normalised, zone_report = exact_normalised_nodes(pre, post, zone_stamp)
    pass_affected, pass_foot = footprint_mask(
        normalised, estamp, "surface", econtrol["anchor"], "passability")
    build_affected, build_foot = footprint_mask(
        normalised, estamp, "surface", econtrol["anchor"], "buildability")

    report: dict[str, object] = {
        "schema": "smr.propertycheck.v3",
        "vanilla": vtag,
        "expanded": etag,
        "gate_ok": False,
        "failed_checks": [],
        "self_test": self_test,
        "zones": zone_report,
        "probe_controls": {
            "vanilla": compact_controls(vcontrol),
            "expanded": compact_controls(econtrol),
        },
        "footprints": {"passability": pass_foot, "buildability": build_foot},
        "freshness": {"vanilla": freshness_report(vgrids), "expanded": freshness_report(egrids)},
        "maps": {},
    }
    failed: list[str] = report["failed_checks"]  # type: ignore[assignment]
    if not self_test["ok"]:
        failed.append("synthetic controls failed")
    if not zone_report["ok"]:
        failed.append("exact normalisation mask reconstruction failed")
    if not vcontrol["ok"] or not econtrol["ok"]:
        failed.append("live multi-phase probe control failed")
    if not pass_foot["ok"] or not build_foot["ok"]:
        failed.append("property footprint derivation failed")
    for role in ("vanilla", "expanded"):
        for env, fresh in report["freshness"][role].items():  # type: ignore[index,union-attr]
            if not fresh["stable"]:
                failed.append(f"{role}/{env}: fresh/repeat/restored mismatch")

    diff_rows: list[list[object]] = []
    for env in ("surface", "underground"):
        mapping = map_sites(vstamp, estamp, env)
        ex, ey = mapping.pop("ex"), mapping.pop("ey")
        assert isinstance(ex, np.ndarray) and isinstance(ey, np.ndarray)
        affected_masks = {
            "passability": pass_affected if env == "surface" else np.zeros(dims(estamp, env)[::-1], dtype=bool),
            "buildability": build_affected if env == "surface" else np.zeros(dims(estamp, env)[::-1], dtype=bool),
        }
        env_report: dict[str, object] = {"mapping": mapping}
        for name, bit in (("passability", 1), ("buildability", 2)):
            scored, different = compare_bits(vgrids[f"{env}:shipped"], egrids[f"{env}:shipped"],
                                             ex, ey, affected_masks[name], bit)
            scored["freshness_inside"] = affected_staleness(
                vgrids[f"{env}:shipped"], vgrids[f"{env}:fresh"],
                egrids[f"{env}:shipped"], egrids[f"{env}:fresh"],
                ex, ey, affected_masks[name], bit)
            env_report[name] = scored
            if not scored["outside_zero"]:
                failed.append(f"{env}/{name}: {scored['differences_outside']} outside-mask differences")
            if not scored["freshness_inside"]["inside_fresh"]:
                failed.append(f"{env}/{name}: shipped verdict stale inside affected set")
            dy, dx = np.nonzero(different)
            scope = affected_masks[name][ey, ex]
            vvalues = (vgrids[f"{env}:shipped"] & bit) != 0
            evalues = (egrids[f"{env}:shipped"] & bit) != 0
            for sy, sx in zip(dy.tolist(), dx.tolist()):
                esx, esy = int(ex[sy, sx]), int(ey[sy, sx])
                diff_rows.append([env, name, "inside" if scope[sy, sx] else "outside",
                                  sx, sy, esx, esy, int(vvalues[sy, sx]), int(evalues[esy, esx]),
                                  int(scope[sy, sx])])
        report["maps"][env] = env_report  # type: ignore[index]

    args.differences.parent.mkdir(parents=True, exist_ok=True)
    with args.differences.open("w", encoding="utf-8", newline="") as fh:
        writer = csv.writer(fh, lineterminator="\n")
        writer.writerow(["env", "property", "scope", "van_sx", "van_sy", "exp_sx", "exp_sy",
                         "van_value", "exp_value", "affected"])
        writer.writerows(diff_rows)
    report["difference_csv"] = str(args.differences)
    report["difference_rows"] = len(diff_rows)
    report["gate_ok"] = not failed
    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    print(json.dumps({key: report[key] for key in ("gate_ok", "failed_checks", "zones", "footprints",
                                                   "freshness", "maps", "difference_rows")}, indent=2))
    return 0 if report["gate_ok"] else 1


if __name__ == "__main__":
    sys.exit(main())
