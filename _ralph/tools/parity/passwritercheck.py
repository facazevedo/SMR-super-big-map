"""Score the passability-WRITER probe (item C1b).

Joins the two twins' `passwriter-<tag>.csv` lattices by SOURCE cell and answers, per twin:
  * did the engine's own sequence (InvalidateHeight + InvalidateType + RebuildPassability) change
    any cell of the window - over the window box (s1/s2) or over the whole map (s4);
  * did the whole-map `HashPassability` digest move at all (the liveness control);
  * did the forced-impassable-box control bite (and was it placed on ground where it COULD bite);
  * how the baseline mask splits by ground flatness, which is what makes the residual non-terrain.

Usage: python passwritercheck.py <vanilla_tag> <expanded_tag> <out.json>
"""
import json
import pathlib
import sys

HERE = pathlib.Path(__file__).resolve().parent
OUT = HERE / "out"
HDR = "map,sgx,sgy,x,y,h,p0,p1,p2,p3,p4,d_src,ctrl,forced0,forced3".split(",")


def load(tag):
    recs, meta = [], {}
    for line in (OUT / f"passwriter-{tag}.csv").read_text(encoding="utf-8").splitlines():
        if line.startswith("#"):
            key = line.split(",")[0][1:]
            meta.setdefault(key, []).append(line)
            continue
        if line.startswith("map,") or not line.strip():
            continue
        r = dict(zip(HDR, line.split(",")))
        for k in ("sgx", "sgy", "x", "y", "h", "d_src", "ctrl", "forced0", "forced3"):
            r[k] = int(r[k])
        for k in range(5):
            r[f"p{k}"] = int(r[f"p{k}"])
        recs.append(r)
    return recs, meta


def digest(tag):
    recs, meta = load(tag)
    per_env = {}
    for env in sorted({r["map"] for r in recs}):
        sub = [r for r in recs if r["map"] == env]
        flat = [r for r in sub if r["h"] == 10000]
        ctrl = [r for r in sub if r["ctrl"] == 1]
        hashes = {}
        for line in meta.get("hash", []):
            if f",{env}," in line:
                hashes = dict(p.split("=", 1) for p in line.split(",")[2:])
        per_env[env] = {
            "n": len(sub),
            "blocked": {f"s{k}": sum(1 for r in sub if r[f"p{k}"] == 0) for k in range(5)},
            "changed_s1": sum(1 for r in sub if r["p0"] != r["p1"]),
            "changed_s2": sum(1 for r in sub if r["p0"] != r["p2"]),
            "changed_s4": sum(1 for r in sub if r["p0"] != r["p4"]),
            "flat_cells": len(flat),
            "flat_blocked": sum(1 for r in flat if r["p0"] == 0),
            "nonflat_blocked": sum(1 for r in sub if r["h"] != 10000 and r["p0"] == 0),
            "hash": hashes,
            "hash_moved_s1": bool(hashes) and hashes.get("h1") != hashes.get("h0"),
            "hash_moved_s4": bool(hashes) and hashes.get("h4") != hashes.get("h0"),
            "control": {
                "n": len(ctrl),
                "blocked_before": sum(1 for r in ctrl if r["p0"] == 0),
                "blocked_after": sum(1 for r in ctrl if r["p3"] == 0),
                "forced_after": sum(1 for r in ctrl if r["forced3"] == 1),
                # A control placed on already-blocked ground can never demonstrate anything.
                "informative": any(r["p0"] == 1 for r in ctrl),
                "bit": any(r["p0"] == 1 and r["p3"] == 0 for r in ctrl),
            },
            "steps": [l for l in meta.get("step", []) if f",{env}," in l],
            "boxes": [l for l in meta.get("boxes", []) if f",{env}," in l],
        }
    return per_env


def main():
    van_tag, exp_tag, out_path = sys.argv[1], sys.argv[2], sys.argv[3]
    van, exp = digest(van_tag), digest(exp_tag)
    report = {"vanilla_tag": van_tag, "expanded_tag": exp_tag,
              "vanilla": van, "expanded": exp, "join": {}}
    for env in sorted(set(van) & set(exp)):
        vr, er = load(van_tag)[0], load(exp_tag)[0]
        vmap = {(r["sgx"], r["sgy"]): r for r in vr if r["map"] == env}
        emap = {(r["sgx"], r["sgy"]): r for r in er if r["map"] == env}
        common = sorted(set(vmap) & set(emap))
        diff = [c for c in common if vmap[c]["p0"] != emap[c]["p0"]]
        report["join"][env] = {
            "n_common": len(common),
            "diff": len(diff),
            "false_to_true": sum(1 for c in diff if vmap[c]["p0"] == 0),
            "true_to_false": sum(1 for c in diff if vmap[c]["p0"] == 1),
            "diff_on_flat_vanilla": sum(1 for c in diff if vmap[c]["h"] == 10000),
        }
    pathlib.Path(out_path).write_text(json.dumps(report, indent=2), encoding="utf-8")
    print(json.dumps(report["join"], indent=2))
    for name, d in (("vanilla", van), ("expanded", exp)):
        for env, e in d.items():
            print(f"{name}/{env}: blocked {e['blocked']} changed s1={e['changed_s1']} "
                  f"s4={e['changed_s4']} hash_moved_s4={e['hash_moved_s4']} "
                  f"control informative={e['control']['informative']} bit={e['control']['bit']}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
