"""Score the forced-impassability / pass-type probe (`passforced_probe.lua`) on a twin pair.

Answers, on the same source cells iterations 021-023 used around the underground Bottomless Pit:

1. Is the vanilla-only mask carried by ENGINE-SIDE FORCED impassability, or by a pass TYPE?
   Cross-tab each twin's `IsPassable` verdict against `IsForcedImpassable`, `GetPassType` and
   `IsTunnelPassable`.  If forced impassability is false wherever vanilla blocks, the hypothesis
   is dead and the mask lives in the pass grid's own bits.

2. Do the two twins even evaluate passability on the SAME geometry?  The pass system reports its
   own grid dimensions (`PassMapSize`) beside the map's world size, so the effective pass cell is
   `mapsize / passmap` world units.  Under an exact 4/3 similarity the expanded map's pass cell
   must be 4/3 of vanilla's; anything else means the two maps sample the same ground at different
   spacings, which is one-way in the direction that makes the finer map MORE passable.

3. Reproducibility: with `--mask <passmask-vanilla.csv> <passmask-expanded.csv>` the per-cell
   passability is compared against the iteration-023 lattices on the shared cells.

Usage:
  python passforcedcheck.py <passforced-vanilla.csv> <passforced-expanded.csv> <out.json>
                            [--map underground] [--mask <mask-van.csv> <mask-exp.csv>]
"""
import json
import sys
from pathlib import Path

SRC_HEIGHT_TILE = 100.0
XY_SCALE = 4.0 / 3.0


def load(path, want_map):
    meta, info, summary, calls, cells, grids, rows = {}, {}, {}, [], [], [], {}
    with open(path, "r", encoding="utf-8") as fh:
        for line in fh:
            line = line.rstrip("\n")
            if not line:
                continue
            if line.startswith("#meta,"):
                for kv in line[6:].split(","):
                    if "=" in kv:
                        k, v = kv.split("=", 1)
                        meta[k] = v
                continue
            if line.startswith("#passinfo,"):
                parts = line[10:].split(",")
                if parts[0] == want_map:
                    for kv in parts[1:]:
                        if "=" in kv:
                            k, v = kv.split("=", 1)
                            info[k] = v
                continue
            if line.startswith("#summary,"):
                parts = line[9:].split(",")
                if parts[0] == want_map:
                    for kv in parts[1:]:
                        if "=" in kv:
                            k, v = kv.split("=", 1)
                            summary[k] = v
                continue
            if line.startswith("#call,"):
                parts = line[6:].split(",")
                if parts[0] == want_map:
                    calls.append(",".join(parts[1:]))
                continue
            if line.startswith("#cell,"):
                p = line[6:].split(",")
                if p[0] == want_map:
                    cells.append({"sgx": int(p[1]), "sgy": int(p[2]), "kind": p[3],
                                  "h": int(p[6]), "p": int(p[7]), "forced": int(p[8]),
                                  "passtype": int(p[9]), "tunnel": int(p[10])})
                continue
            if line.startswith("#passgrid,"):
                parts = line[10:].split(",")
                if parts[0] == want_map:
                    grids.append(",".join(parts[1:]))
                continue
            if line.startswith("#"):
                continue
            p = line.split(",")
            if p[0] != want_map or len(p) < 11:
                continue
            rows[(int(p[1]), int(p[2]))] = {"x": int(p[3]), "y": int(p[4]), "h": int(p[5]),
                                            "p": int(p[6]), "forced": int(p[7]),
                                            "passtype": int(p[8]), "tunnel": int(p[9]),
                                            "d": int(p[10])}
    return {"meta": meta, "info": info, "summary": summary, "calls": calls, "cells": cells,
            "grids": grids, "rows": rows}


def load_mask(path, want_map):
    """Per-cell passability from the iteration-023 mask probe (`#cols ... h,p,p2,tt,d_src,...`)."""
    rows = {}
    with open(path, "r", encoding="utf-8") as fh:
        for line in fh:
            line = line.rstrip("\n")
            if not line or line.startswith("#"):
                continue
            p = line.split(",")
            if p[0] != want_map or len(p) < 9:
                continue
            rows[(int(p[1]), int(p[2]))] = int(p[6])
    return rows


def pass_cell_wu(info):
    try:
        mapsize = float(info["mapsize"].split("x")[0])
        passmap = float(info["passmap"].split("x")[0])
    except (KeyError, ValueError, ZeroDivisionError):
        return None
    if passmap <= 0:
        return None
    return mapsize / passmap


def main():
    args = [a for a in sys.argv[1:]]
    want_map = "underground"
    mask_paths = None
    out = []
    i = 0
    while i < len(args):
        if args[i] == "--map":
            want_map = args[i + 1]
            i += 2
        elif args[i] == "--mask":
            mask_paths = (args[i + 1], args[i + 2])
            i += 3
        else:
            out.append(args[i])
            i += 1
    if len(out) != 3:
        print(__doc__)
        return 2
    van_path, exp_path, out_path = out

    van = load(van_path, want_map)
    exp = load(exp_path, want_map)
    shared = sorted(set(van["rows"]) & set(exp["rows"]))
    if not shared:
        print("no shared source cells")
        return 1

    n = len(shared)
    stats = {"n": n, "van_blocked": 0, "exp_blocked": 0, "diff": 0, "false_to_true": 0,
             "true_to_false": 0, "van_forced": 0, "exp_forced": 0,
             "van_blocked_and_forced": 0, "exp_blocked_and_forced": 0,
             "van_blocked_not_forced": 0, "exp_blocked_not_forced": 0,
             "van_tunnel_pass": 0, "exp_tunnel_pass": 0}
    van_types, exp_types = {}, {}
    for key in shared:
        a, b = van["rows"][key], exp["rows"][key]
        if a["p"] == 0:
            stats["van_blocked"] += 1
            if a["forced"] == 1:
                stats["van_blocked_and_forced"] += 1
            else:
                stats["van_blocked_not_forced"] += 1
        if b["p"] == 0:
            stats["exp_blocked"] += 1
            if b["forced"] == 1:
                stats["exp_blocked_and_forced"] += 1
            else:
                stats["exp_blocked_not_forced"] += 1
        stats["van_forced"] += 1 if a["forced"] == 1 else 0
        stats["exp_forced"] += 1 if b["forced"] == 1 else 0
        stats["van_tunnel_pass"] += 1 if a["tunnel"] == 1 else 0
        stats["exp_tunnel_pass"] += 1 if b["tunnel"] == 1 else 0
        van_types[a["passtype"]] = van_types.get(a["passtype"], 0) + 1
        exp_types[b["passtype"]] = exp_types.get(b["passtype"], 0) + 1
        if a["p"] != b["p"]:
            stats["diff"] += 1
            if a["p"] == 0 and b["p"] == 1:
                stats["false_to_true"] += 1
            else:
                stats["true_to_false"] += 1

    # (2) pass-system geometry: effective pass cell, and what the similarity requires.
    van_cell = pass_cell_wu(van["info"])
    exp_cell = pass_cell_wu(exp["info"])
    geom = {"vanilla": van["info"], "expanded": exp["info"],
            "van_pass_cell_wu": van_cell, "exp_pass_cell_wu": exp_cell}
    if van_cell and exp_cell:
        geom["expected_exp_pass_cell_wu"] = van_cell * XY_SCALE
        geom["ratio_exp_over_van"] = exp_cell / van_cell
        geom["similarity_ratio"] = XY_SCALE
        geom["exp_pass_cell_in_source_wu"] = exp_cell / XY_SCALE
        geom["van_pass_cell_in_source_wu"] = van_cell
        geom["pass_cells_per_height_tile_van"] = SRC_HEIGHT_TILE / van_cell
        geom["pass_cells_per_source_height_tile_exp"] = SRC_HEIGHT_TILE / (exp_cell / XY_SCALE)
        geom["similarity_holds"] = abs(exp_cell - van_cell * XY_SCALE) < 1e-9

    # (1) verdict of the forced/type hypothesis, stated so it cannot be read as confirming.
    forced_carries = (stats["van_blocked_and_forced"] > 0
                      and stats["van_blocked_and_forced"] >= 0.5 * stats["van_blocked"])
    verdict = {
        "forced_impassability_explains_mask": bool(forced_carries),
        "van_blocked_cells_with_forced_flag": stats["van_blocked_and_forced"],
        "van_blocked_cells_without_forced_flag": stats["van_blocked_not_forced"],
        "pass_types_vanilla": {str(k): v for k, v in sorted(van_types.items())},
        "pass_types_expanded": {str(k): v for k, v in sorted(exp_types.items())},
        "pass_type_discriminates": len(van_types) > 1 or len(exp_types) > 1,
    }

    repro = None
    if mask_paths:
        mv = load_mask(mask_paths[0], want_map)
        me = load_mask(mask_paths[1], want_map)
        keys = sorted(set(mv) & set(me) & set(shared))
        agree_v = sum(1 for k in keys if mv[k] == van["rows"][k]["p"])
        agree_e = sum(1 for k in keys if me[k] == exp["rows"][k]["p"])
        repro = {"shared_with_mask_probe": len(keys), "vanilla_agree": agree_v,
                 "expanded_agree": agree_e}

    report = {
        "map": want_map,
        "vanilla_csv": str(Path(van_path).resolve()),
        "expanded_csv": str(Path(exp_path).resolve()),
        "stats": stats,
        "verdict": verdict,
        "pass_geometry": geom,
        "reproducibility_vs_mask_probe": repro,
        "forensic_cells": {"vanilla": van["cells"], "expanded": exp["cells"]},
        "resolved_call_shapes": {"vanilla": van["calls"], "expanded": exp["calls"]},
        "pass_grid_dump": {"vanilla": van["grids"], "expanded": exp["grids"]},
        "summary_lines": {"vanilla": van["summary"], "expanded": exp["summary"]},
    }
    Path(out_path).write_text(json.dumps(report, indent=2), encoding="utf-8")

    print(f"map={want_map} n={n} blocked van={stats['van_blocked']} exp={stats['exp_blocked']} "
          f"diff={stats['diff']} (f->t {stats['false_to_true']}, t->f {stats['true_to_false']})")
    print(f"forced: van={stats['van_forced']} exp={stats['exp_forced']}; "
          f"vanilla-blocked WITHOUT the forced flag: {stats['van_blocked_not_forced']}")
    print(f"pass types: van={verdict['pass_types_vanilla']} exp={verdict['pass_types_expanded']}")
    if van_cell and exp_cell:
        print(f"pass cell: van={van_cell:.4f} wu, exp={exp_cell:.4f} wu "
              f"(similarity requires {geom['expected_exp_pass_cell_wu']:.4f}); "
              f"ratio={geom['ratio_exp_over_van']:.4f} vs 4/3; "
              f"in SOURCE wu van={van_cell:.4f} exp={geom['exp_pass_cell_in_source_wu']:.4f}")
    if repro:
        print(f"vs iter-023 mask lattice: {repro['vanilla_agree']}/{repro['shared_with_mask_probe']} "
              f"vanilla, {repro['expanded_agree']}/{repro['shared_with_mask_probe']} expanded")
    print(f"FORCED-IMPASSABILITY EXPLAINS THE MASK: {verdict['forced_impassability_explains_mask']}")
    print(f"report -> {out_path}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
