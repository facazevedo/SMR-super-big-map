"""Score the floor sweep's exhaustive passability/buildability ruling.

``property_probe.lua`` writes dense shipped/fresh/repeat property rasters for both
twins, plus a self-restoring one-height-node sensitivity control.  This scorer:

* rebuilds the expanded twin's exact massif components from its pre-transform
  height grid and stamp;
* narrows that set to height nodes whose actual post-transform value differs from
  the clipped affine image (the exact spatial-normalisation set);
* derives separate passability and buildability reverse footprints from the live
  sensitivity control and applies them to every normalised height node;
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

  python propertycheck.py --vanilla t100a --expanded t100x \
    --out artifacts/property_t100.json --differences artifacts/property_t100.csv

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
    control: dict[str, str]


def parse_probe_stamp(path: Path) -> ProbeStamp:
    maps: dict[str, dict[str, str]] = {}
    calibration: dict[str, dict[tuple[int, int], tuple[float, float]]] = {}
    freshness: dict[str, dict[str, str]] = {}
    control: dict[str, str] = {}
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
            control = fields
    missing = {"surface", "underground"} - maps.keys()
    if missing:
        fail(f"{path}: missing map rows for {sorted(missing)}")
    for env in ("surface", "underground"):
        need = {(0, 0), (1, 0), (0, 1), (1, 1)}
        if need - calibration.get(env, {}).keys():
            fail(f"{path}: incomplete {env} HexToWorld calibration")
    return ProbeStamp(maps, calibration, freshness, control)


def load_property(path: Path, gw: int, gh: int) -> np.ndarray:
    raw = np.fromfile(path, dtype=np.uint8)
    if raw.size != gw * gh:
        fail(f"{path}: {raw.size} bytes, expected {gw}x{gh}={gw * gh}")
    if raw.size and int(raw.max()) > 3:
        fail(f"{path}: property byte outside bit mask 0..3")
    return raw.reshape((gh, gw))


def matrix_for(stamp: ProbeStamp, env: str) -> tuple[np.ndarray, np.ndarray, np.ndarray]:
    cal = stamp.calibration[env]
    origin = np.asarray(cal[(0, 0)], dtype=np.float64)
    axis_x = np.asarray(cal[(1, 0)], dtype=np.float64) - origin
    axis_y = np.asarray(cal[(0, 1)], dtype=np.float64) - origin
    matrix = np.column_stack((axis_x, axis_y))
    if abs(float(np.linalg.det(matrix))) < 1e-9:
        fail(f"{env}: singular HexToWorld calibration")
    predicted = origin + matrix @ np.asarray([1.0, 1.0])
    if not np.allclose(predicted, cal[(1, 1)], rtol=0, atol=1e-9):
        fail(f"{env}: HexToWorld calibration is not affine")
    return origin, matrix, np.linalg.inv(matrix)


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
    vo, vm, _ = matrix_for(van, env)
    eo, _, einv = matrix_for(exp, env)

    sy, sx = np.indices((vgh, vgw), dtype=np.float64)
    flat = np.vstack((sx.ravel(), sy.ravel()))
    world = vo[:, None] + vm @ flat
    target_float = einv @ (world * scale - eo[:, None])
    target = round_storage(target_float)
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

    rounded_world = eo[:, None] + np.linalg.inv(einv) @ target.astype(np.float64)
    residual = np.linalg.norm(rounded_world - world * scale, axis=0)
    return {
        "ex": ex,
        "ey": ey,
        "scale": scale,
        "sites": vgw * vgh,
        "expanded_unmapped": egw * egh - unique,
        "max_world_rounding_residual": float(residual.max(initial=0.0)),
        "p99_world_rounding_residual": float(np.percentile(residual, 99)) if residual.size else 0.0,
    }


def parse_control_csv(path: Path) -> list[dict[str, int]]:
    rows: list[dict[str, int]] = []
    with path.open("r", encoding="utf-8", newline="") as fh:
        for row in csv.DictReader(fh):
            rows.append({key: int(value) for key, value in row.items()})
    return rows


def validate_probe_control(out_dir: Path, tag: str, stamp: ProbeStamp,
                           grids: dict[str, np.ndarray]) -> dict[str, object]:
    meta = stamp.control
    required = {"node_wx", "node_wy", "diff", "pass_diff", "build_diff", "restore_diff"}
    if required - meta.keys():
        fail(f"property-{tag}-property.txt: missing surface control fields")
    rows = parse_control_csv(out_dir / f"property-{tag}-surface-property-control.csv")
    fresh, control = grids["surface:fresh"], grids["surface:control"]
    raw_diff = fresh != control
    csv_cells = {(row["sx"], row["sy"]) for row in rows}
    raw_y, raw_x = np.nonzero(raw_diff)
    raw_cells = set(zip(raw_x.tolist(), raw_y.tolist()))
    pass_rows = [row for row in rows if (row["fresh_bits"] ^ row["control_bits"]) & 1]
    build_rows = [row for row in rows if (row["fresh_bits"] ^ row["control_bits"]) & 2]
    checks = {
        "csv_is_complete": csv_cells == raw_cells,
        "diff_matches_stamp": len(rows) == int(meta["diff"]),
        "pass_diff_matches_stamp": len(pass_rows) == int(meta["pass_diff"]),
        "build_diff_matches_stamp": len(build_rows) == int(meta["build_diff"]),
        "both_properties_moved": bool(pass_rows) and bool(build_rows),
        "restore_diff_zero": int(meta["restore_diff"]) == 0,
    }
    return {
        "checks": checks,
        "ok": all(checks.values()),
        "rows": rows,
        "pass_rows": pass_rows,
        "build_rows": build_rows,
        "node_world": [float(meta["node_wx"]), float(meta["node_wy"])],
        "counts": {"all": len(rows), "passability": len(pass_rows), "buildability": len(build_rows)},
    }


def load_probe_grids(out_dir: Path, tag: str, stamp: ProbeStamp) -> dict[str, np.ndarray]:
    grids: dict[str, np.ndarray] = {}
    for env in ("surface", "underground"):
        gw, gh = dims(stamp, env)
        for stage in ("shipped", "fresh", "repeat"):
            path = out_dir / f"property-{tag}-{env}-property-{stage}.raw"
            grids[f"{env}:{stage}"] = load_property(path, gw, gh)
        if env == "surface":
            for stage in ("control", "restored"):
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
    origin, _, inverse = matrix_for(stamp, env)
    node_world = np.asarray(control["node_world"], dtype=np.float64)
    node_storage = inverse @ (node_world - origin)
    key = "pass_rows" if property_name == "passability" else "build_rows"
    rows = control[key]
    offsets = np.asarray([[row["sx"], row["sy"]] for row in rows], dtype=np.float64)
    offsets -= node_storage[None, :]
    affected = np.zeros((gh, gw), dtype=bool)
    ny, nx = np.nonzero(nodes)
    chunk = 250_000
    tile = float(stamp.maps[env]["tile"])
    for start in range(0, nx.size, chunk):
        stop = min(start + chunk, nx.size)
        world = np.vstack((nx[start:stop] * tile, ny[start:stop] * tile)).astype(np.float64)
        projected = inverse @ (world - origin[:, None])
        for offset in offsets:
            cell = round_storage(projected + offset[:, None])
            sx, sy = cell[0], cell[1]
            valid = (sx >= 0) & (sx < gw) & (sy >= 0) & (sy < gh)
            affected[sy[valid], sx[valid]] = True

    # Reapplying the derived footprint to the control node must reproduce every observed
    # changed property cell, exactly.  This is the live footprint anti-vacuity check.
    projected_control = inverse @ (node_world - origin)
    replay = round_storage(projected_control[:, None] + offsets.T)
    replay_cells = set(zip(replay[0].tolist(), replay[1].tolist()))
    observed = {(row["sx"], row["sy"]) for row in rows}
    detail = {
        "kernel_cells": len(rows),
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
    checks = {
        "inside_differences_are_classified_inside": (
            p_green["differences_inside"] == 1 and p_green["differences_outside"] == 0
            and b_green["differences_inside"] == 1 and b_green["differences_outside"] == 0),
        "outside_pass_injection_rejected": p_bad["differences_outside"] == 1,
        "outside_build_injection_rejected": b_bad["differences_outside"] == 1,
        "stale_in_mask_injection_rejected": (
            stale_report["vanilla_shipped_vs_fresh_inside"] == 1
            and not stale_report["inside_fresh"]),
    }
    return {"ok": all(checks.values()), "checks": checks,
            "injected_counts": {"outside_pass": p_bad["differences_outside"],
                                "outside_build": b_bad["differences_outside"],
                                "stale": stale_report["vanilla_shipped_vs_fresh_inside"]}}


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--vanilla", default="")
    ap.add_argument("--expanded", default="")
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
        payload = {"schema": "smr.propertycheck.selftest.v1", **self_test}
        rendered = json.dumps(payload, indent=2) + "\n"
        if args.out is not None:
            args.out.parent.mkdir(parents=True, exist_ok=True)
            args.out.write_text(rendered, encoding="utf-8")
        print(rendered, end="")
        return 0 if self_test["ok"] else 1
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
    vcontrol = validate_probe_control(out_dir, vtag, vstamp, vgrids)
    econtrol = validate_probe_control(out_dir, etag, estamp, egrids)
    normalised, zone_report = exact_normalised_nodes(pre, post, zone_stamp)
    pass_affected, pass_foot = footprint_mask(normalised, estamp, "surface", econtrol, "passability")
    build_affected, build_foot = footprint_mask(normalised, estamp, "surface", econtrol, "buildability")

    report: dict[str, object] = {
        "schema": "smr.propertycheck.v1",
        "vanilla": vtag,
        "expanded": etag,
        "gate_ok": False,
        "failed_checks": [],
        "self_test": self_test,
        "zones": zone_report,
        "probe_controls": {
            "vanilla": {key: value for key, value in vcontrol.items() if key not in {"rows", "pass_rows", "build_rows"}},
            "expanded": {key: value for key, value in econtrol.items() if key not in {"rows", "pass_rows", "build_rows"}},
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
        failed.append("live one-node probe control failed")
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
