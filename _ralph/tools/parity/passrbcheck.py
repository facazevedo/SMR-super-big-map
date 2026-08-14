"""Score the passability-rebuild probe (`passrebuild_probe.lua`) on a twin pair.

Answers two questions with the same dense sample set, joined by SOURCE cell index:

1. `rebuild-stable`: does the full-map `terrain.RebuildPassability` the mod calls WIPE (or create)
   the non-terrain impassability around the map's huge wonder object?  Stage a vs stage b vs
   stage c per twin; any nonzero `wiped`/`gained` is the defect iteration 021 hypothesised.

2. What accounts for the twins' difference in that neighbourhood.  Objects keep their REAL size
   while the map grows 4/3 in each axis, so an object's own impassable footprint covers a source
   region 3/4 as wide on the expanded map.  That predicts, for the radial blocked-fraction profile
   measured in SOURCE units around the same object:

        profile_expanded(r)  ==  profile_vanilla(r * 4/3)

   The tool scores that model against the null model `profile_expanded(r) == profile_vanilla(r)`,
   on the vanilla-blocked excess only (the terrain-slope background is common to both twins and
   already proven exact by the height gates).

Usage:
  python passrbcheck.py <passrb-vanilla.csv> <passrb-expanded.csv> <out.json> [--map underground]
"""
import json
import sys
from pathlib import Path


def load(path, want_map):
    meta, summary, gridobjs, rows = {}, {}, [], {}
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
            if line.startswith("#summary,"):
                parts = line[9:].split(",")
                if parts[0] == want_map:
                    for kv in parts[1:]:
                        if "=" in kv:
                            k, v = kv.split("=", 1)
                            summary[k] = v
                continue
            if line.startswith("#gridobj,"):
                p = line[9:].split(",")
                if p[0] == want_map:
                    gridobjs.append({"class": p[1], "entity": p[2], "x": int(p[3]), "y": int(p[4]),
                                     "bbox_w": p[5], "bbox_h": p[6], "d_src": int(p[7])})
                continue
            if line.startswith("#") or line.startswith("map,"):
                continue
            p = line.split(",")
            if p[0] != want_map:
                continue
            rows[(int(p[1]), int(p[2]))] = {
                "h": int(p[5]), "p_a": int(p[6]), "p_b": int(p[7]), "p_c": int(p[8]),
                "d": int(p[9]), "mark": int(p[10])}
    return meta, summary, gridobjs, rows


def profile(rows, bin_w, nbins):
    """Blocked fraction per source-radius bin (stage a, the as-generated state)."""
    tot = [0] * nbins
    blk = [0] * nbins
    for r in rows.values():
        b = r["d"] // bin_w
        if b < nbins:
            tot[b] += 1
            blk[b] += 1 - r["p_a"]
    return [(blk[i] / tot[i] if tot[i] else None, tot[i]) for i in range(nbins)]


def sample_profile(prof, bin_w, r):
    """Linear interpolation of a binned profile at source radius r (bin centres)."""
    x = r / bin_w - 0.5
    i = int(x // 1)
    if i < 0:
        i = 0
    if i + 1 >= len(prof):
        i = len(prof) - 2
    f0, f1 = prof[i][0], prof[i + 1][0]
    if f0 is None or f1 is None:
        return None
    t = x - i
    return f0 + (f1 - f0) * max(0.0, min(1.0, t))


def main():
    va, ex, out_path = sys.argv[1], sys.argv[2], sys.argv[3]
    want_map = "underground"
    if "--map" in sys.argv:
        want_map = sys.argv[sys.argv.index("--map") + 1]

    meta_v, sum_v, obj_v, rows_v = load(va, want_map)
    meta_e, sum_e, obj_e, rows_e = load(ex, want_map)
    common = sorted(set(rows_v) & set(rows_e))

    # 1. rebuild stability, per twin, over the whole scanned neighbourhood.
    def stability(rows):
        wiped = sum(1 for r in rows.values() if r["p_a"] == 0 and r["p_b"] == 1)
        gained = sum(1 for r in rows.values() if r["p_a"] == 1 and r["p_b"] == 0)
        nonidem = sum(1 for r in rows.values() if r["p_b"] != r["p_c"])
        return {"n": len(rows), "blocked_a": sum(1 - r["p_a"] for r in rows.values()),
                "blocked_b": sum(1 - r["p_b"] for r in rows.values()),
                "wiped": wiped, "gained": gained, "non_idempotent": nonidem}

    # 2. per-sample join.
    diff = ft = tf = 0
    for k in common:
        a, b = rows_v[k]["p_a"], rows_e[k]["p_a"]
        if a != b:
            diff += 1
            if a == 0 and b == 1:
                ft += 1
            else:
                tf += 1

    bin_w, nbins = 1000, 31
    prof_v = profile(rows_v, bin_w, nbins)
    prof_e = profile(rows_e, bin_w, nbins)

    # 3. footprint model vs null model, on bins whose vanilla profile stands above the far-field
    #    background (the terrain-slope level both twins share).
    far = [prof_v[i][0] for i in range(nbins - 6, nbins) if prof_v[i][0] is not None]
    background = sum(far) / len(far) if far else 0.0
    model_err, null_err, scored = 0.0, 0.0, 0
    per_bin = []
    for i in range(nbins):
        r = (i + 0.5) * bin_w
        fe, fv = prof_e[i][0], prof_v[i][0]
        pred_model = sample_profile(prof_v, bin_w, r * 4.0 / 3.0)
        row = {"r_src": r, "n": prof_e[i][1], "blocked_vanilla": fv, "blocked_expanded": fe,
               "predicted_footprint_model": pred_model}
        if fe is not None and fv is not None and pred_model is not None:
            row["err_model"] = abs(fe - pred_model)
            row["err_null"] = abs(fe - fv)
            if fv - background > 0.05:      # only where the object's own excess dominates
                model_err += row["err_model"]
                null_err += row["err_null"]
                scored += 1
        per_bin.append(row)

    # 4. height control on the same samples (GetHeight is interpolated, so this is a sanity band).
    ratio = 4.0 / 3.0
    hres = [rows_e[k]["h"] - rows_v[k]["h"] * ratio for k in common]
    hres_abs = sorted(abs(v) for v in hres)

    report = {
        "map": want_map,
        "vanilla_csv": str(Path(va).resolve()),
        "expanded_csv": str(Path(ex).resolve()),
        "meta": {"vanilla": meta_v, "expanded": meta_e},
        "probe_summary": {"vanilla": sum_v, "expanded": sum_e},
        "rebuild_stability": {"vanilla": stability(rows_v), "expanded": stability(rows_e)},
        "join": {"n_common": len(common), "diff": diff, "false_to_true": ft, "true_to_false": tf,
                 "diff_pct": round(100.0 * diff / len(common), 4) if common else None},
        "centre_object": {"vanilla": [o for o in obj_v if o["d_src"] == 0],
                          "expanded": [o for o in obj_e if o["d_src"] == 0]},
        "grid_objects_in_scan": {"vanilla": len(obj_v), "expanded": len(obj_e)},
        "background_blocked_fraction": background,
        "radial_bins": per_bin,
        "footprint_model": {
            "scored_bins": scored,
            "mean_abs_err_model": round(model_err / scored, 5) if scored else None,
            "mean_abs_err_null": round(null_err / scored, 5) if scored else None,
        },
        "height_residual_wu": {
            "n": len(hres), "max_abs": hres_abs[-1] if hres_abs else None,
            "p999": hres_abs[int(0.999 * (len(hres_abs) - 1))] if hres_abs else None,
            "mean": sum(hres) / len(hres) if hres else None,
        },
    }
    Path(out_path).write_text(json.dumps(report, indent=2), encoding="utf-8")

    st = report["rebuild_stability"]
    print(f"map={want_map} common={len(common)} diff={diff} ({ft} false->true, {tf} true->false)")
    print(f"rebuild vanilla wiped={st['vanilla']['wiped']} gained={st['vanilla']['gained']} "
          f"nonidem={st['vanilla']['non_idempotent']} | expanded wiped={st['expanded']['wiped']} "
          f"gained={st['expanded']['gained']} nonidem={st['expanded']['non_idempotent']}")
    print(f"blocked: vanilla {st['vanilla']['blocked_a']} expanded {st['expanded']['blocked_a']} "
          f"background={background:.4f}")
    fm = report["footprint_model"]
    print(f"footprint model mean|err|={fm['mean_abs_err_model']} vs null {fm['mean_abs_err_null']} "
          f"over {fm['scored_bins']} bins")
    print(f"report -> {out_path}")
    # Exit non-zero when the rebuild is NOT stable: that is the defect the probe hunts.
    bad = (st["vanilla"]["wiped"] or st["vanilla"]["gained"] or st["expanded"]["wiped"]
           or st["expanded"]["gained"] or st["vanilla"]["non_idempotent"]
           or st["expanded"]["non_idempotent"])
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
