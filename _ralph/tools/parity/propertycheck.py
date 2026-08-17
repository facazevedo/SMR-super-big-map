"""Score the floor sweep's exhaustive passability/buildability ruling.

``property_probe.lua`` writes dense shipped/fresh/repeat property rasters for both
twins, plus a self-restoring bank of one-height-node sensitivity controls.  This scorer:

* rebuilds the expanded twin's exact massif components from its pre-transform
  height grid and stamp;
* narrows that set to height nodes whose actual post-transform value differs from
  the clipped affine image (the exact spatial-normalisation set);
* indexes the live sensitivity bank by each height node's data-derived phase relative
  to its property site, requires exact replay within every phase across staggered row
  parities, then applies the matching phase footprint to every property site;
* enumerates every expanded property-storage site and inverse-maps its centre into
  the vanilla/source field by the probes' own ``HexToWorld`` calibration and the
  measured height-grid ratio;
* applies the complete, live-measured stock evaluation footprint to the exact
  non-affine height-node set before classifying every expanded verdict;
* requires zero fresh-stock field differences outside that footprint-aware set;
  and
* requires expanded shipped == fresh over the entire expanded map, plus fresh ==
  repeat (and restored == fresh where present), so freshness is authoritative and
  global rather than an exception-local diagnostic.

Every cross-twin difference is written to CSV.  There is no tolerance or allowlist.
The scorer intentionally requires exact pre/post stretch dumps; a bbox-only massif
stamp cannot satisfy the current ruling.

Typical use::

  python propertycheck.py --vanilla vanilla_tag --expanded expanded_tag \
    --out artifacts/property_case.json --differences artifacts/property_case.csv

Run ``--self-test`` before live use.  Its mandatory discriminator injects a single
residual at an expanded site omitted by the superseded forward mapper and requires
the old subset to miss it while the production inverse scorer and global freshness
gate both reject it.
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


def forward_map_sites(van: ProbeStamp, exp: ProbeStamp,
                      env: str) -> dict[str, np.ndarray | float | int]:
    """Superseded vanilla-to-expanded subset, retained only as a self-test control."""
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
    displacement = rounded_world - world * scale
    residual = np.linalg.norm(displacement, axis=0)
    exact_world = residual <= 1e-9
    vectors, vector_counts = np.unique(
        np.round(displacement.T, decimals=9), axis=0, return_counts=True)
    residual_classes = [
        {
            "dx": float(vector[0]),
            "dy": float(vector[1]),
            "distance": float(np.linalg.norm(vector)),
            "sites": int(count),
        }
        for vector, count in zip(vectors, vector_counts)
    ]
    return {
        "ex": ex,
        "ey": ey,
        "exact_world": exact_world.reshape((vgh, vgw)),
        "scale": scale,
        "sites": vgw * vgh,
        "expanded_unmapped": egw * egh - unique,
        "geometry": "alternating_row_parity",
        "vanilla_calibration_max_error": vgeometry.calibration_max_error,
        "expanded_calibration_max_error": egeometry.calibration_max_error,
        "exact_world_sites": int(exact_world.sum()),
        "noncoincident_sites": int((~exact_world).sum()),
        "residual_classes": residual_classes,
        "max_world_rounding_residual": float(residual.max(initial=0.0)),
        "p99_world_rounding_residual": float(np.percentile(residual, 99)) if residual.size else 0.0,
    }


def map_sites(van: ProbeStamp, exp: ProbeStamp,
              env: str) -> dict[str, np.ndarray | float | int | str]:
    """Inverse-map every expanded property centre into the source spatial field.

    The finite vanilla storage raster does not contain a sample for a narrow strip
    of expanded edge centres.  Those centres lie outside the source property
    domain after inverse transformation and therefore receive the stock outside-
    map value (false/unbuildable), represented by ``in_source == False``.
    """
    vgw, vgh = dims(van, env)
    egw, egh = dims(exp, env)
    vrow, erow = van.maps[env], exp.maps[env]
    vh, eh = int(vrow["height_gw"]), int(erow["height_gw"])
    if vh <= 0 or eh <= vh:
        fail(f"{env}: expected expanded height grid larger than vanilla ({vh}, {eh})")
    scale = eh / vh
    vgeometry = geometry_for(van, env)
    egeometry = geometry_for(exp, env)

    ey, ex = np.indices((egh, egw), dtype=np.int64)
    expanded_world = storage_to_world(egeometry, ex.ravel(), ey.ravel())
    source_world = expanded_world / scale
    source, source_float = world_to_storage(vgeometry, source_world)
    vx = source[0].reshape((egh, egw))
    vy = source[1].reshape((egh, egw))
    in_source = (vx >= 0) & (vx < vgw) & (vy >= 0) & (vy < vgh)

    covered_linear = vy[in_source] * vgw + vx[in_source]
    covered = int(np.unique(covered_linear).size)
    if covered != vgw * vgh:
        fail(f"{env}: inverse mapping does not cover the complete source field "
             f"({covered}/{vgw * vgh})")

    rounded_source_world = storage_to_world(vgeometry, source[0], source[1])
    displacement = rounded_source_world - source_world
    residual = np.linalg.norm(displacement, axis=0)
    exact_world = (residual <= 1e-9).reshape((egh, egw))
    vectors, vector_counts = np.unique(
        np.round(displacement.T, decimals=9), axis=0, return_counts=True)
    residual_classes = [
        {
            "dx": float(vector[0]),
            "dy": float(vector[1]),
            "distance": float(np.linalg.norm(vector)),
            "sites": int(count),
        }
        for vector, count in zip(vectors, vector_counts)
    ]
    return {
        "vx": vx,
        "vy": vy,
        "in_source": in_source,
        "exact_world": exact_world,
        "source_world_x": source_world[0].reshape((egh, egw)),
        "source_world_y": source_world[1].reshape((egh, egw)),
        "scale": scale,
        "sites": egw * egh,
        "expanded_sites": egw * egh,
        "source_sites": vgw * vgh,
        "source_sites_covered": covered,
        "source_sites_uncovered": vgw * vgh - covered,
        "out_of_source_sites": int((~in_source).sum()),
        "out_of_source_value": "false_unbuildable",
        "geometry": "all_expanded_inverse_alternating_row_parity",
        "vanilla_calibration_max_error": vgeometry.calibration_max_error,
        "expanded_calibration_max_error": egeometry.calibration_max_error,
        "exact_world_sites": int(exact_world.sum()),
        "noncoincident_sites": int((~exact_world).sum()),
        "residual_classes": residual_classes,
        "max_world_rounding_residual": float(residual.max(initial=0.0)),
        "p99_world_rounding_residual": float(np.percentile(residual, 99)) if residual.size else 0.0,
        "source_continuous_x_range": [float(source_float[0].min()), float(source_float[0].max())],
        "source_continuous_y_range": [float(source_float[1].min()), float(source_float[1].max())],
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


def control_phase(meta: dict[str, str], tile: float) -> tuple[int, int]:
    """Height-node offset from the terrain cell containing the control property site."""
    site_x = float(meta["site_wx"])
    site_y = float(meta["site_wy"])
    base_gx = math.floor(site_x / tile)
    base_gy = math.floor(site_y / tile)
    return int(meta["node_gx"]) - base_gx, int(meta["node_gy"]) - base_gy


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
            # A phase can legitimately have an empty response for one property.  The
            # complete raw/CSV equality above proves that emptiness; requiring both
            # bits to move was the v3 one-kernel defect exposed by t97a.
            "property_response_present": bool(rows),
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
            "site_world": measured_site.tolist(),
            "site_storage": [int(meta["site_sx"]), int(meta["site_sy"])],
            "site_row_parity": int(meta["site_sy"]) % 2,
            "phase": list(control_phase(meta, tile)),
            "counts": {"all": len(rows), "passability": len(pass_rows),
                       "buildability": len(build_rows)},
        })

    site_banks: dict[tuple[int, int], set[tuple[int, int]]] = {}
    phase_parities: dict[tuple[int, int], set[int]] = {}
    for control in controls:
        site = tuple(control["site_storage"])  # type: ignore[arg-type]
        phase = tuple(control["phase"])  # type: ignore[arg-type]
        site_banks.setdefault(site, set()).add(phase)
        phase_parities.setdefault(phase, set()).add(int(control["site_row_parity"]))
    bank_values = list(site_banks.values())
    common_bank = bank_values[0] if bank_values else set()

    cross_checks: list[dict[str, object]] = []
    for source in controls:
        for target in controls:
            same_phase = source["phase"] == target["phase"]
            row = {"source": source["id"], "target": target["id"],
                   "same_phase": same_phase}
            for property_name in ("passability", "buildability"):
                predicted = replay_cells(geometry, source, target, property_name)
                key = "pass_rows" if property_name == "passability" else "build_rows"
                observed = {(item["sx"], item["sy"]) for item in target[key]}
                row[property_name] = predicted == observed
            row["ok"] = bool(row["passability"] and row["buildability"])
            cross_checks.append(row)
    parities = {int(control["site_row_parity"]) for control in controls}
    within_phase = [row for row in cross_checks if row["same_phase"]]
    cross_phase = [row for row in cross_checks if not row["same_phase"]]
    all_within_exact = bool(within_phase) and all(bool(row["ok"]) for row in within_phase)
    cross_phase_mismatches = sum(not bool(row["ok"]) for row in cross_phase)
    banks_match = bool(bank_values) and all(bank == common_bank for bank in bank_values)
    phases_span_parities = bool(phase_parities) and all(
        phase_set == {0, 1} for phase_set in phase_parities.values())
    checks = {
        "all_controls_valid": all(bool(control["ok"]) for control in controls),
        "both_row_parities_present": parities == {0, 1},
        "site_phase_banks_match": banks_match,
        "every_phase_spans_row_parities": phases_span_parities,
        "within_phase_kernels_cross_replay_exact": all_within_exact,
        "cross_phase_discriminator_fires": cross_phase_mismatches > 0,
    }
    phase_controls: dict[tuple[int, int], dict[str, object]] = {}
    for control in controls:
        phase_controls.setdefault(tuple(control["phase"]), control)  # type: ignore[arg-type]
    return {
        "checks": checks,
        "ok": all(checks.values()),
        "controls": controls,
        "cross_checks": cross_checks,
        "phase_controls": phase_controls,
        "control_count": len(controls),
        "phase_count": len(phase_controls),
        "cross_replays": len(cross_checks),
        "within_phase_replays": len(within_phase),
        "cross_phase_mismatches": cross_phase_mismatches,
    }


def compact_controls(control: dict[str, object]) -> dict[str, object]:
    compact = {key: value for key, value in control.items()
               if key not in {"controls", "phase_controls"}}
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


def freshness_report(grids: dict[str, np.ndarray]) -> dict[str, dict[str, object]]:
    report: dict[str, dict[str, object]] = {}
    for env in ("surface", "underground"):
        fresh = grids[f"{env}:fresh"]
        shipped_grid = grids[f"{env}:shipped"]
        shipped = int((shipped_grid != fresh).sum())
        repeat = int((grids[f"{env}:repeat"] != fresh).sum())
        restored = int((grids[f"{env}:restored"] != fresh).sum()) if env == "surface" else 0
        by_property = {}
        for name, bit in (("passability", 1), ("buildability", 2)):
            changed = ((shipped_grid ^ fresh) & bit) != 0
            by_property[name] = {
                "shipped_vs_fresh": int(changed.sum()),
                "shipped_fresh": int(changed.sum()) == 0,
            }
        report[env] = {
            "shipped_vs_fresh": shipped,
            "shipped_fresh": shipped == 0,
            "repeat_vs_fresh": repeat,
            "restored_vs_fresh": restored,
            "stable": repeat == 0 and restored == 0,
            "by_property": by_property,
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
                   control_bank: dict[str, object], property_name: str) -> tuple[np.ndarray, dict]:
    """Apply each measured node phase only at the matching phase around every site."""
    gw, gh = dims(stamp, env)
    geometry = geometry_for(stamp, env)
    key = "pass_rows" if property_name == "passability" else "build_rows"
    affected = np.zeros((gh, gw), dtype=bool)
    tile = float(stamp.maps[env]["tile"])
    site_sy, site_sx = np.indices((gh, gw), dtype=np.int64)
    site_world = storage_to_world(geometry, site_sx.ravel(), site_sy.ravel())
    base_gx = np.floor(site_world[0] / tile).astype(np.int64)
    base_gy = np.floor(site_world[1] / tile).astype(np.int64)
    phase_controls = control_bank["phase_controls"]
    phase_detail: list[dict[str, object]] = []
    chunk = 250_000
    total_kernel_cells = 0
    for phase in sorted(phase_controls):  # type: ignore[union-attr]
        control = phase_controls[phase]  # type: ignore[index]
        rows = control[key]
        total_kernel_cells += len(rows)
        node_x = base_gx + phase[0]
        node_y = base_gy + phase[1]
        valid_node = ((node_x >= 0) & (node_x < nodes.shape[1])
                      & (node_y >= 0) & (node_y < nodes.shape[0]))
        selected = np.zeros(valid_node.shape, dtype=bool)
        valid_idx = np.flatnonzero(valid_node)
        selected[valid_idx] = nodes[node_y[valid_idx], node_x[valid_idx]]
        target_idx = np.flatnonzero(selected)
        output_before = int(affected.sum())
        if rows and target_idx.size:
            observed_storage = np.asarray(
                [[row["sx"], row["sy"]] for row in rows], dtype=np.int64)
            observed_world = storage_to_world(
                geometry, observed_storage[:, 0], observed_storage[:, 1]).T
            source_site = np.asarray(control["site_world"], dtype=np.float64)
            world_offsets = observed_world - source_site[None, :]
            for start in range(0, target_idx.size, chunk):
                stop = min(start + chunk, target_idx.size)
                target_world = site_world[:, target_idx[start:stop]]
                for offset in world_offsets:
                    cell, _ = world_to_storage(geometry, target_world + offset[:, None])
                    sx, sy = cell[0], cell[1]
                    valid = (sx >= 0) & (sx < gw) & (sy >= 0) & (sy < gh)
                    affected[sy[valid], sx[valid]] = True
        phase_detail.append({
            "phase": list(phase),
            "kernel_cells": len(rows),
            "selected_sites": int(target_idx.size),
            "new_affected_cells": int(affected.sum()) - output_before,
        })

    # Every property site is evaluated against the same data-derived phase bank.  The
    # live validator has already required each phase to replay across both storage-row
    # parities, so no global affine or one-anchor projection is hidden here.
    detail = {
        "phase_count": len(phase_controls),  # type: ignore[arg-type]
        "kernel_cells_across_phases": total_kernel_cells,
        "geometry": "site_relative_height_phase_over_alternating_row_parity",
        "calibration_max_error": geometry.calibration_max_error,
        "within_phase_replay_exact": bool(
            control_bank["checks"]["within_phase_kernels_cross_replay_exact"]),  # type: ignore[index]
        "affected_cells": int(affected.sum()),
        "height_nodes": int(nodes.sum()),
        "phases": phase_detail,
    }
    detail["ok"] = bool(control_bank["ok"] and total_kernel_cells > 0)
    return affected, detail


def inverse_expected(van_bits: np.ndarray, vx: np.ndarray, vy: np.ndarray,
                     in_source: np.ndarray, bit: int) -> np.ndarray:
    """Nearest-centre sample of the inverse transformed source field.

    The complete stock evaluation footprint is used separately to construct the
    expanded ``affected`` mask.  Outside the finite source field the stock spatial
    value is false/unbuildable.
    """
    vanilla = (van_bits & bit) != 0
    expected = np.zeros(vx.shape, dtype=bool)
    expected[in_source] = vanilla[vy[in_source], vx[in_source]]
    return expected


def compare_bits(van_bits: np.ndarray, exp_bits: np.ndarray, vx: np.ndarray, vy: np.ndarray,
                 in_source: np.ndarray, affected: np.ndarray,
                 bit: int) -> tuple[dict[str, int | bool], np.ndarray]:
    expected = inverse_expected(van_bits, vx, vy, in_source, bit)
    expanded = (exp_bits & bit) != 0
    scope = affected
    different = expected != expanded
    outside = different & ~scope
    inside = different & scope
    report = {
        "corresponding_sites": int(different.size),
        "all_expanded_sites_scored": int(different.size) == int(exp_bits.size),
        "in_source_sites": int(in_source.sum()),
        "out_of_source_sites": int((~in_source).sum()),
        "affected_sites": int(scope.sum()),
        "outside_sites": int((~scope).sum()),
        "differences_total": int(different.sum()),
        "differences_outside": int(outside.sum()),
        "differences_inside": int(inside.sum()),
        "outside_false_to_true": int((~expected & expanded & ~scope).sum()),
        "outside_true_to_false": int((expected & ~expanded & ~scope).sum()),
        "outside_zero": int(outside.sum()) == 0,
    }
    return report, different


def property_border_distance(stamp: ProbeStamp, env: str) -> np.ndarray:
    """Rectangular world distance from every property site to the height-map edge."""
    gw, gh = dims(stamp, env)
    row = stamp.maps[env]
    geometry = geometry_for(stamp, env)
    sy, sx = np.indices((gh, gw), dtype=np.int64)
    world = storage_to_world(geometry, sx.ravel(), sy.ravel()).reshape((2, gh, gw))
    width = int(row["height_gw"]) * float(row["tile"])
    height = int(row["height_gh"]) * float(row["tile"])
    return np.minimum.reduce((world[0], world[1], width - world[0], height - world[1]))


def count_binary_partition(mask: np.ndarray, exact_world: np.ndarray, different: np.ndarray,
                           vanilla: np.ndarray, expanded: np.ndarray) -> dict[str, int]:
    selected = exact_world & mask
    return {
        "sites": int(selected.sum()),
        "differences": int((different & selected).sum()),
        "false_to_true": int((~vanilla & expanded & selected).sum()),
        "true_to_false": int((vanilla & ~expanded & selected).sum()),
    }


def exact_world_stock_inputs(vstamp: ProbeStamp, estamp: ProbeStamp, env: str,
                             exact_world: np.ndarray, different: np.ndarray,
                             vanilla: np.ndarray, expanded: np.ndarray,
                             source_distance: np.ndarray | None = None) -> dict[str, object]:
    """Partition exact-world results by the stock map-border passability input.

    This is diagnostic only: neither partition relaxes the production zero-difference gate.
    The strict ``<`` convention is intentionally explicit and synthetic-controlled.
    """
    if source_distance is None:
        source_distance = property_border_distance(vstamp, env)
    vanilla_border = float(vstamp.maps[env]["pass_border"])
    expanded_border = float(estamp.maps[env]["pass_border"])
    in_vanilla_border = source_distance < vanilla_border
    exact_differences = exact_world & different
    differing_distances = source_distance[exact_differences]
    distance_summary = {
        "minimum": float(differing_distances.min()) if differing_distances.size else 0.0,
        "median": float(np.median(differing_distances)) if differing_distances.size else 0.0,
        "maximum": float(differing_distances.max()) if differing_distances.size else 0.0,
    }
    return {
        "input": "PassBorder",
        "distance_geometry": "rectangular_world_distance_to_height_map_edge",
        "membership_rule": "source_border_distance < vanilla_pass_border",
        "vanilla_pass_border": vanilla_border,
        "expanded_pass_border": expanded_border,
        "pass_border_inputs_equal": vanilla_border == expanded_border,
        "within_vanilla_pass_border": count_binary_partition(
            in_vanilla_border, exact_world, different, vanilla, expanded),
        "outside_vanilla_pass_border": count_binary_partition(
            ~in_vanilla_border, exact_world, different, vanilla, expanded),
        "exact_difference_source_border_distance": distance_summary,
        "diagnostic_only": True,
    }


def affected_staleness(van_shipped: np.ndarray, van_fresh: np.ndarray,
                       exp_shipped: np.ndarray, exp_fresh: np.ndarray,
                       vx: np.ndarray, vy: np.ndarray, in_source: np.ndarray,
                       affected: np.ndarray,
                       bit: int) -> dict[str, int | bool]:
    van_changed = ((van_shipped ^ van_fresh) & bit) != 0
    exp_changed = ((exp_shipped ^ exp_fresh) & bit) != 0
    mapped_van_changed = np.zeros(affected.shape, dtype=bool)
    mapped_van_changed[in_source] = van_changed[vy[in_source], vx[in_source]]
    van_stale = int((mapped_van_changed & affected).sum())
    exp_stale = int((exp_changed & affected).sum())
    return {
        "vanilla_mapped_affected_sites": int((affected & in_source).sum()),
        "expanded_affected_sites": int(affected.sum()),
        "mapped_vanilla_shipped_vs_fresh_inside": van_stale,
        "expanded_shipped_vs_fresh_inside": exp_stale,
        "inside_fresh": van_stale == 0 and exp_stale == 0,
    }


def synthetic_controls() -> dict[str, object]:
    geometry_calibration = {
        (0, 0): (0.0, 0.0), (1, 0): (1000.0, 0.0),
        (0, 1): (500.0, 866.0), (1, 1): (1500.0, 866.0),
        (0, 2): (0.0, 1732.0), (1, 2): (1000.0, 1732.0),
    }
    vmaps = {env: {"gw": "15", "gh": "18", "height_gw": "150", "height_gh": "150",
                    "tile": "100", "pass_border": "2000"}
             for env in ("surface", "underground")}
    emaps = {env: {"gw": "20", "gh": "24", "height_gw": "200", "height_gh": "200",
                    "tile": "100", "pass_border": "0"}
             for env in ("surface", "underground")}
    calibrations = {env: geometry_calibration for env in ("surface", "underground")}
    vstamp = ProbeStamp(vmaps, calibrations, {}, [])
    estamp = ProbeStamp(emaps, calibrations, {}, [])
    geometry = geometry_for(vstamp, "surface")
    egeometry = geometry_for(estamp, "surface")
    test_sx = np.asarray([0, 1, 0, 1, 7, 7], dtype=np.int64)
    test_sy = np.asarray([0, 0, 1, 2, 9, 10], dtype=np.int64)
    test_world = storage_to_world(geometry, test_sx, test_sy)
    roundtrip, _ = world_to_storage(geometry, test_world)
    forward = forward_map_sites(vstamp, estamp, "surface")
    mapped_x = forward["ex"]
    mapped_y = forward["ey"]
    mapping = map_sites(vstamp, estamp, "surface")
    vx, vy = mapping["vx"], mapping["vy"]
    in_source = mapping["in_source"]
    exact_world = mapping["exact_world"]
    assert (isinstance(mapped_x, np.ndarray) and isinstance(mapped_y, np.ndarray)
            and isinstance(vx, np.ndarray) and isinstance(vy, np.ndarray)
            and isinstance(in_source, np.ndarray) and isinstance(exact_world, np.ndarray))
    src_y, src_x = np.indices((18, 15), dtype=np.float64)
    old_affine_x = round_storage(src_x * (4.0 / 3.0))
    parity_discriminator = int((old_affine_x != mapped_x).sum())

    baseline = np.full((18, 15), 3, dtype=np.uint8)
    expected_exp = np.zeros((24, 20), dtype=np.uint8)
    expected_exp[in_source] = 3
    green_exp = expected_exp.copy()
    pass_mask = np.zeros(green_exp.shape, dtype=bool)
    build_mask = np.zeros(green_exp.shape, dtype=bool)
    pass_mask[4, 5] = True
    build_mask[6, 7] = True
    green_exp[pass_mask] ^= 1
    green_exp[build_mask] ^= 2
    p_green, _ = compare_bits(
        baseline, green_exp, vx, vy, in_source, pass_mask, 1)
    b_green, _ = compare_bits(
        baseline, green_exp, vx, vy, in_source, build_mask, 2)

    forward_coverage = np.zeros(green_exp.shape, dtype=bool)
    forward_coverage[mapped_y, mapped_x] = True
    old_unmapped = ~forward_coverage & in_source & ~pass_mask & ~build_mask
    injected_linear = int(np.flatnonzero(old_unmapped)[0])
    injected_y, injected_x = np.unravel_index(injected_linear, green_exp.shape)
    bad_pass = expected_exp.copy()
    bad_pass[injected_y, injected_x] ^= 1
    p_bad, _ = compare_bits(
        baseline, bad_pass, vx, vy, in_source, pass_mask, 1)
    old_source_pass = (baseline & 1) != 0
    old_exp_pass = (bad_pass[mapped_y, mapped_x] & 1) != 0
    old_subset_differences = int((old_source_pass != old_exp_pass).sum())

    bad_build = expected_exp.copy()
    build_inject_y, build_inject_x = np.unravel_index(
        int(np.flatnonzero(old_unmapped)[1]), green_exp.shape)
    bad_build[build_inject_y, build_inject_x] ^= 2
    b_bad, _ = compare_bits(
        baseline, bad_build, vx, vy, in_source, build_mask, 2)

    stale = green_exp.copy()
    stale[pass_mask] ^= 1
    stale_report = affected_staleness(
        baseline, baseline, stale, green_exp, vx, vy, in_source, pass_mask, 1)
    fresh_grids = {}
    for env in ("surface", "underground"):
        fresh_grids[f"{env}:fresh"] = green_exp.copy()
        fresh_grids[f"{env}:repeat"] = green_exp.copy()
        fresh_grids[f"{env}:shipped"] = green_exp.copy()
    fresh_grids["surface:restored"] = green_exp.copy()
    fresh_grids["surface:shipped"][injected_y, injected_x] ^= 1
    global_freshness = freshness_report(fresh_grids)
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
    synthetic_site = (5, 4)
    synthetic_site_world = storage_to_world(
        egeometry, np.asarray(synthetic_site[0]), np.asarray(synthetic_site[1]))
    synthetic_base = np.floor(synthetic_site_world / 100.0).astype(np.int64)
    active_nodes = np.zeros((150, 150), dtype=bool)
    active_nodes[synthetic_base[1], synthetic_base[0]] = True
    inactive_nodes = np.zeros_like(active_nodes)
    inactive_nodes[synthetic_base[1], synthetic_base[0] + 1] = True
    phase_bank = {
        "ok": True,
        "checks": {"within_phase_kernels_cross_replay_exact": True},
        "phase_controls": {
            (0, 0): {
                "site_world": storage_to_world(
                    egeometry, np.asarray(2), np.asarray(2)).tolist(),
                "pass_rows": [{"sx": 2, "sy": 2}],
                "build_rows": [{"sx": 2, "sy": 2}],
            },
            (1, 0): {
                "site_world": storage_to_world(
                    egeometry, np.asarray(2), np.asarray(2)).tolist(),
                "pass_rows": [],
                "build_rows": [{"sx": 2, "sy": 2}],
            },
        },
    }
    active_footprint, active_detail = footprint_mask(
        active_nodes, estamp, "surface", phase_bank, "passability")
    inactive_footprint, inactive_detail = footprint_mask(
        inactive_nodes, estamp, "surface", phase_bank, "passability")
    synthetic_vbits = np.zeros((18, 15), dtype=np.uint8)
    synthetic_ebits = np.zeros((24, 20), dtype=np.uint8)
    source_world_x = mapping["source_world_x"]
    source_world_y = mapping["source_world_y"]
    assert isinstance(source_world_x, np.ndarray) and isinstance(source_world_y, np.ndarray)
    source_extent = 150 * 100
    source_distance = np.minimum.reduce((source_world_x, source_world_y,
                                         source_extent - source_world_x,
                                         source_extent - source_world_y))
    synthetic_border = source_distance < 2000
    injected_border = exact_world & synthetic_border
    synthetic_ebits[injected_border] = 1
    synthetic_vvalues = inverse_expected(synthetic_vbits, vx, vy, in_source, 1)
    synthetic_evalues = (synthetic_ebits & 1) != 0
    synthetic_different = synthetic_vvalues != synthetic_evalues
    border_partition = exact_world_stock_inputs(
        vstamp, estamp, "surface", exact_world, synthetic_different,
        synthetic_vvalues, synthetic_evalues, source_distance)

    checks = {
        "inside_differences_are_classified_inside": (
            p_green["differences_inside"] == 1 and p_green["differences_outside"] == 0
            and b_green["differences_inside"] == 1 and b_green["differences_outside"] == 0),
        "outside_pass_injection_rejected": p_bad["differences_outside"] == 1,
        "outside_build_injection_rejected": b_bad["differences_outside"] == 1,
        "old_forward_subset_misses_unmapped_injection": old_subset_differences == 0,
        "injected_site_was_old_unmapped": not bool(forward_coverage[injected_y, injected_x]),
        "all_expanded_inverse_scorer_covers_injection": (
            p_bad["corresponding_sites"] == 20 * 24
            and p_bad["all_expanded_sites_scored"]),
        "global_expanded_freshness_rejects_unmapped_injection": (
            global_freshness["surface"]["shipped_vs_fresh"] == 1
            and not global_freshness["surface"]["shipped_fresh"]),
        "stale_in_mask_injection_rejected": (
            stale_report["expanded_shipped_vs_fresh_inside"] == 1
            and not stale_report["inside_fresh"]),
        "parity_geometry_roundtrips": bool(np.array_equal(
            roundtrip, np.vstack((test_sx, test_sy)))),
        "row_two_rejects_global_affine_model": parity_discriminator > 0,
        "odd_row_inverse_mapping_is_parity_aware": (
            int(vx[1, 1]) == 1 and int(vy[1, 1]) == 1),
        "even_row_inverse_mapping_is_parity_aware": (
            int(vx[2, 2]) == 2 and int(vy[2, 2]) == 2),
        "exact_world_sublattice_is_detected": 0 < int(exact_world.sum()) < 20 * 24,
        "noncoincident_residual_classes_are_detected": len(mapping["residual_classes"]) >= 9,
        "inverse_mapping_covers_all_source_sites": (
            mapping["source_sites_covered"] == 15 * 18
            and mapping["source_sites_uncovered"] == 0),
        "phase_kernel_cross_replays_across_row_parity": phase_replay == {(6, 5)},
        "phase_kernel_mismatch_is_rejected": phase_replay != {(7, 5)},
        "phase_index_selects_matching_footprint": (
            bool(active_footprint[synthetic_site[1], synthetic_site[0]])
            and int(active_footprint.sum()) == 1 and active_detail["ok"]),
        "empty_phase_does_not_widen_footprint": (
            int(inactive_footprint.sum()) == 0 and inactive_detail["ok"]),
        "pass_border_partition_is_exact": (
            border_partition["within_vanilla_pass_border"]["differences"]
            == int(injected_border.sum())
            and border_partition["outside_vanilla_pass_border"]["differences"] == 0),
        "pass_border_input_mismatch_is_reported": (
            border_partition["vanilla_pass_border"] == 2000.0
            and border_partition["expanded_pass_border"] == 0.0
            and not border_partition["pass_border_inputs_equal"]),
    }
    return {"ok": all(checks.values()), "checks": checks,
            "geometry_control": {
                "calibration_max_error": geometry.calibration_max_error,
                "roundtrip_sites": int(test_sx.size),
                "global_affine_disagreements": parity_discriminator,
                "mapping_sites": int(mapping["sites"]),
                "forward_subset_sites": int(forward["sites"]),
                "forward_unmapped_sites": int(forward["expanded_unmapped"]),
                "injected_old_unmapped_site": [int(injected_x), int(injected_y)],
                "old_subset_differences": old_subset_differences,
            },
            "phase_control": {
                "matching_affected_cells": int(active_footprint.sum()),
                "empty_phase_affected_cells": int(inactive_footprint.sum()),
            },
            "border_control": border_partition,
            "injected_counts": {"outside_pass": p_bad["differences_outside"],
                                 "outside_build": b_bad["differences_outside"],
                                 "stale": stale_report["expanded_shipped_vs_fresh_inside"],
                                 "global_freshness": global_freshness["surface"]["shipped_vs_fresh"]}}


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
        payload = {"schema": "smr.propertycheck.selftest.v5", **self_test}
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
            "schema": "smr.propertycheck.probe.v5",
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
        normalised, estamp, "surface", econtrol, "passability")
    build_affected, build_foot = footprint_mask(
        normalised, estamp, "surface", econtrol, "buildability")

    report: dict[str, object] = {
        "schema": "smr.propertycheck.v5",
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
        "correspondence_rule": {
            "enumeration": "every_expanded_property_site",
            "source_field": "fresh_stock_vanilla_inverse_nearest_center",
            "outside_source_value": "false_unbuildable",
            "normalisation_exception": "complete_live_measured_expanded_stock_footprint",
            "primary_gate": "expanded_shipped_equals_fresh_everywhere",
        },
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
            if role == "expanded" and not fresh["shipped_fresh"]:
                by_property = fresh["by_property"]
                failed.append(
                    f"expanded/{env}: shipped verdict stale globally "
                    f"(pass={by_property['passability']['shipped_vs_fresh']}, "
                    f"build={by_property['buildability']['shipped_vs_fresh']})")

    diff_rows: list[list[object]] = []
    for env in ("surface", "underground"):
        mapping = map_sites(vstamp, estamp, env)
        vx, vy = mapping.pop("vx"), mapping.pop("vy")
        in_source = mapping.pop("in_source")
        exact_world = mapping.pop("exact_world")
        source_world_x = mapping.pop("source_world_x")
        source_world_y = mapping.pop("source_world_y")
        assert (isinstance(vx, np.ndarray) and isinstance(vy, np.ndarray)
                and isinstance(in_source, np.ndarray) and isinstance(exact_world, np.ndarray)
                and isinstance(source_world_x, np.ndarray)
                and isinstance(source_world_y, np.ndarray))
        vrow = vstamp.maps[env]
        source_width = int(vrow["height_gw"]) * float(vrow["tile"])
        source_height = int(vrow["height_gh"]) * float(vrow["tile"])
        source_distance = np.minimum.reduce((source_world_x, source_world_y,
                                             source_width - source_world_x,
                                             source_height - source_world_y))
        affected_masks = {
            "passability": pass_affected if env == "surface" else np.zeros(dims(estamp, env)[::-1], dtype=bool),
            "buildability": build_affected if env == "surface" else np.zeros(dims(estamp, env)[::-1], dtype=bool),
        }
        env_report: dict[str, object] = {"mapping": mapping}
        for name, bit in (("passability", 1), ("buildability", 2)):
            scored, different = compare_bits(
                vgrids[f"{env}:fresh"], egrids[f"{env}:fresh"],
                vx, vy, in_source, affected_masks[name], bit)
            source_scope = affected_masks[name]
            vanilla_values = inverse_expected(
                vgrids[f"{env}:fresh"], vx, vy, in_source, bit)
            expanded_values = (egrids[f"{env}:fresh"] & bit) != 0
            exact_outside = exact_world & ~source_scope
            exact_inside = exact_world & source_scope
            scored["exact_world_correspondence"] = {
                "sites": int(exact_world.sum()),
                "outside_sites": int(exact_outside.sum()),
                "inside_sites": int(exact_inside.sum()),
                "differences": int((different & exact_world).sum()),
                "differences_outside": int((different & exact_outside).sum()),
                "differences_inside": int((different & exact_inside).sum()),
                "outside_false_to_true": int(
                    (~vanilla_values & expanded_values & exact_outside).sum()),
                "outside_true_to_false": int(
                    (vanilla_values & ~expanded_values & exact_outside).sum()),
                "outside_zero": int((different & exact_outside).sum()) == 0,
            }
            scored["exact_world_correspondence"]["stock_inputs"] = exact_world_stock_inputs(
                vstamp, estamp, env, exact_world, different, vanilla_values, expanded_values,
                source_distance)
            scored["freshness_inside"] = affected_staleness(
                vgrids[f"{env}:shipped"], vgrids[f"{env}:fresh"],
                egrids[f"{env}:shipped"], egrids[f"{env}:fresh"],
                vx, vy, in_source, affected_masks[name], bit)
            env_report[name] = scored
            if not scored["outside_zero"]:
                failed.append(f"{env}/{name}: {scored['differences_outside']} outside-mask differences")
            if not scored["freshness_inside"]["inside_fresh"]:
                failed.append(f"{env}/{name}: shipped verdict stale inside affected set")
            dy, dx = np.nonzero(different)
            scope = affected_masks[name]
            for esy, esx in zip(dy.tolist(), dx.tolist()):
                vsx, vsy = int(vx[esy, esx]), int(vy[esy, esx])
                diff_rows.append([
                    env, name, "inside" if scope[esy, esx] else "outside",
                    vsx, vsy, esx, esy,
                    int(vanilla_values[esy, esx]), int(expanded_values[esy, esx]),
                    int(scope[esy, esx]), int(in_source[esy, esx]),
                ])
        report["maps"][env] = env_report  # type: ignore[index]

    args.differences.parent.mkdir(parents=True, exist_ok=True)
    with args.differences.open("w", encoding="utf-8", newline="") as fh:
        writer = csv.writer(fh, lineterminator="\n")
        writer.writerow(["env", "property", "scope", "van_sx", "van_sy", "exp_sx", "exp_sy",
                         "van_value", "exp_value", "affected", "in_source"])
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
