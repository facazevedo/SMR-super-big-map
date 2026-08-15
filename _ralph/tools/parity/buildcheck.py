"""Score contract step 6's BUILDABLE clause, and the ceiling collision this task creates.

Step 6 says "rebuild passability and buildable from the final grid".  The passability half is
scored by `passrealcheck.py`; the buildable half never was.  It matters more here than it looks:

  * `Lua/BuildableGrid.lua:23-27` - the engine's own "this hex cannot be built on" marker is
    `UnbuildableZ = 2^16 - 1 = 65535`, stored in a U16 grid, i.e. the sentinel is a VALUE in the
    same range as a real buildable Z in world units;
  * `:72` - with no declared `visible_height_range` (every map measured in this workspace dumps
    `visible=nil` on the surface) the height cap falls back to that same 65535 wu;
  * this task normalizes every massif so its peak lands on EXACTLY 65535 wu.

So the transform puts terrain exactly on the sentinel value for the first time.  This tool reads
what the engine actually produced.

Inputs are the `buildable_probe.lua` dumps of a twin pair:
    height-<tag>-buildable.txt                  stamp rows (dims, sentinel, summit rows)
    height-<tag>-<env>-buildable.txt            the z_grid the pipeline shipped
    height-<tag>-<env>-buildable-rebuild.txt    a fresh rebuild over the FINAL terrain

Scored checks
  1. FRESH (step 6): the EXPANDED twin's shipped grid == a fresh rebuild over the final terrain,
     cell for cell, on both its maps. The vanilla twin's own figure is measured too, as the
     baseline this is read against - it is not gated, because step 6 is a statement about what
     this task ships, not about the stock game.
  2. Sensitivity control for check 1: the same comparator on two grids that must differ (the
     surface vs the underground shipped grid, identical dimensions), plus a constructed one-cell
     perturbation of the rebuild copy.  Both must report a nonzero difference.
  3. Anti-vacuity: each grid holds both sentinel and non-sentinel hexes.
  4. RANGE FIT (contract step 5, the clause that gates this grid): `BuildableGrid:Build` caps at
     `map_max_height = range.to*guim` and floors at `range.from*guim` (`:71-72`), so every cell of
     the FINAL height grid must lie inside the map's declared `visible_height_range` or the hexes
     above it go unbuildable - the v423 failure mode. Scored per map from the dumped height grid
     against the `ranges,` row of the same run's zone stamp; a map that declares no range (every
     surface measured here) has no cap and is reported N/A, not green.
  5. Ceiling exposure, reported per twin: the largest NON-sentinel buildable Z, how many hexes
     sit within 1000 wu of the sentinel, and the per-massif summit rows (the hex holding each
     peak cell and its 5x5 hex neighbourhood) with the vanilla twin's matching window.

Height grid units are world units on both twins (measured: the underground's vanilla flatten floor
is 10,000 in the grid and its buildable Z reads 10,000 wu), and declared ranges are in metres with
guim = 1000 wu/m.

Hex windows are matched across twins by scaling storage coordinates by src/dest (the hex size is
identical on both maps; only the map extent differs), so the match is exact up to +-1 hex - which
is why a 5x5 window, not a single hex, is reported.

Usage:
  python buildcheck.py --vanilla <tag> --expanded <tag> [--out-dir <dir>] --out <json>
Exit 0 when every scored check passes and both controls fire; 1 otherwise.
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

import numpy as np

HERE = Path(__file__).resolve().parent
DEFAULT_OUT_DIR = HERE / "out"
SENTINEL = 65535


def load_grid(path: Path) -> np.ndarray:
    with path.open("r", encoding="utf-8") as fh:
        head = fh.readline()
        if not head.startswith("#"):
            raise SystemExit(f"{path}: missing header row")
        rows = [np.fromstring(line, dtype=np.int64, sep=",") for line in fh if line.strip()]
    grid = np.vstack(rows)
    meta = dict(kv.split("=", 1) for kv in head.lstrip("#").strip().split(","))
    gw, gh = int(meta["gw"]), int(meta["gh"])
    if grid.shape != (gh, gw):
        raise SystemExit(f"{path}: header says {gw}x{gh}, read {grid.shape[1]}x{grid.shape[0]}")
    return grid


def parse_stamp(path: Path) -> dict:
    out = {"maps": {}, "summits": [], "rebuild": {}}
    for line in path.read_text(encoding="utf-8").splitlines():
        parts = line.split(",")
        if not parts:
            continue
        kind, tag = parts[0], parts[1] if len(parts) > 1 else ""
        fields = dict(p.split("=", 1) for p in parts[2:] if "=" in p)
        if kind == "buildable":
            out["maps"][tag] = fields
        elif kind == "rebuild":
            out["rebuild"][tag] = fields
        elif kind == "summit":
            fields["env"] = tag
            fields["index"] = int(parts[2])
            out["summits"].append(fields)
    return out


GUIM = 1000


def range_fit(out_dir: Path, tag: str, env: str) -> dict:
    """Does the final height grid fit inside the range the buildable grid is capped by?"""
    stamp = out_dir / f"height-{tag}-zones.txt"
    declared = None
    for line in stamp.read_text(encoding="utf-8").splitlines():
        parts = line.split(",")
        if len(parts) >= 3 and parts[0] == "ranges" and parts[1] == env:
            fields = dict(p.split("=", 1) for p in parts[2:] if "=" in p)
            declared = fields.get("visible")
            break
    raw = np.fromfile(out_dir / f"height-{tag}-{env}.raw", dtype="<u2")
    lo, hi = int(raw.min()), int(raw.max())
    out = {"declared_visible_range_m": declared, "grid_min_wu": lo, "grid_max_wu": hi,
           "cells": int(raw.size)}
    if not declared or declared == "nil" or ".." not in declared:
        out["applicable"] = False
        out["note"] = "no declared visible_height_range: map_max_height falls back to UnbuildableZ"
        return out
    a, b = declared.split("..")
    frm, to = int(a) * GUIM, int(b) * GUIM
    out.update({
        "applicable": True,
        "cap_wu": to,
        "floor_wu": frm,
        "cells_above_cap": int((raw > to).sum()),
        "cells_below_floor": int((raw < frm).sum()),
        "headroom_wu": to - hi,
    })
    return out


def grid_stats(grid: np.ndarray) -> dict:
    sent = int((grid == SENTINEL).sum())
    total = int(grid.size)
    free = grid[grid != SENTINEL]
    return {
        "hexes": total,
        "sentinel": sent,
        "buildable": total - sent,
        "buildable_fraction": round((total - sent) / total, 6),
        "max_non_sentinel_z": int(free.max()) if free.size else None,
        "within_1000_of_sentinel": int(((grid >= SENTINEL - 1000) & (grid != SENTINEL)).sum()),
        "within_100_of_sentinel": int(((grid >= SENTINEL - 100) & (grid != SENTINEL)).sum()),
        "within_10_of_sentinel": int(((grid >= SENTINEL - 10) & (grid != SENTINEL)).sum()),
    }


def window(grid: np.ndarray, sx: int, sy: int, rad: int) -> dict:
    y0, y1 = max(0, sy - rad), min(grid.shape[0], sy + rad + 1)
    x0, x1 = max(0, sx - rad), min(grid.shape[1], sx + rad + 1)
    if y0 >= y1 or x0 >= x1:
        return {"n": 0, "sentinel": 0, "max_non_sentinel_z": None, "in_bounds": False}
    w = grid[y0:y1, x0:x1]
    free = w[w != SENTINEL]
    return {
        "n": int(w.size),
        "sentinel": int((w == SENTINEL).sum()),
        "max_non_sentinel_z": int(free.max()) if free.size else None,
        "in_bounds": True,
    }


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--vanilla", required=True, help="vanilla twin tag")
    ap.add_argument("--expanded", required=True, help="expanded twin tag")
    ap.add_argument("--out-dir", default=str(DEFAULT_OUT_DIR))
    ap.add_argument("--out", required=True, help="verdict JSON")
    ap.add_argument("--window", type=int, default=2, help="half-size of the matched hex window")
    args = ap.parse_args()

    out_dir = Path(args.out_dir)
    report = {
        "tool": "buildcheck.py",
        "vanilla_tag": args.vanilla,
        "expanded_tag": args.expanded,
        "sentinel": SENTINEL,
        "maps": {},
        "summits": [],
        "controls": {},
        "failed_checks": [],
    }
    fail = report["failed_checks"].append

    grids = {}
    for role, tag in (("vanilla", args.vanilla), ("expanded", args.expanded)):
        stamp = parse_stamp(out_dir / f"height-{tag}-buildable.txt")
        report[f"{role}_stamp"] = {"maps": stamp["maps"], "rebuild": stamp["rebuild"]}
        for env in ("surface", "underground"):
            shipped = load_grid(out_dir / f"height-{tag}-{env}-buildable.txt")
            rebuilt = load_grid(out_dir / f"height-{tag}-{env}-buildable-rebuild.txt")
            grids[(role, env)] = shipped
            key = f"{role}/{env}"
            if shipped.shape != rebuilt.shape:
                fail(f"{key}: shipped and rebuild dimensions differ")
                continue
            diff = int((shipped != rebuilt).sum())
            st = grid_stats(shipped)
            st["stale_cells_vs_fresh_rebuild"] = diff
            st["rebuild_ms"] = stamp["rebuild"].get(env, {}).get("ms")
            st["range_fit"] = range_fit(out_dir, tag, env)
            report["maps"][key] = st
            rf = st["range_fit"]
            if rf.get("applicable") and (rf["cells_above_cap"] or rf["cells_below_floor"]):
                fail(f"{key}: {rf['cells_above_cap']} cells above the declared cap and "
                     f"{rf['cells_below_floor']} below its floor - those hexes go unbuildable")
            # The gate is the MOD's pipeline: step 6 is a statement about what this task ships.
            # The vanilla twin's own number is the baseline it is read against - and where it is
            # nonzero it is also the sensitivity control this comparator needs, found in the wild
            # rather than constructed.
            if diff != 0 and role == "expanded":
                fail(f"{key}: {diff} hexes differ from a fresh rebuild (stale buildable grid)")
            if st["sentinel"] == 0 or st["buildable"] == 0:
                fail(f"{key}: vacuous grid - {st['sentinel']} sentinel, {st['buildable']} buildable")
        if role == "expanded":
            report["expanded_summits_raw"] = stamp["summits"]

    # Control A: the comparator on two grids that MUST differ (same dims, different map).
    for role in ("vanilla", "expanded"):
        a, b = grids[(role, "surface")], grids[(role, "underground")]
        if a.shape == b.shape:
            d = int((a != b).sum())
            report["controls"][f"{role}_surface_vs_underground_diff"] = d
            if d == 0:
                fail(f"{role}: control comparison of two different maps reports 0 differences")
        else:
            report["controls"][f"{role}_surface_vs_underground_diff"] = "dims differ"

    # Control B: a constructed one-hex perturbation must be caught by the same comparator.
    probe = grids[("expanded", "surface")].copy()
    probe[probe.shape[0] // 2, probe.shape[1] // 2] += 1
    ctl = int((probe != grids[("expanded", "surface")]).sum())
    report["controls"]["constructed_one_hex_perturbation"] = ctl
    if ctl != 1:
        fail(f"constructed control reports {ctl} differing hexes, expected 1")

    # The summits: the hex holding each massif peak, and the vanilla twin's matching window.
    van_s, exp_s = grids[("vanilla", "surface")], grids[("expanded", "surface")]
    ratio = van_s.shape[1] / exp_s.shape[1]
    report["storage_scale_vanilla_over_expanded"] = round(ratio, 6)
    sent_summits = 0
    for s in report.get("expanded_summits_raw", []):
        if s.get("env") != "surface":
            continue
        q, r = int(s["q"]), int(s["r"])
        sx, sy = q + r // 2, r
        vx, vy = int(round(sx * ratio)), int(round(sy * ratio))
        row = {
            "massif": s["index"],
            "peak_src": int(s["peak"]),
            "peak_img": int(s["peak_img"]),
            "terrain_height_wu": int(s["height"]),
            "expanded_build_z": int(s["build_z"]),
            "expanded_sentinel": s["sentinel"] == "true",
            "expanded_disc": {"n": int(s["disc_n"]), "sentinel": int(s["disc_sentinel"])},
            "expanded_window": window(exp_s, sx, sy, args.window),
            "vanilla_window": window(van_s, vx, vy, args.window),
        }
        sent_summits += 1 if row["expanded_sentinel"] else 0
        report["summits"].append(row)
    report["summit_summary"] = {
        "massifs": len(report["summits"]),
        "peak_hex_sentinel": sent_summits,
        "peak_hex_buildable": len(report["summits"]) - sent_summits,
        "vanilla_windows_fully_sentinel": sum(
            1 for s in report["summits"]
            if s["vanilla_window"]["n"] and s["vanilla_window"]["sentinel"] == s["vanilla_window"]["n"]),
        "expanded_windows_fully_sentinel": sum(
            1 for s in report["summits"]
            if s["expanded_window"]["n"] and s["expanded_window"]["sentinel"] == s["expanded_window"]["n"]),
    }
    report.pop("expanded_summits_raw", None)

    # A buildable Z is stored in the same U16 grid as the sentinel, so a hex whose flatten Z
    # computed to exactly 65535 would be indistinguishable from "unbuildable". Report how close
    # the measurement actually gets on each twin instead of arguing about it.
    report["ceiling_headroom"] = {
        role: {
            "max_non_sentinel_z": report["maps"][f"{role}/surface"]["max_non_sentinel_z"],
            "headroom_wu": SENTINEL - report["maps"][f"{role}/surface"]["max_non_sentinel_z"],
            "hexes_within_1000": report["maps"][f"{role}/surface"]["within_1000_of_sentinel"],
        }
        for role in ("vanilla", "expanded")
        if f"{role}/surface" in report["maps"]
    }
    report["gate_ok"] = not report["failed_checks"]
    Path(args.out).write_text(json.dumps(report, indent=2), encoding="utf-8")
    print(json.dumps({k: report[k] for k in ("gate_ok", "failed_checks", "maps", "controls",
                                             "ceiling_headroom", "summit_summary")}, indent=2))
    return 0 if report["gate_ok"] else 1


if __name__ == "__main__":
    sys.exit(main())
