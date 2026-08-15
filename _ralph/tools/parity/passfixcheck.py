"""Scorer for the buried-wonder concealment FIX (`passfix_probe.lua`, item C1i).

The defect, measured in full-z-parity iterations 028-032 on both twins at 45S82E: the mod concealed
buried wonders by clearing `efVisible`, and the engine rasterises an object's ApplyToGrids surfaces
into the pass grid only while that bit is set, so the expanded map's `BottomlessPit` clone applied
NO impassability.  Baseline numbers to beat, from the same 201x201 / 200 src-wu window this probe
samples: vanilla blocked 21,719, expanded 866, twin diff 20,869 (20,861 vanilla-blocked/expanded-
free).  032's ablation showed the ceiling: with both wonders visible the window agrees to 67 cells.

Mod 808 conceals with zero opacity instead.  This scorer requires BOTH halves of the claim, so the
gate cannot be passed by simply turning the concealment off:

  1. the expanded wonder is still CONCEALED - opacity 0 on the object and on every attach, and the
     mod's own `SuperBigMapConcealedByDarkness` stamp present;
  2. it is VISIBLE TO THE GRIDS - `efVisible` set, and the twin join over the shared source cells
     down to the 032 ablation level (<= --max-diff, default 200, versus the 20,869 baseline);
  3. the vanilla twin is UNTOUCHED - visible, opacity 100, no mod stamp - and its own blocked count
     is unchanged from the 21,719 the reading probes have measured since iteration 023.

    python passfixcheck.py <vanilla_tag> <expanded_tag> <out.json> [--max-diff N]
    e.g. python passfixcheck.py t19a t19x ..\\..\\runs\\full-z-parity\\artifacts\\pass\\x.json

Exit 0 when every requirement above holds; 1 otherwise.
"""
import json
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
OUT = HERE / "out"

# Measured on this exact window by iterations 023/024/026/028/030/031/032 (vanilla is a control and
# must not move; the expanded figures are what the fix is supposed to change).
BASELINE = {
    "vanilla_blocked": 21719,
    "expanded_blocked_before_fix": 866,
    "twin_diff_before_fix": 20869,
    "twin_diff_with_both_visible_032": 67,
}
DEFAULT_MAX_DIFF = 200


def parse(tag):
    path = OUT / f"passfix-{tag}.csv"
    if not path.exists():
        raise SystemExit(f"missing lattice: {path}")
    meta, objs, hashes, cells = {}, [], {}, {}
    summary = []
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
            elif kind == "#obj":
                row = {"tag": parts[1], "role": parts[2], "depth": int(parts[3]),
                       "class": parts[4]}
                for kv in parts[5:]:
                    if "=" in kv:
                        k, v = kv.split("=", 1)
                        row[k] = v
                objs.append(row)
            elif kind == "#hash":
                for kv in parts[2:]:
                    if "=" in kv:
                        k, v = kv.split("=", 1)
                        hashes[k] = v
            elif kind == "#summary":
                summary.append(line)
            elif kind == "#skip":
                meta.setdefault("skips", []).append(line)
            continue
        if line.startswith("map,"):
            continue
        f = line.split(",")
        # map,window,sgx,sgy,x,y,h,p0,d_src,inplay
        if len(f) < 10 or f[0] != "underground":
            continue
        cells[(int(f[2]), int(f[3]))] = {"h": int(f[6]), "p": int(f[7]),
                                         "d": int(f[8]), "inplay": int(f[9])}
    return {"meta": meta, "objs": objs, "hashes": hashes, "cells": cells, "summary": summary}


def wonder_state(run):
    """The wonder itself plus its attaches, as the fix's two requirements need them."""
    tree = [o for o in run["objs"] if o["role"].startswith("wonder")]
    root = next((o for o in tree if o["depth"] == 0), None)
    opacities = []
    for o in tree:
        try:
            opacities.append(int(o.get("GetOpacity", "?")))
        except ValueError:
            opacities.append(None)
    return {
        "found": root is not None,
        "class": root and root.get("class"),
        "entity": root and root.get("entity"),
        "ef_visible": root and root.get("ef_visible"),
        "ef_grids": root and root.get("ef_grids"),
        "opacity": root and root.get("GetOpacity"),
        "revealed": root and root.get("revealed"),
        "sbm_concealed": root and root.get("sbm_concealed"),
        "sbm_reason": root and root.get("sbm_reason"),
        "tree_size": len(tree),
        "tree_opacities": opacities,
        "tree": tree,
    }


def join(van, exp):
    shared = sorted(set(van["cells"]) & set(exp["cells"]))
    diff = f2t = t2f = 0
    for cell in shared:
        a, x = van["cells"][cell]["p"], exp["cells"][cell]["p"]
        if a != x:
            diff += 1
            if a == 0 and x == 1:
                f2t += 1
            else:
                t2f += 1
    return {"shared_cells": len(shared), "diff": diff,
            "vanilla_blocked_expanded_free": f2t, "expanded_blocked_vanilla_free": t2f}


def main():
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    if len(args) < 3:
        raise SystemExit(__doc__)
    max_diff = DEFAULT_MAX_DIFF
    for i, a in enumerate(sys.argv):
        if a == "--max-diff" and i + 1 < len(sys.argv):
            max_diff = int(sys.argv[i + 1])
    van_tag, exp_tag, out_path = args[0], args[1], Path(args[2])
    van, exp = parse(van_tag), parse(exp_tag)

    problems = []
    report = {"vanilla_tag": van_tag, "expanded_tag": exp_tag, "baseline": BASELINE,
              "max_diff": max_diff}
    for name, run in (("vanilla", van), ("expanded", exp)):
        blocked = sum(1 for c in run["cells"].values() if c["p"] == 0)
        w = wonder_state(run)
        report[name] = {
            "samples": len(run["cells"]),
            "blocked": blocked,
            "centre": run["meta"].get("centre"),
            "hash": run["hashes"].get("h0"),
            "wonder": w,
            "summary": run["summary"],
        }
        if not run["cells"]:
            problems.append(f"{name}: no underground samples")
        if not w["found"]:
            problems.append(f"{name}: the probe found no wonder to report")

    v, e = report["vanilla"], report["expanded"]

    # (3) the vanilla control must be exactly what every reading probe has measured since 023.
    if v["blocked"] != BASELINE["vanilla_blocked"]:
        problems.append(f"vanilla control moved: window blocked {v['blocked']} vs the measured "
                        f"{BASELINE['vanilla_blocked']}")
    if v["wonder"]["ef_visible"] != "true":
        problems.append(f"vanilla wonder is not visible (ef_visible={v['wonder']['ef_visible']})")
    if v["wonder"]["sbm_concealed"] not in (None, "nil"):
        problems.append("the mod touched the VANILLA twin's wonder "
                        f"(sbm_concealed={v['wonder']['sbm_concealed']})")

    # (1) still concealed on the expanded map, by opacity, with the mod's own stamp.
    if e["wonder"]["sbm_concealed"] != "true":
        problems.append("the expanded wonder is NOT concealed by the mod "
                        f"(sbm_concealed={e['wonder']['sbm_concealed']}); the fix may not be "
                        "obtained by disabling the concealment")
    nonzero = [o for o in e["wonder"]["tree_opacities"] if o != 0]
    if nonzero:
        problems.append(f"the expanded wonder tree is not fully transparent: opacities "
                        f"{e['wonder']['tree_opacities']}")

    # (2) visible to the grids, and the window now agrees with vanilla.
    if e["wonder"]["ef_visible"] != "true":
        problems.append("the expanded wonder still has efVisible cleared "
                        f"(ef_visible={e['wonder']['ef_visible']}) - it will rasterise nothing")
    if e["wonder"]["ef_grids"] != "true":
        problems.append(f"the expanded wonder lost efApplyToGrids "
                        f"(ef_grids={e['wonder']['ef_grids']})")

    j = join(van, exp)
    report["twin_join"] = j
    if j["shared_cells"] < 40000:
        problems.append(f"only {j['shared_cells']} shared source cells; the windows do not align")
    if j["diff"] > max_diff:
        problems.append(f"twin window disagreement {j['diff']} exceeds {max_diff} "
                        f"(baseline {BASELINE['twin_diff_before_fix']}, "
                        f"032 ablation ceiling {BASELINE['twin_diff_with_both_visible_032']})")

    report["verdict"] = {
        "concealment_still_applied": e["wonder"]["sbm_concealed"] == "true" and not nonzero,
        "wonder_visible_to_the_grids": e["wonder"]["ef_visible"] == "true",
        "expanded_blocked_before_fix": BASELINE["expanded_blocked_before_fix"],
        "expanded_blocked_now": e["blocked"],
        "twin_diff_before_fix": BASELINE["twin_diff_before_fix"],
        "twin_diff_now": j["diff"],
        "problems": problems,
        "passed": not problems,
    }

    out_path.parent.mkdir(parents=True, exist_ok=True)
    out_path.write_text(json.dumps(report, indent=2), encoding="utf-8")

    for name in ("vanilla", "expanded"):
        r = report[name]
        w = r["wonder"]
        print(f"{name}: window blocked {r['blocked']} of {r['samples']}   wonder "
              f"ef_visible={w['ef_visible']} opacity={w['opacity']} "
              f"tree={w['tree_opacities']} concealed={w['sbm_concealed']} "
              f"revealed={w['revealed']}")
    print(f"twin join: diff={j['diff']} of {j['shared_cells']} "
          f"(vanilla-blocked {j['vanilla_blocked_expanded_free']}, "
          f"expanded-blocked {j['expanded_blocked_vanilla_free']}); "
          f"before the fix {BASELINE['twin_diff_before_fix']}, "
          f"032 ablation ceiling {BASELINE['twin_diff_with_both_visible_032']}")
    if problems:
        print("PROBLEMS:")
        for p in problems:
            print("  " + p)
    print(f"report -> {out_path}")
    return 0 if not problems else 1


if __name__ == "__main__":
    sys.exit(main())
