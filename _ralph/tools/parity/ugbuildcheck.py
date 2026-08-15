"""Gate `underground-unchanged`, the DERIVED-GRID clause: the gate says underground *grids*, and
`ugcheck.py` compares only the height grid.

Why the height grid alone is not the whole clause.  v811/v812 added a closing gameplay-grid rebuild
on BOTH maps (`SuperBigMap.GenerationGrids.RebuildFinal`, the underground reached through the
wrapper at `sbm_map_generation.lua:11707`/`:12106`), so a grid DERIVED from the underground terrain
can differ from the pre-change pipeline even when the terrain itself is byte-identical - and the
buildable grid is exactly such a grid (`Lua/BuildableGrid.lua`).  This scores it between a
pre-change run and a current one of the same coordinate with the same pins, i.e. the same protocol
`ugcheck.py` uses, on the one derived grid this workspace can dump.

Scored, all on the text dumps `buildable_probe.lua` writes:
  underground shipped grid   v804 vs v812   must be cell-identical (the clause)
  underground fresh rebuild  v804 vs v812   must be cell-identical (the same terrain must rebuild
                                            to the same grid under either payload)
  surface shipped grid       v804 vs v812   REQUIRED to differ - the control that proves the two
                                            runs saw different payloads
Reported beside them: staleness within each run (shipped vs its own fresh rebuild), which is
`buildcheck.py`'s step-6 statistic measured on the pre-change payload for the first time.

Usage:
  python ugbuildcheck.py --base <tag_prechange> --new <tag_current> [--out report.json]
                         [--out-dir out]
"""
import argparse
import hashlib
import json
from pathlib import Path

import numpy as np

HERE = Path(__file__).resolve().parent


def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as fh:
        for chunk in iter(lambda: fh.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def load(out_dir, tag, mapname, kind):
    suffix = "-buildable.txt" if kind == "shipped" else "-buildable-rebuild.txt"
    path = out_dir / f"height-{tag}-{mapname}{suffix}"
    lines = path.read_text().splitlines()
    rows = [np.fromstring(ln, dtype=np.int64, sep=",") for ln in lines[1:] if ln]
    return path, lines[0], np.stack(rows)


def compare(out_dir, base_tag, new_tag, mapname, kind):
    bp, bh, b = load(out_dir, base_tag, mapname, kind)
    np_, nh, n = load(out_dir, new_tag, mapname, kind)
    if b.shape != n.shape:
        return dict(map=mapname, kind=kind, comparable=False,
                    shape_base=list(b.shape), shape_new=list(n.shape))
    d = b != n
    idx = np.argwhere(d)[:8]
    bsha, nsha = sha256(bp), sha256(np_)
    return dict(
        map=mapname, kind=kind, comparable=True,
        base_file=str(bp), new_file=str(np_), base_header=bh, new_header=nh,
        base_sha256=bsha, new_sha256=nsha, byte_identical=bsha == nsha,
        cells=int(b.size), cells_differing=int(d.sum()),
        max_abs_diff=int(np.abs(b - n).max()) if d.any() else 0,
        base_sentinel=int((b == 65535).sum()), new_sentinel=int((n == 65535).sum()),
        base_max_non_sentinel=int(b[b != 65535].max()), new_max_non_sentinel=int(n[n != 65535].max()),
        samples=[dict(y=int(y), x=int(x), base=int(b[y, x]), new=int(n[y, x])) for y, x in idx],
    )


def staleness(out_dir, tag, mapname):
    _, _, s = load(out_dir, tag, mapname, "shipped")
    _, _, r = load(out_dir, tag, mapname, "rebuild")
    d = s != r
    return dict(tag=tag, map=mapname, cells=int(s.size), stale=int(d.sum()),
                max_abs_diff=int(np.abs(s - r).max()) if d.any() else 0)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--base", required=True, help="pre-change payload run tag")
    ap.add_argument("--new", required=True, help="current payload run tag")
    ap.add_argument("--out")
    ap.add_argument("--out-dir", default="out")
    a = ap.parse_args()
    out_dir = Path(a.out_dir)
    if not out_dir.is_absolute():
        out_dir = HERE / out_dir

    rep = {
        "gate": "underground-unchanged (derived buildable grid clause)",
        "base_tag": a.base, "new_tag": a.new,
        "scored": [compare(out_dir, a.base, a.new, "underground", "shipped"),
                   compare(out_dir, a.base, a.new, "underground", "rebuild")],
        "control_surface": [compare(out_dir, a.base, a.new, "surface", "shipped")],
        "staleness_within_run": [staleness(out_dir, t, m) for t in (a.base, a.new)
                                 for m in ("underground", "surface")],
    }
    rep["clause_pass"] = all(r["comparable"] and r["cells_differing"] == 0 for r in rep["scored"])
    rep["control_fires"] = rep["control_surface"][0]["cells_differing"] > 0
    rep["failures"] = ([] if rep["clause_pass"] else ["underground buildable grid differs"]) + \
                      ([] if rep["control_fires"] else ["surface control did not differ"])
    if a.out:
        Path(a.out).write_text(json.dumps(rep, indent=2, sort_keys=True))

    for r in rep["scored"] + rep["control_surface"]:
        print(f"{r['map']:12s} {r['kind']:8s} {r['cells_differing']:>9,} of {r['cells']:,} differ "
              f"(max |d| {r['max_abs_diff']:,})  sha equal={r['byte_identical']}")
    for s in rep["staleness_within_run"]:
        print(f"  stale within {s['tag']} {s['map']:12s}: {s['stale']:>7,} of {s['cells']:,}")
    print(f"clause_pass={rep['clause_pass']} control_fires={rep['control_fires']} "
          f"failures={rep['failures']}")
    return 0 if not rep["failures"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
