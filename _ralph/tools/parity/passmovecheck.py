"""Scorer for the passability POSE-ABLATION probe (`passmove_probe.lua`, item C1f).

Answers one question with numbers: when the `BottomlessPit` wonder is MOVED to fresh ground and
passability is rebuilt over the whole map, does its imprint follow it?

    vanilla   the imprint must LEAVE the origin window and APPEAR at the destination window -
              the positive control that this ladder can see a moving imprint at all
    expanded  an imprint appearing at the destination means the clone rasterises fine and only its
              pose (or local state at the pit) is wrong; no imprint at either pose means the
              INSTANCE is inert, whatever its position

Both maps also carry two controls that must hold or the reading is void: s1 rebuilds without
touching the object (must reproduce s0 in both windows) and s3 restores the baseline pose (must
return both windows to s1).

    python passmovecheck.py <vanilla_tag> <expanded_tag> <out.json>
    e.g. python passmovecheck.py t16a t16x ..\\..\\runs\\full-z-parity\\artifacts\\pass\\x.json

Exit 0 when both runs parsed and every control held; 1 otherwise.
"""
import json
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
OUT = HERE / "out"

STAGES = {
    0: "baseline",
    1: "rebuild_only (control)",
    2: "object_moved_to_destination",
    3: "pose_restored (control)",
}
WINDOWS = ("origin", "dest")


def parse(tag):
    path = OUT / f"passmove-{tag}.csv"
    if not path.exists():
        raise SystemExit(f"missing lattice: {path}")
    meta, obj_rows, steps, acts, hashes = {}, [], [], [], {}
    summary = {}
    cells = {w: {} for w in WINDOWS}
    for line in path.read_text(encoding="utf-8").splitlines():
        if not line:
            continue
        if line.startswith("#"):
            parts = line.split(",")
            kind = parts[0]
            if kind == "#meta":
                for kv in parts[1:]:
                    if "=" in kv:
                        k, v = kv.split("=", 1)
                        meta[k] = v
            elif kind in ("#centre", "#dest"):
                meta[kind[1:]] = line
            elif kind == "#obj":
                row = {"map": parts[1], "when": parts[2], "class": parts[3]}
                for kv in parts[4:]:
                    if "=" in kv:
                        k, v = kv.split("=", 1)
                        row[k] = v
                obj_rows.append(row)
            elif kind == "#act":
                acts.append(line)
            elif kind == "#step":
                steps.append(line)
            elif kind == "#hash":
                for kv in parts[2:]:
                    if "=" in kv:
                        k, v = kv.split("=", 1)
                        hashes[k] = v
            elif kind == "#summary":
                win = parts[2]
                for kv in parts[3:]:
                    if "=" in kv:
                        k, v = kv.split("=", 1)
                        summary[f"{win}_{k}"] = v
            elif kind == "#skip":
                meta.setdefault("skips", []).append(line)
            continue
        if line.startswith("map,"):
            continue
        f = line.split(",")
        # map,window,sgx,sgy,x,y,h,p0,p1,p2,p3,d_src,inplay
        if len(f) < 13 or f[0] != "underground":
            continue
        win = f[1]
        if win not in cells:
            continue
        cells[win][(int(f[2]), int(f[3]))] = {
            "h": int(f[6]),
            "p": [int(f[7 + k]) for k in range(4)],
            "d": int(f[11]),
            "inplay": int(f[12]),
        }
    return {"meta": meta, "objects": obj_rows, "acts": acts, "steps": steps,
            "summary": summary, "hashes": hashes, "cells": cells}


def window_table(cells):
    n = len(cells)
    rows = []
    for k in range(4):
        blocked = sum(1 for c in cells.values() if c["p"][k] == 0)
        changed = sum(1 for c in cells.values() if c["p"][k] != c["p"][0])
        rows.append({
            "stage": k,
            "what": STAGES[k],
            "blocked": blocked,
            "blocked_pct": round(100.0 * blocked / n, 3) if n else None,
            "changed_vs_baseline": changed,
        })
    return rows


def main():
    if len(sys.argv) < 4:
        raise SystemExit(__doc__)
    van_tag, exp_tag, out_path = sys.argv[1], sys.argv[2], Path(sys.argv[3])
    van, exp = parse(van_tag), parse(exp_tag)

    report = {"vanilla_tag": van_tag, "expanded_tag": exp_tag}
    problems = []
    for name, run in (("vanilla", van), ("expanded", exp)):
        tables = {w: window_table(run["cells"][w]) for w in WINDOWS}
        # Controls.  s1 touches nothing, s3 restores the pose: both must reproduce the state the
        # object was in, in BOTH windows.
        for w in WINDOWS:
            if tables[w][1]["changed_vs_baseline"] != 0:
                problems.append(f"{name}/{w}: rebuild-only control changed "
                                f"{tables[w][1]['changed_vs_baseline']} cells")
            restore_delta = sum(1 for c in run["cells"][w].values() if c["p"][3] != c["p"][1])
            if restore_delta != 0:
                problems.append(f"{name}/{w}: pose-restore control differs from the rebuild-only "
                                f"state on {restore_delta} cells")
        if run["hashes"].get("h3") != run["hashes"].get("h1"):
            problems.append(f"{name}: whole-map passability hash did not return to its "
                            f"rebuild-only value after the pose restore "
                            f"(h1={run['hashes'].get('h1')} h3={run['hashes'].get('h3')})")
        obj = {o["when"]: o for o in run["objects"]}
        moved = None
        if "s0" in obj and "move_to_dest" in obj:
            moved = (obj["s0"].get("x") != obj["move_to_dest"].get("x")
                     or obj["s0"].get("y") != obj["move_to_dest"].get("y"))
            if not moved:
                problems.append(f"{name}: the object did not actually move")
        report[name] = {
            "samples_per_window": {w: len(run["cells"][w]) for w in WINDOWS},
            "centre": run["meta"].get("centre"),
            "dest": run["meta"].get("dest"),
            "object_pose": {k: {kk: obj[k].get(kk) for kk in
                                ("x", "y", "vz", "valid_z", "scale", "ef_grids", "obb", "obbmin")}
                            for k in sorted(obj)},
            "object_moved": moved,
            "windows": tables,
            "hashes": run["hashes"],
            "imprint": {
                "origin_cells_lost_when_moved_away":
                    tables["origin"][0]["blocked"] - tables["origin"][2]["blocked"],
                "dest_cells_gained_when_moved_in":
                    tables["dest"][2]["blocked"] - tables["dest"][0]["blocked"],
                "cells_changed_by_the_move":
                    tables["origin"][2]["changed_vs_baseline"]
                    + tables["dest"][2]["changed_vs_baseline"],
                "whole_map_hash_moved_with_the_object":
                    run["hashes"].get("h2") != run["hashes"].get("h1"),
            },
            "steps": run["steps"],
            "acts": run["acts"],
        }

    # Twin join per window, at the baseline and with the object moved away from the origin.
    join = {}
    for w in WINDOWS:
        shared = sorted(set(van["cells"][w]) & set(exp["cells"][w]))
        entry = {"shared_cells": len(shared)}
        for label, k in (("baseline", 0), ("object_moved", 2)):
            diff = f2t = t2f = 0
            for cell in shared:
                a, x = van["cells"][w][cell]["p"][k], exp["cells"][w][cell]["p"][k]
                if a != x:
                    diff += 1
                    if a == 0 and x == 1:
                        f2t += 1
                    else:
                        t2f += 1
            entry[label] = {"diff": diff, "vanilla_blocked_expanded_free": f2t,
                            "expanded_blocked_vanilla_free": t2f}
        join[w] = entry
    report["twin_join"] = join

    v = report["vanilla"]["imprint"]
    e = report["expanded"]["imprint"]
    report["verdict"] = {
        "vanilla_imprint_follows_the_object": (v["origin_cells_lost_when_moved_away"] > 0
                                               and v["dest_cells_gained_when_moved_in"] > 0),
        "expanded_imprints_at_the_destination": e["dest_cells_gained_when_moved_in"] > 0,
        "expanded_instance_inert_at_every_pose": e["cells_changed_by_the_move"] == 0,
        "controls_held": not problems,
        "problems": problems,
    }
    out_path.parent.mkdir(parents=True, exist_ok=True)
    out_path.write_text(json.dumps(report, indent=2), encoding="utf-8")

    for name in ("vanilla", "expanded"):
        r = report[name]
        o = [str(s["blocked"]) for s in r["windows"]["origin"]]
        d = [str(s["blocked"]) for s in r["windows"]["dest"]]
        print(f"{name:9s}: origin {'->'.join(o)}   dest {'->'.join(d)}   "
              f"moved={r['object_moved']} hash_moved={r['imprint']['whole_map_hash_moved_with_the_object']}")
    print(f"vanilla  : origin loses {v['origin_cells_lost_when_moved_away']}, "
          f"destination gains {v['dest_cells_gained_when_moved_in']}")
    print(f"expanded : origin loses {e['origin_cells_lost_when_moved_away']}, "
          f"destination gains {e['dest_cells_gained_when_moved_in']}, "
          f"cells changed by the move {e['cells_changed_by_the_move']}")
    for w in WINDOWS:
        print(f"twin join {w}: baseline diff {join[w]['baseline']['diff']}, "
              f"with the object moved {join[w]['object_moved']['diff']}")
    for p in problems:
        print("PROBLEM:", p)
    print(f"-> {out_path}")
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main())
