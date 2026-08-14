"""The user ruling's discriminating measurement: terrain passability WITHOUT objects.

WHY THIS EXISTS
===============
`passverdict.py` scores passability at every object's own cell, and every measurement of it
runs about 5:1 false->true (45S82E 271/53, 42S28W 147/15, the untouched underground 77/9).
Quantization and resample noise are symmetric, so a one-way bias has a systematic cause, and
the ruling forbids restating the `pass-exact-outside-zones` gate until that cause is named.

Two candidate causes are entangled in an at-object sample:

  TERRAIN     the Z transform changing a slope across the engine's passability threshold, and
  OBSTRUCTION objects keeping their real size while the map grows 4/3 in each axis, so a
              neighbour that blocked a cell in vanilla is 4/3 further away in the expanded map
              and no longer blocks it.  That mechanism is inherently one-way false->true and
              has nothing to do with Z (45S82E has zero compression zones and still shows 324).

`passlattice_probe.lua` separates them by sampling a geometric lattice in SOURCE space and
keeping only samples farther than a footprint-sized threshold from EVERY object of that map.
This tool joins the two twins on the source lattice index, drops anything inside a compression
massif, and reports the direction of the residue that survives.

THE INTERPRETATION IS FIXED IN ADVANCE (ruling), so it cannot be rationalized after the fact:

  (a) object-free terrain matches with only SYMMETRIC residue at the untouched underground's
      noise level  ->  the terrain transform is proven exact and the at-object residue is
      object-density geometry.  Exit 0.
  (b) object-free terrain ALSO shows a one-way false->true bias  ->  the transform has a real
      defect; the gate stands as written.  Exit 1.

"Symmetric" is decided by a two-sided binomial test on (false->true vs true->false) at p=0.5
together with a bias-ratio bound, and "at the underground's noise level" by comparing the
surface's object-free diff RATE with the same map's underground lattice - the underground Z has
always been an exact 4/3 and this task never touched it, so it is the noise floor of the whole
pipeline measured on the same run.

The same run's heights are scored on the same object-free samples: outside the massifs the
expanded height must be the affine image of the vanilla height, which is the per-cell gate
`height-similarity-outside-zones` re-measured at points chosen for this test.

SECOND HALF OF THE RULING: `--objdensity` reports whether the AT-OBJECT residue correlates with
local object density (diff rate vs the count of objects within the same threshold radius), read
off the existing `pass-*.csv` dumps.  Under (a) it must correlate; that correlation is
confirming evidence, not a gate.

Usage:
  python passlatticecheck.py <vanilla_tag> <expanded_tag> <zones_txt|-> <out_json>
                             [--threshold 2400] [--objdensity]
"""
import json
import math
import sys
from collections import defaultdict
from pathlib import Path

import zverdict

HERE = Path(__file__).resolve().parent
OUT = HERE / "out"
HEIGHT_TILE = 100
DEFAULT_THRESHOLD = 2400          # source wu; >= the largest object footprint (ruling)
SYMMETRY_P = 1e-3                 # two-sided binomial p below which the residue is one-way
SYMMETRY_RATIO = 2.0              # ... and the bias ratio must also exceed this to fail


def read_lattice(path):
    """-> {map: [rows]}, {map: meta}.  Rows are dicts with ints."""
    rows, maps, head = defaultdict(list), {}, None
    for line in Path(path).read_text(encoding="utf-8", errors="replace").splitlines():
        if not line:
            continue
        if line.startswith("#map,"):
            f = line[5:].split(",")
            maps[f[0]] = dict(p.split("=", 1) for p in f[1:] if "=" in p)
            continue
        if line.startswith("#"):
            continue
        if line.startswith("map,sgx"):
            head = line.split(",")
            continue
        if head is None:
            continue
        f = line.split(",")
        r = dict(zip(head, f))
        for k in ("sgx", "sgy", "x", "y", "h", "p", "dmin_src", "nobj"):
            r[k] = int(r[k])
        rows[r["map"]].append(r)
    return rows, maps


def binom_two_sided(k, n):
    """P(|X - n/2| >= |k - n/2|) under Binomial(n, 1/2), exact, no scipy dependency."""
    if n == 0:
        return 1.0
    k = min(k, n - k)
    # Sum both tails via log-gamma to stay exact for n in the thousands.
    total = 0.0
    for i in range(0, k + 1):
        total += math.exp(math.lgamma(n + 1) - math.lgamma(i + 1) - math.lgamma(n - i + 1)
                          - n * math.log(2.0))
    return min(1.0, 2.0 * total)


def score_map(vrows, erows, massifs, threshold, stamp):
    vidx = {(r["sgx"], r["sgy"]): r for r in vrows}
    paired = kept = inside = 0
    diff = f2t = t2f = 0
    h_exact = h_n = 0
    h_worst = 0
    by_density = defaultdict(lambda: [0, 0, 0])   # bucket -> [n, f2t, t2f]
    examples = []
    for e in erows:
        v = vidx.get((e["sgx"], e["sgy"]))
        if v is None:
            continue
        paired += 1
        if v["dmin_src"] < threshold or e["dmin_src"] < threshold:
            continue
        cx, cy = e["x"] // HEIGHT_TILE, e["y"] // HEIGHT_TILE
        if any(x0 <= cx <= x1 and y0 <= cy <= y1 for x0, y0, x1, y1 in massifs):
            inside += 1
            continue
        kept += 1
        if stamp:
            h_n += 1
            want = (v["h"] * stamp["mul"]) // stamp["div"] + stamp["add"]
            d = e["h"] - want
            if d == 0:
                h_exact += 1
            h_worst = max(h_worst, abs(d))
        bucket = min(4, max(v["nobj"], e["nobj"]))
        by_density[bucket][0] += 1
        if v["p"] != e["p"]:
            diff += 1
            if v["p"] == 0:
                f2t += 1
                by_density[bucket][1] += 1
            else:
                t2f += 1
                by_density[bucket][2] += 1
            if len(examples) < 20:
                examples.append({"sgx": e["sgx"], "sgy": e["sgy"], "x": e["x"], "y": e["y"],
                                 "vanilla_pass": v["p"], "expanded_pass": e["p"],
                                 "vanilla_h": v["h"], "expanded_h": e["h"],
                                 "dmin_src": min(v["dmin_src"], e["dmin_src"])})
    return {
        "paired_lattice": paired, "scored": kept, "inside_massif": inside,
        "diff": diff, "false_to_true": f2t, "true_to_false": t2f,
        "diff_rate_pct": round(100.0 * diff / kept, 4) if kept else None,
        "bias_ratio": round(f2t / t2f, 3) if t2f else (None if not f2t else float("inf")),
        "symmetry_binomial_p": binom_two_sided(min(f2t, t2f), f2t + t2f),
        "height_scored": h_n, "height_exact": h_exact,
        "height_exact_pct": round(100.0 * h_exact / h_n, 4) if h_n else None,
        "height_worst_abs": h_worst,
        "by_local_object_count": {str(k): {"n": v[0], "false_to_true": v[1],
                                           "true_to_false": v[2],
                                           "diff_rate_pct": round(100.0 * (v[1] + v[2]) / v[0], 4)}
                                  for k, v in sorted(by_density.items())},
        "diff_examples": examples,
    }


def object_density(vtag, etag, stamp, threshold):
    """Ruling's confirming evidence: at-object diff rate vs local object density."""
    import passverdict
    vrows = passverdict.read_pass(OUT / f"pass-{vtag}.csv")
    erows = passverdict.read_pass(OUT / f"pass-{etag}.csv")
    out = {}
    for m in ("surface", "underground"):
        v = [r for r in vrows if r["map"] == m]
        e = [r for r in erows if r["map"] == m]
        if not v or not e:
            continue
        massifs = stamp.get(m, {}).get("massifs", [])
        # Local density from the VANILLA object field, in source units, via a bucket grid.
        bs = threshold
        buckets = defaultdict(list)
        for r in v:
            buckets[(r["src_x"] // bs, r["src_y"] // bs)].append((r["src_x"], r["src_y"]))

        def near_count(sx, sy):
            n = 0
            bx, by = sx // bs, sy // bs
            for ox in (-1, 0, 1):
                for oy in (-1, 0, 1):
                    for px, py in buckets.get((bx + ox, by + oy), ()):
                        if (px - sx) ** 2 + (py - sy) ** 2 <= bs * bs:
                            n += 1
            return n - 1  # exclude the object itself

        pool = defaultdict(list)
        for r in v:
            pool[(r["class"], r["src_x"], r["src_y"])].append(r)
        bins = defaultdict(lambda: [0, 0, 0])
        pairs = []
        for r in e:
            bucket = pool.get((r["class"], r["src_x"], r["src_y"]))
            if not bucket:
                continue
            vr = bucket.pop()
            if vr["self_pass"] not in ("true", "false") or r["self_pass"] not in ("true", "false"):
                continue
            cx, cy = r["x"] // HEIGHT_TILE, r["y"] // HEIGHT_TILE
            if any(x0 <= cx <= x1 and y0 <= cy <= y1 for x0, y0, x1, y1 in massifs):
                continue
            nb = near_count(r["src_x"], r["src_y"])
            differs = vr["self_pass"] != r["self_pass"]
            key = min(nb, 20)
            bins[key][0] += 1
            if differs:
                bins[key][1] += 1
                if vr["self_pass"] == "false":
                    bins[key][2] += 1
            pairs.append((nb, 1 if differs else 0))
        # Rank correlation between local density and "this object's cell differs".
        rho = spearman([p[0] for p in pairs], [p[1] for p in pairs])
        grouped = {}
        for lo, hi in ((0, 0), (1, 2), (3, 5), (6, 10), (11, 20)):
            n = sum(bins[k][0] for k in range(lo, hi + 1))
            d = sum(bins[k][1] for k in range(lo, hi + 1))
            f = sum(bins[k][2] for k in range(lo, hi + 1))
            grouped[f"{lo}-{hi}"] = {"n": n, "diff": d, "false_to_true": f,
                                     "diff_rate_pct": round(100.0 * d / n, 4) if n else None}
        out[m] = {"threshold_src_wu": threshold, "objects_scored": len(pairs),
                  "spearman_rho_density_vs_diff": rho, "by_neighbour_count": grouped}
    return out


def spearman(xs, ys):
    n = len(xs)
    if n < 3:
        return None

    def ranks(vals):
        order = sorted(range(n), key=lambda i: vals[i])
        r = [0.0] * n
        i = 0
        while i < n:
            j = i
            while j + 1 < n and vals[order[j + 1]] == vals[order[i]]:
                j += 1
            avg = (i + j) / 2.0 + 1.0
            for k in range(i, j + 1):
                r[order[k]] = avg
            i = j + 1
        return r

    rx, ry = ranks(xs), ranks(ys)
    mx, my = sum(rx) / n, sum(ry) / n
    num = sum((a - mx) * (b - my) for a, b in zip(rx, ry))
    den = math.sqrt(sum((a - mx) ** 2 for a in rx) * sum((b - my) ** 2 for b in ry))
    return round(num / den, 4) if den else None


def main():
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    flags = [a for a in sys.argv[1:] if a.startswith("--")]
    vtag, etag, zones_txt, out_json = args[:4]
    threshold = DEFAULT_THRESHOLD
    for f in flags:
        if f.startswith("--threshold"):
            threshold = int(f.split("=", 1)[1])

    vrows, vmeta = read_lattice(OUT / f"passlat-{vtag}.csv")
    erows, emeta = read_lattice(OUT / f"passlat-{etag}.csv")
    stamp = {} if zones_txt == "-" else zverdict.read_stamp(zones_txt)

    result = {"vanilla": vtag, "expanded": etag, "zones": zones_txt,
              "threshold_src_wu": threshold,
              "probe_meta": {"vanilla": vmeta, "expanded": emeta}, "maps": {}}
    for m in ("surface", "underground"):
        if not vrows.get(m) or not erows.get(m):
            continue
        st = stamp.get(m)
        result["maps"][m] = score_map(vrows[m], erows[m],
                                      (st or {}).get("massifs", []), threshold, st)
        result["maps"][m]["massifs"] = len((st or {}).get("massifs", []))

    if "--objdensity" in flags:
        # Same run, same tags: the twins carry `passall` beside `passlattice`, so the at-object
        # residue and the object-free lattice come from one generation each.
        result["at_object_density"] = object_density(vtag, etag, stamp, threshold)

    # The verdict, on the rules stated in the module docstring and fixed before the run.
    s = result["maps"].get("surface")
    u = result["maps"].get("underground")
    if s:
        one_way = (s["symmetry_binomial_p"] < SYMMETRY_P
                   and (s["bias_ratio"] is None or s["bias_ratio"] >= SYMMETRY_RATIO
                        or s["bias_ratio"] <= 1.0 / SYMMETRY_RATIO))
        at_noise = (u is None or s["diff_rate_pct"] is None or u["diff_rate_pct"] is None
                    or s["diff_rate_pct"] <= max(2.0 * u["diff_rate_pct"], 0.05))
        result["surface_object_free_one_way"] = one_way
        result["surface_at_underground_noise_level"] = at_noise
        result["interpretation"] = "b_transform_defect" if one_way else (
            "a_terrain_exact" if at_noise else "a_symmetric_but_above_underground_noise")
        result["pass"] = (not one_way) and at_noise
    else:
        result["pass"] = False
        result["interpretation"] = "no_surface_samples"

    Path(out_json).write_text(json.dumps(result, indent=2), encoding="utf-8")
    print(json.dumps({k: v for k, v in result.items() if k != "probe_meta"}, indent=2))
    return 0 if result["pass"] else 1


if __name__ == "__main__":
    sys.exit(main())
