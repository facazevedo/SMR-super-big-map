"""Gate `underground-unchanged`: the underground height grid must be byte-identical to the
pre-change pipeline's on the same seeds.

The task replaces the SURFACE Z transform only; the underground has always scaled Z by exactly
4/3 (uniform) and is the control the whole task is measured against, so any movement there would
invalidate every before/after number in the run.  The code argument alone is not evidence: the
new zone-compression block is skipped when `uniform_underground` is true, but the surface's
different final terrain could in principle reach the underground through generation order, RNG
draws or the shared mapdata presets.  So this scores two REAL runs of the same coordinate and the
same pinned underground seed, one deployed from the pre-change payload commit and one from the
current one.

Byte-identical is the whole gate; there is deliberately no tolerance.  The stamp rows
(`zmul/zdiv/zadd/uniform` and the scaled height ranges) are compared too, because an identical
grid under different declared ranges would still change what the buildable grid honours.

The surface pair is reported for contrast only - it is EXPECTED to differ (that is the change).

Usage:
  python ugcheck.py --base <tag_prechange> --new <tag_current> [--out report.json]
                    [--dim 8192] [--out-dir out]
"""

import argparse
import hashlib
import json
import sys
from pathlib import Path

import numpy as np

HERE = Path(__file__).resolve().parent


def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as fh:
        for chunk in iter(lambda: fh.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def load(path, dim):
    a = np.fromfile(path, dtype="<u2")
    if a.size != dim * dim:
        raise SystemExit(f"{path}: {a.size} cells, expected {dim*dim}")
    return a.reshape(dim, dim)


def grid_pair(base_path, new_path, dim):
    """Byte + cell level comparison of two U16 raw grids."""
    out = {
        "base_file": str(base_path),
        "new_file": str(new_path),
        "base_sha256": sha256(base_path),
        "new_sha256": sha256(new_path),
        "base_bytes": base_path.stat().st_size,
        "new_bytes": new_path.stat().st_size,
    }
    out["byte_identical"] = (
        out["base_sha256"] == out["new_sha256"] and out["base_bytes"] == out["new_bytes"]
    )
    a, b = load(base_path, dim), load(new_path, dim)
    d = b.astype(np.int64) - a.astype(np.int64)
    nz = np.flatnonzero(d.ravel())
    out["cells"] = int(a.size)
    out["cells_differing"] = int(nz.size)
    out["max_abs_diff"] = int(np.abs(d).max()) if nz.size else 0
    out["base_min_max"] = [int(a.min()), int(a.max())]
    out["new_min_max"] = [int(b.min()), int(b.max())]
    if nz.size:
        i = int(nz[0])
        out["first_diff"] = {"x": i % dim, "y": i // dim,
                            "base": int(a.ravel()[i]), "new": int(b.ravel()[i])}
        pct = [50, 90, 99, 100]
        vals = np.abs(d.ravel()[nz])
        out["abs_diff_pct"] = {str(p): float(np.percentile(vals, p)) for p in pct}
    return out


def stamp_rows(path, env):
    """The `map,<env>,...` and `ranges,<env>,...` rows of a zones stamp dump."""
    rows = []
    for line in Path(path).read_text(encoding="utf-8").splitlines():
        parts = line.split(",")
        if len(parts) >= 2 and parts[0] in ("map", "ranges") and parts[1] == env:
            rows.append(line.strip())
    return rows


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--base", required=True, help="pre-change run tag")
    ap.add_argument("--new", required=True, help="current-code run tag")
    ap.add_argument("--out-dir", default=str(HERE / "out"))
    ap.add_argument("--dim", type=int, default=8192)
    ap.add_argument("--out")
    args = ap.parse_args()
    out_dir = Path(args.out_dir)

    rep = {"gate": "underground-unchanged", "base_tag": args.base, "new_tag": args.new,
           "dim": args.dim, "failures": []}

    for env in ("underground", "surface"):
        rep[env] = grid_pair(out_dir / f"height-{args.base}-{env}.raw",
                             out_dir / f"height-{args.new}-{env}.raw", args.dim)
        rep[env]["stamp_base"] = stamp_rows(out_dir / f"height-{args.base}-zones.txt", env)
        rep[env]["stamp_new"] = stamp_rows(out_dir / f"height-{args.new}-zones.txt", env)
        rep[env]["stamp_identical"] = rep[env]["stamp_base"] == rep[env]["stamp_new"]

    ug = rep["underground"]
    if not ug["byte_identical"]:
        rep["failures"].append(
            f"underground grid differs: {ug['cells_differing']} cells, "
            f"max |d| {ug['max_abs_diff']}")
    if not ug["stamp_identical"]:
        rep["failures"].append("underground stamp/height-range rows differ")
    # The surface MUST have moved - that is the change under test.  A surface that did not move
    # means the two runs were served the same payload, so the underground zero proves nothing.
    if rep["surface"]["byte_identical"]:
        rep["failures"].append(
            "surface grid is byte-identical too: the two runs did not see different payloads")
    rep["gate_pass"] = not rep["failures"]

    text = json.dumps(rep, indent=2, sort_keys=True)
    if args.out:
        Path(args.out).write_text(text, encoding="utf-8")
    print(text)
    return 0 if rep["gate_pass"] else 1


if __name__ == "__main__":
    sys.exit(main())
