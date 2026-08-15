"""Scorer for the passability CLASS-vs-INSTANCE probe (`passclass_probe.lua`, item C1g).

Answers one question with numbers: on the map where the mod's `BottomlessPit` clone imprints
nothing, does a FRESH object of the same entity - and of the same class - imprint?

    fresh object imprints  -> the class/entity rasterises fine on the expanded map and the defect
                              is in how the mod's wonder path constructs or mutates the clone; the
                              property diff this scorer prints names the field
    fresh object is inert  -> the class/entity is rasterised out on that map and the repair route
                              is 027b's load-time `OnMsg.OnPassabilityRebuilding` +
                              `terrain.ClearPassabilityBox`

Controls that must hold or the reading is void, on BOTH twins: s1 rebuilds with nothing placed
(must reproduce s0 in both windows), s3 and s5 remove what s2/s4 placed (must return both windows
to the s1 state AND return the whole-map passability hash to its s1 value).  Vanilla is the
positive control: its fresh objects must imprint at the destination, else the ladder cannot see an
imprint at all.

    python passclasscheck.py <vanilla_tag> <expanded_tag> <out.json>
    e.g. python passclasscheck.py t17a t17x ..\\..\\runs\\full-z-parity\\artifacts\\pass\\x.json

Exit 0 when both runs parsed, every control held and vanilla's positive control imprinted;
1 otherwise.
"""
import json
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
OUT = HERE / "out"

STAGES = {
    0: "baseline",
    1: "rebuild_only (control)",
    2: "fresh_object_with_the_wonder_entity",
    3: "entity_object_removed (control)",
    4: "fresh_object_of_the_wonder_class",
    5: "class_object_removed (control)",
}
WINDOWS = ("origin", "dest")
NSTAGES = 6
# Property keys whose twin difference is a candidate mechanism rather than bookkeeping noise.
NOISE_KEYS = ("member.handle", "member.update_thread", "member.creation_time", "probe_map_id",
              "map_id", "vis_x", "vis_y", "obbmin")


def parse(tag):
    path = OUT / f"passclass-{tag}.csv"
    if not path.exists():
        raise SystemExit(f"missing lattice: {path}")
    meta, steps, acts, hashes, summary, props = {}, [], [], {}, {}, {}
    cells = {w: {} for w in WINDOWS}
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
            elif kind in ("#centre", "#dest"):
                meta[kind[1:]] = line
            elif kind == "#prop":
                # #prop,<map>,<who>,<key>,<value>
                if len(parts) >= 5:
                    props.setdefault(f"{parts[1]}/{parts[2]}", {})[parts[3]] = ",".join(parts[4:])
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
        # map,window,sgx,sgy,x,y,h,p0..p5,d_src,inplay
        if len(f) < 15 or f[0] != "underground":
            continue
        win = f[1]
        if win not in cells:
            continue
        cells[win][(int(f[2]), int(f[3]))] = {
            "h": int(f[6]),
            "p": [int(f[7 + k]) for k in range(NSTAGES)],
            "d": int(f[13]),
            "inplay": int(f[14]),
        }
    return {"meta": meta, "acts": acts, "steps": steps, "summary": summary,
            "hashes": hashes, "cells": cells, "props": props}


def window_table(cells):
    n = len(cells)
    rows = []
    for k in range(NSTAGES):
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


def prop_diff(a, b):
    keys = sorted(set(a) | set(b))
    out = {}
    for k in keys:
        va, vb = a.get(k, "<absent>"), b.get(k, "<absent>")
        if va != vb:
            out[k] = [va, vb]
    return out


def main():
    if len(sys.argv) < 4:
        raise SystemExit(__doc__)
    van_tag, exp_tag, out_path = sys.argv[1], sys.argv[2], Path(sys.argv[3])
    van, exp = parse(van_tag), parse(exp_tag)

    report = {"vanilla_tag": van_tag, "expanded_tag": exp_tag}
    problems = []
    for name, run in (("vanilla", van), ("expanded", exp)):
        tables = {w: window_table(run["cells"][w]) for w in WINDOWS}
        for w in WINDOWS:
            if tables[w][1]["changed_vs_baseline"] != 0:
                problems.append(f"{name}/{w}: rebuild-only control changed "
                                f"{tables[w][1]['changed_vs_baseline']} cells")
            for k, label in ((3, "entity-object removal"), (5, "class-object removal")):
                delta = sum(1 for c in run["cells"][w].values() if c["p"][k] != c["p"][1])
                if delta != 0:
                    problems.append(f"{name}/{w}: {label} control differs from the rebuild-only "
                                    f"state on {delta} cells")
        for k in ("h3", "h5"):
            if run["hashes"].get(k) != run["hashes"].get("h1"):
                problems.append(f"{name}: whole-map passability hash did not return to its "
                                f"rebuild-only value at {k} "
                                f"(h1={run['hashes'].get('h1')} {k}={run['hashes'].get(k)})")
        for act in run["acts"]:
            if "ok=true" not in act:
                problems.append(f"{name}: probe action failed: {act}")
        report[name] = {
            "samples_per_window": {w: len(run["cells"][w]) for w in WINDOWS},
            "centre": run["meta"].get("centre"),
            "dest": run["meta"].get("dest"),
            "windows": tables,
            "hashes": run["hashes"],
            "imprint": {
                "dest_cells_gained_by_the_entity_object":
                    tables["dest"][2]["blocked"] - tables["dest"][1]["blocked"],
                "dest_cells_gained_by_the_class_object":
                    tables["dest"][4]["blocked"] - tables["dest"][1]["blocked"],
                "origin_cells_changed_by_either_placement":
                    tables["origin"][2]["changed_vs_baseline"]
                    + tables["origin"][4]["changed_vs_baseline"],
                "whole_map_hash_moved_with_the_entity_object":
                    run["hashes"].get("h2") != run["hashes"].get("h1"),
                "whole_map_hash_moved_with_the_class_object":
                    run["hashes"].get("h4") != run["hashes"].get("h1"),
            },
            "steps": run["steps"],
            "acts": run["acts"],
        }

    # Twin join per window, at the baseline and with each fresh object in place.
    join = {}
    for w in WINDOWS:
        shared = sorted(set(van["cells"][w]) & set(exp["cells"][w]))
        entry = {"shared_cells": len(shared)}
        for label, k in (("baseline", 0), ("entity_object_placed", 2), ("class_object_placed", 4)):
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

    # Property diffs: the point of the run.  Vanilla's live wonder against the expanded clone (what
    # the mod changed), and on each twin the clone against the fresh objects (what a working
    # imprinter looks like on that same map).
    diffs = {}
    for label, a, b in (
            ("vanilla_existing__vs__expanded_existing",
             van["props"].get("underground/existing", {}),
             exp["props"].get("underground/existing", {})),
            ("expanded_existing__vs__expanded_fresh_entity",
             exp["props"].get("underground/existing", {}),
             exp["props"].get("underground/fresh_entity", {})),
            ("expanded_existing__vs__expanded_fresh_class",
             exp["props"].get("underground/existing", {}),
             exp["props"].get("underground/fresh_class", {})),
            ("vanilla_existing__vs__vanilla_fresh_class",
             van["props"].get("underground/existing", {}),
             van["props"].get("underground/fresh_class", {})),
    ):
        d = prop_diff(a, b)
        diffs[label] = d
    report["property_diffs"] = diffs

    # Candidate fields: differ between the twins' live wonders AND between the inert clone and the
    # fresh objects that DO imprint on the same map - i.e. they track the imprint, not the stretch.
    twin = diffs["vanilla_existing__vs__expanded_existing"]
    fresh = diffs["expanded_existing__vs__expanded_fresh_entity"]
    candidates = {}
    for k, (va, vx) in twin.items():
        if k in NOISE_KEYS or k.startswith("member.SuperBigMap"):
            continue
        if k in fresh:
            candidates[k] = {"vanilla_existing": va, "expanded_existing": vx,
                             "expanded_fresh_entity": fresh[k][1]}
    report["candidate_fields_tracking_the_imprint"] = candidates

    v = report["vanilla"]["imprint"]
    e = report["expanded"]["imprint"]
    report["verdict"] = {
        "vanilla_fresh_objects_imprint": (v["dest_cells_gained_by_the_entity_object"] > 0
                                          and v["dest_cells_gained_by_the_class_object"] > 0),
        "expanded_fresh_entity_object_imprints": e["dest_cells_gained_by_the_entity_object"] > 0,
        "expanded_fresh_class_object_imprints": e["dest_cells_gained_by_the_class_object"] > 0,
        "reading": None,
        "controls_held": not problems,
        "problems": problems,
    }
    if report["verdict"]["expanded_fresh_entity_object_imprints"]:
        report["verdict"]["reading"] = ("the class/entity rasterises on the expanded map - the "
                                        "defect is the mod's own instance; see "
                                        "candidate_fields_tracking_the_imprint")
    else:
        report["verdict"]["reading"] = ("a fresh object of that class/entity is inert on the "
                                        "expanded map too - the class is rasterised out there")

    out_path.parent.mkdir(parents=True, exist_ok=True)
    out_path.write_text(json.dumps(report, indent=2), encoding="utf-8")

    for name in ("vanilla", "expanded"):
        r = report[name]
        print(f"{name}: dest blocked "
              + " -> ".join(str(row["blocked"]) for row in r["windows"]["dest"])
              + f"   (entity +{r['imprint']['dest_cells_gained_by_the_entity_object']}, "
                f"class +{r['imprint']['dest_cells_gained_by_the_class_object']})")
        print(f"{name}: origin blocked "
              + " -> ".join(str(row["blocked"]) for row in r["windows"]["origin"]))
    print(f"candidate fields: {sorted(candidates)}")
    for k, v2 in candidates.items():
        print(f"  {k}: vanilla={v2['vanilla_existing']} clone={v2['expanded_existing']} "
              f"fresh={v2['expanded_fresh_entity']}")
    print(f"verdict: {report['verdict']['reading']}")
    if problems:
        print("PROBLEMS:")
        for p in problems:
            print("  " + p)
    print(f"report -> {out_path}")
    return 0 if (not problems and report["verdict"]["vanilla_fresh_objects_imprint"]) else 1


if __name__ == "__main__":
    sys.exit(main())
