"""Compare before/after T0->T1 snapshot runs produced by sample_t0t1.ps1 + t0t1_snapshot_14N134W.lua.

usage: compare_snapshots.py <dir> <before_tag> <after_tag>
Reads <dir>/<tag>_runN.txt (result line + flat reports) and <dir>/<tag>_runN.lattice (height lattice)
for every N present, prints T0->T1 statistics per tag, the report fields that differ between the two
tags (using run 1 of each as the representative, and checking that runs within a tag agree), and the
height-lattice difference split into outer ring (outer 10% per axis) and interior.
"""
import glob
import os
import re
import statistics
import sys

d, before, after = sys.argv[1], sys.argv[2], sys.argv[3]


def load_runs(tag):
    runs = []
    for path in sorted(glob.glob(os.path.join(d, f"{tag}_run*.txt"))):
        text = open(path, encoding="utf-8-sig", errors="ignore").read()
        m = re.search(r"result=(.*)", text)
        result = m.group(1).strip() if m else ""
        t = re.search(r"t0_to_t1_ms=(\d+)", result)
        reports = {}
        rm = re.search(r"reports=(.*)", text, re.S)
        if rm:
            for kv in rm.group(1).strip().split(";"):
                if "=" in kv:
                    k, v = kv.split("=", 1)
                    reports[k.strip()] = v.strip()
        meta = re.search(r"lattice_meta=(.*)", text)
        lat_path = path[:-4] + ".lattice"
        lattice = None
        if os.path.exists(lat_path):
            raw = open(lat_path, encoding="utf-8-sig", errors="ignore").read()
            raw = raw.strip().strip('"')
            # the harness may wrap the value in a JSON envelope; pull the longest digit/comma run
            m2 = max(re.findall(r"[\d,]{100,}", raw), key=len, default="")
            lattice = [int(x) for x in m2.split(",") if x.strip().isdigit()]
        runs.append({"path": os.path.basename(path), "t0t1": int(t.group(1)) if t else None,
                     "result": result, "reports": reports, "meta": meta.group(1) if meta else "",
                     "lattice": lattice})
    return runs


def summarize(tag, runs):
    vals = [r["t0t1"] for r in runs if r["t0t1"]]
    print(f"== {tag}: {len(runs)} runs, T0->T1 (s): " + ", ".join(f"{v/1000:.1f}" for v in vals))
    if vals:
        print(f"   median {statistics.median(vals)/1000:.1f} s  min {min(vals)/1000:.1f}  max {max(vals)/1000:.1f}")
    for r in runs:
        rep = r["reports"]
        keys = ("terrain_report.patches", "terrain_report.modified_cells", "terrain_report.error",
                "terrain_report.native_raster_cells", "audit_report.resource_failures", "audit_report.rocket_failures",
                "sites.count", "pads.count")
        print("   " + r["path"] + ": " + " ".join(f"{k.split('.')[-1]}={rep.get(k, '-')}" for k in keys))
    return vals


b_runs, a_runs = load_runs(before), load_runs(after)
bv = summarize(before, b_runs)
av = summarize(after, a_runs)
if bv and av:
    print(f"\n== T0->T1 change: median {statistics.median(bv)/1000:.1f} s -> {statistics.median(av)/1000:.1f} s "
          f"({(statistics.median(av)-statistics.median(bv))/1000:+.1f} s)")


def agree(runs, label):
    if len(runs) < 2:
        return
    base = runs[0]["reports"]
    diffs = [k for k in base if any(r["reports"].get(k) != base[k] for r in runs[1:])]
    print(f"\n== within-{label} agreement: {len(diffs)} report fields vary across runs" + (": " + ", ".join(diffs[:12]) if diffs else ""))
    lat = [r["lattice"] for r in runs if r["lattice"]]
    if len(lat) >= 2 and all(len(l) == len(lat[0]) for l in lat):
        n = sum(1 for i in range(len(lat[0])) if any(l[i] != lat[0][i] for l in lat[1:]))
        print(f"   lattice samples that vary across runs: {n} of {len(lat[0])}")


agree(b_runs, before)
agree(a_runs, after)

if b_runs and a_runs:
    br, ar = b_runs[0]["reports"], a_runs[0]["reports"]
    keys = sorted(set(br) | set(ar))
    changed = [(k, br.get(k), ar.get(k)) for k in keys if br.get(k) != ar.get(k)]
    print(f"\n== report fields that differ {before} -> {after}: {len(changed)}")
    for k, x, y in changed[:80]:
        print(f"   {k}: {x} -> {y}")
    bl, al = b_runs[0]["lattice"], a_runs[0]["lattice"]
    if bl and al and len(bl) == len(al):
        meta = b_runs[0]["meta"]
        w = int(re.search(r"w=(\d+)", meta).group(1)); h = int(re.search(r"h=(\d+)", meta).group(1))
        step = int(re.search(r"step=(\d+)", meta).group(1))
        cols = (w + step - 1) // step
        ring, inner = [], []
        for i, (x, y) in enumerate(zip(bl, al)):
            cx, cy = (i % cols) * step, (i // cols) * step
            in_ring = cx < w * 0.1 or cx >= w * 0.9 or cy < h * 0.1 or cy >= h * 0.9
            (ring if in_ring else inner).append(abs(x - y))
        for name, arr in (("outer ring", ring), ("interior", inner)):
            nz = [v for v in arr if v]
            print(f"   height lattice {name}: {len(arr)} samples, {len(nz)} differ "
                  f"({100.0*len(nz)/max(1,len(arr)):.1f}%), max |dz| {max(arr) if arr else 0}, "
                  f"mean |dz| of differing {statistics.mean(nz) if nz else 0:.1f} (height units)")
    else:
        print("   lattice comparison unavailable (missing or mismatched lattices)")
