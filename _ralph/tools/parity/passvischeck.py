"""Scorer for the passability VISIBILITY-ABLATION probe (`passvis_probe.lua`, item C1h).

Answers one question with numbers: is the cleared `efVisible` bit the reason the mod's
`BottomlessPit` clone rasterises no impassability on the expanded map?

The probe runs the SAME ladder on both twins, flipping the bit away from that twin's own baseline
and back, so vanilla is the positive control (visible -> hidden) and the expanded map is the test
(hidden -> visible):

    vanilla window collapses when hidden AND expanded window fills when shown
        -> `efVisible` gates pass-grid rasterisation; the defect is the mod's darkness concealment
           (`BuriedWonderDarkness.SyncVisibility` -> `wonder:SetVisible(false)`), not the Z transform
    neither moves
        -> visibility refuted; the search returns to the clone's remaining state

Controls that must hold or the reading is void, on BOTH twins: s1 rebuilds with the object
untouched (must reproduce s0), s3 and s5 restore the baseline flag (must return the window to s1
AND return the whole-map passability hash to its s1 value), and every probe action reports ok.

    python passvischeck.py <vanilla_tag> <expanded_tag> <out.json>
    e.g. python passvischeck.py t18a t18x ..\\..\\runs\\full-z-parity\\artifacts\\pass\\x.json

Exit 0 when both runs parsed, every control held and vanilla's positive control moved; 1 otherwise.
"""
import json
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
OUT = HERE / "out"

STAGES = {
    0: "baseline",
    1: "rebuild_only (control)",
    2: "efVisible flipped (raw enum flag)",
    3: "raw flag restored (control)",
    4: "efVisible flipped (SetVisible API)",
    5: "SetVisible restored (control)",
}
NSTAGES = 6


def parse(tag):
    path = OUT / f"passvis-{tag}.csv"
    if not path.exists():
        raise SystemExit(f"missing lattice: {path}")
    meta, steps, acts, objs, hashes = {}, [], [], [], {}
    cells = {}
    for line in path.read_text(encoding="utf-8", errors="replace").splitlines():
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
            elif kind == "#centre":
                meta["centre"] = line
            elif kind == "#baseline_visible":
                meta["baseline_visible"] = parts[2]
            elif kind == "#setvisible":
                meta["setvisible"] = line
            elif kind == "#obj":
                objs.append(line)
            elif kind == "#act":
                acts.append(line)
            elif kind == "#step":
                steps.append(line)
            elif kind == "#hash":
                for kv in parts[2:]:
                    if "=" in kv:
                        k, v = kv.split("=", 1)
                        hashes[k] = v
            elif kind == "#skip":
                meta.setdefault("skips", []).append(line)
            continue
        if line.startswith("map,"):
            continue
        f = line.split(",")
        # map,window,sgx,sgy,x,y,h,p0..p5,d_src,inplay
        if len(f) < 15 or f[0] != "underground":
            continue
        cells[(int(f[2]), int(f[3]))] = {
            "h": int(f[6]),
            "p": [int(f[7 + k]) for k in range(NSTAGES)],
            "d": int(f[13]),
            "inplay": int(f[14]),
        }
    return {"meta": meta, "acts": acts, "steps": steps, "objs": objs,
            "hashes": hashes, "cells": cells}


def window_table(cells):
    n = len(cells)
    rows = []
    for k in range(NSTAGES):
        blocked = sum(1 for c in cells.values() if c["p"][k] == 0)
        rows.append({
            "stage": k,
            "what": STAGES[k],
            "blocked": blocked,
            "blocked_pct": round(100.0 * blocked / n, 3) if n else None,
            "changed_vs_baseline": sum(1 for c in cells.values() if c["p"][k] != c["p"][0]),
        })
    return rows


def join(van, exp, k_van, k_exp):
    shared = sorted(set(van["cells"]) & set(exp["cells"]))
    diff = f2t = t2f = 0
    for cell in shared:
        a, x = van["cells"][cell]["p"][k_van], exp["cells"][cell]["p"][k_exp]
        if a != x:
            diff += 1
            if a == 0 and x == 1:
                f2t += 1
            else:
                t2f += 1
    return {"shared_cells": len(shared), "diff": diff,
            "vanilla_blocked_expanded_free": f2t, "expanded_blocked_vanilla_free": t2f}


def main():
    if len(sys.argv) < 4:
        raise SystemExit(__doc__)
    van_tag, exp_tag, out_path = sys.argv[1], sys.argv[2], Path(sys.argv[3])
    van, exp = parse(van_tag), parse(exp_tag)

    report = {"vanilla_tag": van_tag, "expanded_tag": exp_tag}
    problems = []
    for name, run in (("vanilla", van), ("expanded", exp)):
        table = window_table(run["cells"])
        if table[1]["changed_vs_baseline"] != 0:
            problems.append(f"{name}: rebuild-only control changed "
                            f"{table[1]['changed_vs_baseline']} cells")
        for k, label in ((3, "raw-flag restore"), (5, "SetVisible restore")):
            delta = sum(1 for c in run["cells"].values() if c["p"][k] != c["p"][1])
            if delta != 0:
                problems.append(f"{name}: {label} control differs from the rebuild-only state on "
                                f"{delta} cells")
        for k in ("h3", "h5"):
            if run["hashes"].get(k) != run["hashes"].get("h1"):
                problems.append(f"{name}: whole-map passability hash did not return to its "
                                f"rebuild-only value at {k} "
                                f"(h1={run['hashes'].get('h1')} {k}={run['hashes'].get(k)})")
        for act in run["acts"]:
            if "ok=true" not in act:
                problems.append(f"{name}: probe action failed: {act}")
        if run["meta"].get("baseline_visible") is None:
            problems.append(f"{name}: probe reported no baseline visibility")
        # The two ladders must agree: the raw bit and the API are the same experiment unless the
        # class overrides SetVisible.
        if table[2]["blocked"] != table[4]["blocked"]:
            problems.append(f"{name}: the raw-flag and SetVisible flips disagree "
                            f"({table[2]['blocked']} vs {table[4]['blocked']} blocked)")
        report[name] = {
            "samples": len(run["cells"]),
            "baseline_visible": run["meta"].get("baseline_visible"),
            "centre": run["meta"].get("centre"),
            "setvisible_impl": run["meta"].get("setvisible"),
            "window": table,
            "hashes": run["hashes"],
            "cells_gained_by_the_flip": table[2]["blocked"] - table[1]["blocked"],
            "whole_map_hash_moved_with_the_flip":
                run["hashes"].get("h2") != run["hashes"].get("h1"),
            "steps": run["steps"],
            "acts": run["acts"],
            "obj": run["objs"],
        }

    # Twin joins.  The point of the run: does equalising VISIBILITY equalise the twins' masks?
    van_vis = report["vanilla"]["baseline_visible"] == "true"
    exp_vis = report["expanded"]["baseline_visible"] == "true"
    if not (van_vis and not exp_vis):
        problems.append(f"unexpected baseline visibilities (vanilla={van_vis} expanded={exp_vis}); "
                        f"the mirror reading assumes vanilla visible and the clone hidden")
    report["twin_join"] = {
        "baseline__vanilla_visible_vs_clone_hidden": join(van, exp, 1, 1),
        "both_visible__vanilla_baseline_vs_clone_flag_flipped": join(van, exp, 1, 2),
        "both_hidden__vanilla_flag_flipped_vs_clone_baseline": join(van, exp, 2, 1),
        "both_visible__setvisible_ladder": join(van, exp, 1, 4),
    }

    v = report["vanilla"]
    e = report["expanded"]
    hiding_removes = v["cells_gained_by_the_flip"] < 0
    showing_adds = e["cells_gained_by_the_flip"] > 0
    report["verdict"] = {
        "hiding_vanillas_wonder_removes_its_imprint": hiding_removes,
        "showing_the_expanded_clone_adds_an_imprint": showing_adds,
        "twin_diff_baseline": report["twin_join"]["baseline__vanilla_visible_vs_clone_hidden"]["diff"],
        "twin_diff_with_both_visible":
            report["twin_join"]["both_visible__vanilla_baseline_vs_clone_flag_flipped"]["diff"],
        "controls_held": not problems,
        "problems": problems,
    }
    if hiding_removes and showing_adds:
        report["verdict"]["reading"] = (
            "efVisible gates pass-grid rasterisation: the clone is inert because the mod's own "
            "darkness concealment clears it (BuriedWonderDarkness.SyncVisibility -> "
            "SetVisible(false)).  The fix belongs there, not in the Z transform.")
    elif hiding_removes:
        report["verdict"]["reading"] = (
            "hiding vanilla's wonder removes its imprint, but showing the clone adds none - "
            "visibility is necessary and not sufficient; the clone carries a second defect.")
    else:
        report["verdict"]["reading"] = (
            "visibility does not move either twin - REFUTED; return to the clone's remaining state.")

    out_path.parent.mkdir(parents=True, exist_ok=True)
    out_path.write_text(json.dumps(report, indent=2), encoding="utf-8")

    for name in ("vanilla", "expanded"):
        r = report[name]
        print(f"{name}: baseline_visible={r['baseline_visible']} origin blocked "
              + " -> ".join(str(row["blocked"]) for row in r["window"])
              + f"   (flip {r['cells_gained_by_the_flip']:+d}, hash moved "
                f"{r['whole_map_hash_moved_with_the_flip']})")
    for k, j in report["twin_join"].items():
        print(f"join {k}: diff={j['diff']} "
              f"(vanilla-blocked {j['vanilla_blocked_expanded_free']}, "
              f"expanded-blocked {j['expanded_blocked_vanilla_free']}) of {j['shared_cells']}")
    print(f"verdict: {report['verdict']['reading']}")
    if problems:
        print("PROBLEMS:")
        for p in problems:
            print("  " + p)
    print(f"report -> {out_path}")
    return 0 if (not problems and hiding_removes) else 1


if __name__ == "__main__":
    sys.exit(main())
