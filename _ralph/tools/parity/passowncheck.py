"""Scorer for the passability OWNERSHIP probe (`passown_probe.lua`, flag `passown`).

Joins the twins' probe dumps and answers, per twin and per write box:
  * which Lua write path (if any) MOVED passability bits at all;
  * whether that write survived the engine's own Invalidate+Rebuild over the box;
  * whether it survived the whole-map Invalidate+Rebuild the mod itself runs after stretching;
  * whether the whole-map `HashPassability` returned EXACTLY to its pre-write value, which is the
    strong form of "the rebuild owns these cells".

Usage:
  python passowncheck.py <vanilla.csv> <expanded.csv> <out.json>
"""
import json
import sys
from pathlib import Path


def load(path):
    meta, tries, steps, hashes, summary, boxes, current = {}, [], [], {}, {}, [], {}
    cells = []
    for line in Path(path).read_text(encoding="utf-8").splitlines():
        if not line:
            continue
        if line.startswith("#try,"):
            # The call signature itself contains commas ("terrain.X(map,box)"), so rejoin every
            # field before the first key=value pair.
            p = line.split(",")
            first_kv = next((i for i, f in enumerate(p) if i >= 3 and "=" in f), len(p))
            rec = {"map": p[1], "box": p[2], "signature": ",".join(p[3:first_kv])}
            for kv in p[first_kv:]:
                if "=" in kv:
                    k, v = kv.split("=", 1)
                    rec[k] = v
            tries.append(rec)
        elif line.startswith("#step,"):
            p = line.split(",")
            steps.append({"map": p[1], "label": p[2], "detail": ",".join(p[3:])})
        elif line.startswith("#hash,"):
            p = line.split(",")
            hashes[p[1]] = dict(kv.split("=", 1) for kv in p[2:] if "=" in kv)
        elif line.startswith("#summary,"):
            p = line.split(",")
            summary[p[1]] = dict(kv.split("=", 1) for kv in p[3:] if "=" in kv)
            summary[p[1]]["grid"] = p[2].split("=", 1)[1]
        elif line.startswith("#wbox,"):
            p = line.split(",")
            boxes.append({"map": p[1], "id": p[2], "rest": ",".join(p[3:])})
        elif line.startswith("#current,"):
            p = line.split(",")
            current[p[1]] = dict(kv.split("=", 1) for kv in p[2:] if "=" in kv)
        elif line.startswith("#meta"):
            meta = dict(kv.split("=", 1) for kv in line.split(",")[1:] if "=" in kv)
        elif line.startswith("#") or line.startswith("map,"):
            continue
        else:
            p = line.split(",")
            if len(p) < 14:
                continue
            cells.append(dict(map=p[0], sgx=int(p[1]), sgy=int(p[2]), h=int(p[5]),
                              p0=int(p[6]), p1=int(p[7]), p2=int(p[8]), p3=int(p[9]),
                              d=int(p[10]), wbox=int(p[11])))
    return dict(meta=meta, tries=tries, steps=steps, hashes=hashes, summary=summary,
                boxes=boxes, current=current, cells=cells)


def score(d, tag):
    out = {"tag": tag, "meta": d["meta"], "envs": {}}
    for env, s in d["summary"].items():
        h = d["hashes"].get(env, {})
        env_cells = [c for c in d["cells"] if c["map"] == env]
        res = {
            "grid": s.get("grid"),
            "samples": int(s.get("samples", 0)),
            "window_blocked": [int(s.get(f"blocked{k}", 0)) for k in range(4)],
            "hash": {k: h.get(k) for k in ("h0", "h1", "h2", "h3")},
            "hash_moved_by_write": h.get("h0") != h.get("h1"),
            "hash_restored_by_local_rebuild": h.get("h2") == h.get("h0"),
            "hash_moved_by_full_rebuild": h.get("h3") != h.get("h0"),
            # The summary's shape strings contain commas (they are call signatures), so the
            # authoritative record is the ladder itself: the first try that moved bits.
            "shapeA": next((t["signature"] for t in d["tries"]
                            if t["map"] == env and t["box"] == "A" and int(t.get("at_want", 0)) > 0),
                           "no_visible_write"),
            "shapeB": next((t["signature"] for t in d["tries"]
                            if t["map"] == env and t["box"] == "B" and int(t.get("at_want", 0)) > 0),
                           "no_visible_write"),
            "ladder": [t for t in d["tries"] if t["map"] == env],
            "boxes": [b for b in d["boxes"] if b["map"] == env],
            "current_map": d["current"].get(env, {}),
        }
        for bid, key in ((1, "A"), (2, "B")):
            bc = [c for c in env_cells if c["wbox"] == bid]
            if not bc:
                continue
            res[f"box{key}"] = {
                "cells": len(bc),
                "blocked_s0": sum(1 for c in bc if c["p0"] == 0),
                "blocked_after_write": sum(1 for c in bc if c["p1"] == 0),
                "blocked_after_local_rebuild": sum(1 for c in bc if c["p2"] == 0),
                "blocked_after_full_rebuild": sum(1 for c in bc if c["p3"] == 0),
                "flat": len({c["h"] for c in bc}) == 1,
            }
            res[f"box{key}"]["write_visible"] = (
                res[f"box{key}"]["blocked_after_write"] != res[f"box{key}"]["blocked_s0"])
            res[f"box{key}"]["survives_local_rebuild"] = (
                res[f"box{key}"]["blocked_after_local_rebuild"]
                == res[f"box{key}"]["blocked_after_write"])
            res[f"box{key}"]["survives_full_rebuild"] = (
                res[f"box{key}"]["blocked_after_full_rebuild"]
                == res[f"box{key}"]["blocked_after_write"])
        out["envs"][env] = res
    return out


def main():
    van, exp, outp = sys.argv[1], sys.argv[2], sys.argv[3]
    a, x = load(van), load(exp)
    report = {"vanilla": score(a, Path(van).stem), "expanded": score(x, Path(exp).stem)}
    # The verdict the investigation needs, stated once and machine-readably.
    v = []
    for side in ("vanilla", "expanded"):
        for env, r in report[side]["envs"].items():
            b = r.get("boxB")
            if not b:
                continue
            v.append({
                "side": side, "env": env, "write": r["shapeB"],
                "write_visible": b["write_visible"],
                "survives_local_rebuild": b["survives_local_rebuild"],
                "survives_full_rebuild": b["survives_full_rebuild"],
                "hash_restored_exactly": r["hash_restored_by_local_rebuild"],
            })
    report["verdict"] = v
    report["conclusion"] = (
        "the rebuild owns the bits" if all(
            (not e["survives_local_rebuild"]) and e["hash_restored_exactly"] for e in v)
        else "mixed - read the per-box columns")
    Path(outp).write_text(json.dumps(report, indent=2), encoding="utf-8")
    print(json.dumps({"verdict": v, "conclusion": report["conclusion"]}, indent=2))


if __name__ == "__main__":
    main()
