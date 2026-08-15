"""Score contract step 5 - the declared HEIGHT RANGES - and the unit constant it rests on.

Step 5 says the map's final `to` comes from the MEASURED post-compression maximum while the
`from`/floor side keeps the affine, and the v423 lesson says the declared ranges must follow the
height transform BEFORE any buildable rebuild.  `buildcheck.py` (070) scored the FIT half of that
clause; nothing ever scored the DERIVATION rule, and the fit half was scored with a guessed unit
constant.

THE UNIT CONSTANT, measured here rather than assumed.  `Lua/BuildableGrid.lua:71-72` caps the
buildable grid at `range.to*guim` with the range in metres, so every number in this clause is
scaled by `guim`.  This tool DERIVES it per run from that run's own dumps, three ways that must
agree:

  1. the engine's own formula for the map extent, `CommonLua/Classes/MapData.lua:15`
     `local width = self.Width * guim`, against the extent the terrain actually has:
     guim = tiles * const.HeightTileSize / mapdata.Width   (both meta rows are in objects-<tag>.csv,
     tiles from the raw grid itself) - 6144 tiles * 100 wu / 6144 = 100 on a vanilla twin,
     8192 * 100 / 8192 = 100 on an expanded one;
  2. the hex pitch the same meta rows carry (hex_width 615 wu = 6.15 m at guim 100);
  3. the mod's own output: inverting the ranges the pipeline WROTE pins guim to a single integer.

Height grid units are world units (TerrainHeightScale = 1: `zseatcheck.py` subtracts terrain grid
values from object world Z and gets residuals of well under a wu), so metres = wu / guim.

Scored checks, per twin pair:
  1. DERIVATION: every declared range on the expanded twin equals the rule the payload implements
     (`sbm_terrain_copy.lua:582-603`) applied to the vanilla twin's own declared range -
     from = floor(from0*mul/div + add/guim), to = ceil(to0*mul/div + add/guim), or
     to = ceil(measured_max*hscale/guim) where a measured maximum exists.
  2. BRANCH COVERAGE: reports how many scored rows exercise the measured-max branch.  It is a
     contract requirement, so a run of zeroes is a stated LIMIT, not a green.
  3. FIT, in the corrected units: cells of the final height grid above the declared cap / below the
     declared floor, on BOTH twins.  The criterion is EQUIVALENCE, not zero: a stock vanilla map
     already carries terrain above its own declared cap, so "0 above cap" is not what step 5 asks
     for.  What it asks for is that the transform does not push MORE terrain out of the range than
     vanilla had (the v423 failure mode), plus the expanded cap being the round-outward image of
     the vanilla cap.
  4. CONTROLS: the derivation re-scored with guim = 1000 and with the stamped add moved by one
     metre must both FAIL, or the checks above are not sensitive to what they claim to measure.

Usage:
  python rangecheck.py --case label=P1,vanilla=t77a,expanded=t77x[,fit=false] ... --out <json>
Exit 0 when every scored check passes and both controls fire; 1 otherwise.
"""

from __future__ import annotations

import argparse
import json
import math
import sys
from pathlib import Path

import numpy as np

HERE = Path(__file__).resolve().parent
DEFAULT_OUT_DIR = HERE / "out"
# const.TerrainHeightScale: grid unit -> world unit.  Measured 1 (see the header).
HEIGHT_SCALE = 1
CONTROL_GUIM = 1000


def parse_zones(path: Path) -> dict:
    """map/ranges rows of a height_dump_probe stamp."""
    out = {"maps": {}, "ranges": {}}
    for line in path.read_text(encoding="utf-8").splitlines():
        parts = line.split(",")
        if len(parts) < 2:
            continue
        kind, env = parts[0], parts[1]
        fields = dict(p.split("=", 1) for p in parts[2:] if "=" in p)
        if kind == "map":
            out["maps"][env] = fields
        elif kind == "ranges":
            out["ranges"][env] = fields
    return out


def parse_meta(path: Path) -> dict:
    """#meta rows of an object dump, per environment."""
    meta = {}
    if not path.exists():
        return meta
    with path.open("r", encoding="utf-8", errors="replace") as fh:
        for line in fh:
            if not line.startswith("#"):
                break
            parts = line.rstrip("\n").split(",")
            if len(parts) >= 4 and parts[0] == "#meta":
                meta.setdefault(parts[1], {})[parts[2]] = ",".join(parts[3:])
    return meta


def grid_tiles(out_dir: Path, tag: str, env: str) -> int | None:
    raw = out_dir / f"height-{tag}-{env}.raw"
    if not raw.exists():
        return None
    cells = raw.stat().st_size // 2
    side = int(round(math.sqrt(cells)))
    return side if side * side == cells else None


def derive_guim(out_dir: Path, tag: str) -> dict:
    """guim in wu/m, from the run's own dumps.  Never a literal."""
    meta = parse_meta(out_dir / f"objects-{tag}.csv")
    rec = {"tag": tag, "sources": {}}
    for env in ("surface", "underground"):
        m = meta.get(env, {})
        width = m.get("mapdata_width")
        tile = m.get("height_tile_size")
        tiles = grid_tiles(out_dir, tag, env)
        if not width or not tile or not tiles:
            continue
        try:
            width_m, tile_wu = int(width), int(tile)
        except ValueError:
            continue
        if width_m <= 0:
            continue
        extent_wu = tiles * tile_wu
        if extent_wu % width_m:
            continue
        rec["sources"][env] = {
            "mapdata_width_m": width_m, "height_tile_size_wu": tile_wu,
            "grid_tiles": tiles, "extent_wu": extent_wu, "guim": extent_wu // width_m,
            "hex_width_wu": m.get("hex_width"),
        }
    vals = sorted({s["guim"] for s in rec["sources"].values()})
    rec["guim"] = vals[0] if len(vals) == 1 else None
    rec["agree"] = len(vals) == 1
    return rec


def parse_range(text: str | None) -> tuple[int, int] | None:
    if not text or text == "nil" or ".." not in text:
        return None
    a, b = text.split("..", 1)
    try:
        return int(a), int(b)
    except ValueError:
        return None


def predict(src: tuple[int, int], mul: int, div: int, add: int, guim: int,
            measured_max: int | None) -> tuple[int, int]:
    """The payload's own rule, `sbm_terrain_copy.lua` ScaleHeightRanges (float maths, as there)."""
    frm = math.floor((src[0] * mul + 0.0) / div + (add + 0.0) / guim)
    if measured_max:
        to = math.ceil((measured_max * HEIGHT_SCALE + 0.0) / guim)
    else:
        to = math.ceil((src[1] * mul + 0.0) / div + (add + 0.0) / guim)
    if to <= frm:
        to = frm + 1
    return frm, to


def int_or_none(fields: dict, key: str) -> int | None:
    v = fields.get(key)
    if v is None or v == "nil":
        return None
    try:
        return int(v)
    except ValueError:
        return None


def fit(out_dir: Path, tag: str, env: str, declared: tuple[int, int] | None, guim: int) -> dict:
    raw_path = out_dir / f"height-{tag}-{env}.raw"
    if not raw_path.exists():
        return {"scored": False, "reason": "no raw height dump"}
    raw = np.fromfile(raw_path, dtype="<u2")
    out = {"scored": True, "cells": int(raw.size),
           "grid_min_wu": int(raw.min()), "grid_max_wu": int(raw.max())}
    if declared is None:
        out.update({"applicable": False,
                    "note": "no declared visible_height_range: the cap falls back to UnbuildableZ"})
        return out
    frm_wu, to_wu = declared[0] * guim, declared[1] * guim
    above = int((raw.astype(np.int64) > to_wu).sum())
    below = int((raw.astype(np.int64) < frm_wu).sum())
    out.update({
        "applicable": True, "declared_m": f"{declared[0]}..{declared[1]}",
        "cap_wu": to_wu, "floor_wu": frm_wu,
        "cells_above_cap": above, "cells_below_floor": below,
        "fraction_above_cap": round(above / raw.size, 6),
        "fraction_below_floor": round(below / raw.size, 6),
        "cap_margin_over_grid_min_wu": to_wu - int(raw.min()),
    })
    return out


def score_case(out_dir: Path, label: str, van: str, exp: str, do_fit: bool) -> dict:
    case = {"label": label, "vanilla_tag": van, "expanded_tag": exp,
            "rows": [], "failures": [], "measured_max_rows": 0, "affine_rows": 0}
    van_z = parse_zones(out_dir / f"height-{van}-zones.txt")
    exp_z = parse_zones(out_dir / f"height-{exp}-zones.txt")
    guim_van, guim_exp = derive_guim(out_dir, van), derive_guim(out_dir, exp)
    case["guim"] = {"vanilla": guim_van, "expanded": guim_exp}
    guim = guim_exp.get("guim") or guim_van.get("guim")
    if not guim:
        case["failures"].append("guim could not be derived from either twin's dumps")
        return case
    if guim_van.get("guim") and guim_exp.get("guim") and guim_van["guim"] != guim_exp["guim"]:
        case["failures"].append("the twins derive different guim values")
    case["guim_used"] = guim

    for env in ("surface", "underground"):
        stamp = exp_z["maps"].get(env, {})
        mul, div = int_or_none(stamp, "zmul"), int_or_none(stamp, "zdiv")
        add = int_or_none(stamp, "zadd") or 0
        measured_max = int_or_none(stamp, "measured_max")
        src_rows = van_z["ranges"].get(env, {})
        got_rows = exp_z["ranges"].get(env, {})
        for key in ("visible", "playable"):
            src = parse_range(src_rows.get(key))
            got = parse_range(got_rows.get(key))
            row = {"env": env, "range": key, "vanilla_m": src_rows.get(key),
                   "expanded_m": got_rows.get(key), "measured_max": measured_max}
            if src is None:
                row["scored"] = False
                row["reason"] = "the vanilla twin declares no such range"
                if got is not None:
                    case["failures"].append(
                        f"{env}/{key}: the expanded twin declares {got} where vanilla declares none")
                case["rows"].append(row)
                continue
            if not mul or not div:
                row["scored"] = False
                row["reason"] = "the expanded twin carries no Z stamp for this map"
                case["rows"].append(row)
                continue
            want = predict(src, mul, div, add, guim, measured_max)
            row.update({"scored": True, "stamp": {"zmul": mul, "zdiv": div, "zadd": add},
                        "predicted": list(want), "actual": list(got) if got else None,
                        "branch": "measured_max" if measured_max else "affine",
                        "match": got is not None and tuple(got) == want})
            if measured_max:
                case["measured_max_rows"] += 1
            else:
                case["affine_rows"] += 1
            if not row["match"]:
                case["failures"].append(
                    f"{env}/{key}: predicted {want}, dumped {got}")
            # Controls: the same prediction with a wrong unit constant and a wrong shift.
            row["control_guim1000"] = list(predict(src, mul, div, add, CONTROL_GUIM, measured_max))
            row["control_add_plus_1m"] = list(
                predict(src, mul, div, add + guim, guim, measured_max))
            case["rows"].append(row)

        if do_fit:
            src = parse_range(van_z["ranges"].get(env, {}).get("visible"))
            got = parse_range(exp_z["ranges"].get(env, {}).get("visible"))
            f_van = fit(out_dir, van, env, src, guim)
            f_exp = fit(out_dir, exp, env, got, guim)
            entry = {"env": env, "vanilla": f_van, "expanded": f_exp}
            if f_van.get("applicable") and f_exp.get("applicable"):
                # The image of the vanilla cap under the height transform, in wu, before the
                # round-outward to whole metres - the expanded cap must sit on it, at most one
                # metre above (ceil) and never below (that would evict terrain vanilla kept).
                img = (src[1] * mul) / div * guim + add if mul and div else None
                entry["vanilla_cap_image_wu"] = round(img, 3) if img is not None else None
                entry["expanded_cap_minus_image_wu"] = (
                    round(f_exp["cap_wu"] - img, 3) if img is not None else None)
                entry["above_cap_fraction_delta"] = round(
                    f_exp["fraction_above_cap"] - f_van["fraction_above_cap"], 6)
                if img is not None and not (0 <= f_exp["cap_wu"] - img < guim):
                    case["failures"].append(
                        f"{env}: expanded cap {f_exp['cap_wu']} wu is not the round-outward image "
                        f"of the vanilla cap ({img:.1f} wu)")
                if entry["above_cap_fraction_delta"] > 1e-3:
                    case["failures"].append(
                        f"{env}: the transform pushed {entry['above_cap_fraction_delta']:.6f} more "
                        "of the map above the declared cap than vanilla had (v423 failure mode)")
                if f_exp["cells_below_floor"] > f_van["cells_below_floor"]:
                    case["failures"].append(
                        f"{env}: {f_exp['cells_below_floor']} cells below the declared floor "
                        f"against vanilla's {f_van['cells_below_floor']}")
            case.setdefault("fit", []).append(entry)
    return case


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--case", action="append", required=True,
                    help="label=..,vanilla=<tag>,expanded=<tag>[,fit=false]")
    ap.add_argument("--out-dir", default=str(DEFAULT_OUT_DIR))
    ap.add_argument("--out", required=True)
    args = ap.parse_args()

    out_dir = Path(args.out_dir)
    report = {"tool": "rangecheck.py", "height_scale": HEIGHT_SCALE, "cases": [],
              "failed_checks": [], "controls": {}}
    for spec in args.case:
        fields = dict(kv.split("=", 1) for kv in spec.split(",") if "=" in kv)
        case = score_case(out_dir, fields.get("label", spec), fields["vanilla"], fields["expanded"],
                          fields.get("fit", "true") != "false")
        report["cases"].append(case)
        for f in case["failures"]:
            report["failed_checks"].append(f"{case['label']}: {f}")

    scored = [r for c in report["cases"] for r in c["rows"] if r.get("scored")]
    report["scored_rows"] = len(scored)
    report["matching_rows"] = sum(1 for r in scored if r["match"])
    report["measured_max_rows"] = sum(c["measured_max_rows"] for c in report["cases"])
    report["affine_rows"] = sum(c["affine_rows"] for c in report["cases"])
    report["guim_values"] = sorted({c["guim_used"] for c in report["cases"] if c.get("guim_used")})

    # Controls: both wrong-parameter predictions must move at least one scored row.
    ctl_guim = sum(1 for r in scored if r["control_guim1000"] != r["predicted"])
    ctl_add = sum(1 for r in scored if r["control_add_plus_1m"] != r["predicted"])
    report["controls"] = {"rows_moved_by_guim_1000": ctl_guim,
                          "rows_moved_by_add_plus_one_metre": ctl_add,
                          "scored_rows": len(scored)}
    if not scored:
        report["failed_checks"].append("no scored rows - vacuous run")
    if scored and ctl_guim == 0:
        report["failed_checks"].append("control: guim = 1000 changes no prediction")
    if scored and ctl_add == 0:
        report["failed_checks"].append("control: a one-metre shift changes no prediction")
    if report["measured_max_rows"] == 0:
        report["measured_max_branch_limit"] = (
            "LIMIT: no scored row exercises step 5's measured-max branch - every map measured "
            "declares its ranges on the underground only, where the transform is a uniform 4/3 "
            "with no massifs and no measured maximum is stamped.  The surface, the only map with "
            "compression, declares no height range at all.")

    report["gate_ok"] = not report["failed_checks"]
    Path(args.out).write_text(json.dumps(report, indent=2), encoding="utf-8")
    print(json.dumps({k: report[k] for k in
                      ("gate_ok", "failed_checks", "scored_rows", "matching_rows",
                       "measured_max_rows", "affine_rows", "guim_values", "controls")}, indent=2))
    return 0 if report["gate_ok"] else 1


if __name__ == "__main__":
    sys.exit(main())
