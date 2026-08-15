"""Scorer for the passability INPUT-ABLATION probe (`passablate_probe.lua`, item C1d).

Joins the two twins' ablation lattices by SOURCE cell and answers one question with numbers:
does the `BottomlessPit` wonder apply the pit-region impassability mask, and does the expanded
clone apply anything at all?

The probe's ladder alternates ablation and RESTORE stages; a restore that does not return the
window to its baseline verdicts invalidates that stage's reading, so the restores are scored as
controls first and the verdict is withheld when one fails.

    python passablatecheck.py <vanilla_tag> <expanded_tag> <out.json>
    e.g. python passablatecheck.py t14a t14x ..\\..\\runs\\full-z-parity\\artifacts\\pass\\x.json

Exit 0 when both runs parsed and every restore control held; 1 otherwise.
"""
import json
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
OUT = HERE / "out"

STAGES = {
    0: "baseline",
    1: "scale_flipped",
    2: "scale_restored (control)",
    3: "z_mode_flipped",
    4: "z_mode_restored (control)",
    5: "ef_apply_to_grids_cleared",
    6: "ef_apply_to_grids_restored (control)",
    7: "object_deleted",
    8: "second_rebuild (idempotence)",
}
CONTROLS = (2, 4, 6)


def parse(tag):
    path = OUT / f"passabl-{tag}.csv"
    if not path.exists():
        raise SystemExit(f"missing lattice: {path}")
    meta, obj_rows, steps, acts, summary, hashes = {}, [], [], [], {}, {}
    cells = {}
    for line in path.read_text(encoding="utf-8").splitlines():
        if not line:
            continue
        if line.startswith("#"):
            parts = line.split(",")
            kind = parts[0]
            if kind == "#meta":
                meta["raw"] = line
                for kv in parts[1:]:
                    if "=" in kv:
                        k, v = kv.split("=", 1)
                        meta[k] = v
            elif kind == "#centre":
                meta["centre"] = line
                for kv in parts[2:]:
                    if "=" in kv:
                        k, v = kv.split("=", 1)
                        meta["centre_" + k] = v
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
                for kv in parts[2:]:
                    if "=" in kv:
                        k, v = kv.split("=", 1)
                        summary[k] = v
            elif kind == "#skip":
                meta["skip"] = line
            continue
        if line.startswith("map,"):
            continue
        f = line.split(",")
        if len(f) < 16 or f[0] != "underground":
            continue
        sgx, sgy = int(f[1]), int(f[2])
        cells[(sgx, sgy)] = {
            "h": int(f[5]),
            "p": [int(f[6 + k]) for k in range(9)],
            "d": int(f[15]),
        }
    return {"meta": meta, "objects": obj_rows, "acts": acts, "steps": steps,
            "summary": summary, "hashes": hashes, "cells": cells}


def stage_table(run):
    n = len(run["cells"])
    rows = []
    for k in range(9):
        blocked = sum(1 for c in run["cells"].values() if c["p"][k] == 0)
        changed = sum(1 for c in run["cells"].values() if c["p"][k] != c["p"][0])
        rows.append({
            "stage": k,
            "what": STAGES[k],
            "blocked": blocked,
            "blocked_pct": round(100.0 * blocked / n, 3) if n else None,
            "changed_vs_baseline": changed,
            "hash": run["hashes"].get(f"h{k}"),
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
        table = stage_table(run)
        base = table[0]["blocked"]
        controls = {}
        for k in CONTROLS:
            ok = table[k]["changed_vs_baseline"] == 0
            controls[STAGES[k]] = {"changed_vs_baseline": table[k]["changed_vs_baseline"],
                                   "held": ok}
            if not ok:
                problems.append(f"{name}: restore control s{k} did not return to baseline "
                                f"({table[k]['changed_vs_baseline']} cells differ)")
        obj0 = next((o for o in run["objects"] if o["when"] == "s0"), {})
        report[name] = {
            "samples": len(run["cells"]),
            "centre": run["meta"].get("centre"),
            "object_s0": obj0,
            "stages": table,
            "restore_controls": controls,
            "object_contribution": {
                "blocked_with_object": base,
                "blocked_without_object": table[7]["blocked"],
                "cells_the_object_blocks": base - table[7]["blocked"],
                "pct_of_window": round(100.0 * (base - table[7]["blocked"])
                                       / max(1, len(run["cells"])), 3),
                "hash_moves_when_deleted": run["hashes"].get("h6") != run["hashes"].get("h7"),
            },
            "scale_effect_cells": table[1]["changed_vs_baseline"],
            "z_mode_effect_cells": table[3]["changed_vs_baseline"],
            "flag_effect_cells": table[5]["changed_vs_baseline"],
            "steps": run["steps"],
            "acts": run["acts"],
        }

    # Twin join: same source cells, both runs.
    shared = sorted(set(van["cells"]) & set(exp["cells"]))
    join = {"shared_cells": len(shared)}
    for label, k in (("baseline", 0), ("object_deleted", 7)):
        diff = f2t = t2f = 0
        for cell in shared:
            a, x = van["cells"][cell]["p"][k], exp["cells"][cell]["p"][k]
            if a != x:
                diff += 1
                if a == 0 and x == 1:
                    f2t += 1
                else:
                    t2f += 1
        join[label] = {"diff": diff, "vanilla_blocked_expanded_free": f2t,
                       "expanded_blocked_vanilla_free": t2f}
    join["residual_explained_by_the_object"] = (
        join["baseline"]["diff"] - join["object_deleted"]["diff"])
    report["twin_join"] = join

    van_c = report["vanilla"]["object_contribution"]["cells_the_object_blocks"]
    exp_c = report["expanded"]["object_contribution"]["cells_the_object_blocks"]
    report["verdict"] = {
        "vanilla_object_is_the_applier": van_c > 0,
        "expanded_object_applies_nothing": exp_c == 0,
        "restore_controls_held": not problems,
        "problems": problems,
    }
    out_path.parent.mkdir(parents=True, exist_ok=True)
    out_path.write_text(json.dumps(report, indent=2), encoding="utf-8")

    print(f"vanilla  : object blocks {van_c} of {report['vanilla']['samples']} window cells "
          f"({report['vanilla']['object_contribution']['pct_of_window']}%)")
    print(f"expanded : object blocks {exp_c} of {report['expanded']['samples']} window cells "
          f"({report['expanded']['object_contribution']['pct_of_window']}%)")
    print(f"twin diff: baseline {join['baseline']['diff']} -> "
          f"with the object deleted on both {join['object_deleted']['diff']} "
          f"(the object explains {join['residual_explained_by_the_object']})")
    for k in (1, 3, 5):
        print(f"  s{k} {STAGES[k]:34s} vanilla {report['vanilla']['stages'][k]['blocked']:6d} "
              f"expanded {report['expanded']['stages'][k]['blocked']:6d}")
    for p in problems:
        print("PROBLEM:", p)
    print(f"-> {out_path}")
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main())
