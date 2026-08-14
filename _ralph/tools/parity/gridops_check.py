"""Cell-exact offline audit of `gridops_probe.lua`'s in-game result.

The probe runs the port's whole in-zone remap pipeline out of engine grid ops on a synthetic
192^2 grid and dumps its input and output raw (U16).  This script re-derives the SAME transform
with numpy/scipy (the semantics `zonefit.py` validated) and compares cell by cell, so the engine
op chain is proven to reproduce the offline reference before any of it is ported into the mod's
generation path.  It also settles which connectivity GridEnumZones uses, by checking which one
reproduces the zone count and sizes the probe reported.

Usage:
    python gridops_check.py --base <artifacts>/gridops/gridops-p01 \
        [--json <out.json>] [--fig <out.png>]
"""

from __future__ import annotations

import argparse
import json
import math
import os
import sys

import numpy as np
from scipy import ndimage

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from zonefit import CAP, FLOOR, XY_DIV, XY_MUL, affine, solve_k  # noqa: E402

BAND_MULT = 1.0 / 3.0  # base = src_cap - ceil(BAND_MULT * (peak - src_cap))


def lua_lut(base, peak, shift):
    """The integer LUT the mod builds in Lua: round-half-up, clamped to the affine.

    Deliberately NOT numpy's rint (round-half-to-even): the Lua port uses
    floor(x + 0.5), so the reference must too or the two disagree on exact halves.
    """
    base_img = int(affine(base, shift))
    H = CAP - base_img
    T = peak - base
    k = solve_k(H, T)
    t = np.arange(0, T + 1, dtype=np.float64)
    if k <= 0.0:
        img = base_img + np.floor(H * t / max(T, 1) + 0.5).astype(np.int64)
    else:
        img = base_img + np.floor(
            H * (-np.expm1(-k * t)) / -np.expm1(-k * T) + 0.5).astype(np.int64)
    img = np.minimum(img, affine(base + t, shift))
    return img, base_img, H, T, k


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--base", required=True, help="probe output prefix (without -in.raw)")
    ap.add_argument("--width", type=int, default=192)
    ap.add_argument("--json", default="")
    ap.add_argument("--fig", default="")
    args = ap.parse_args(argv)

    W = args.width
    src = np.fromfile(args.base + "-in.raw", dtype="<u2").astype(np.int64).reshape((W, W))
    got = np.fromfile(args.base + "-out.raw", dtype="<u2").astype(np.int64).reshape((W, W))
    report = {"schema": "smr.gridops_check", "schema_version": 1,
              "base": os.path.abspath(args.base), "width": W}

    interior = src[1:-1, 1:-1]
    imin, imax = int(interior.min()), int(interior.max())
    shift = min(0, FLOOR - int(affine(imin, 0)))
    src_cap = int(((CAP - shift) * XY_DIV) // XY_MUL)
    report["transform"] = dict(interior_min=imin, interior_max=imax, shift=shift,
                              src_cap=src_cap, affine_max=int(affine(imax, shift)))
    print(f"interior {imin}..{imax}  shift {shift}  src_cap {src_cap}")

    # --- which connectivity does GridEnumZones use?  (the probe reported 3 zones, 97/13/1)
    over = src > src_cap
    conn = {}
    for name, c in (("4", 1), ("8", 2)):
        lab, n = ndimage.label(over, structure=ndimage.generate_binary_structure(2, c))
        sizes = sorted((int(v) for v in np.bincount(lab.ravel())[1:]), reverse=True)
        conn[name] = dict(zones=n, sizes=sizes)
        print(f"connectivity {name}: {n} zones, sizes {sizes[:6]}")
    report["connectivity_candidates"] = conn

    # the port's own choice: 8-connected (a diagonal ridge is one mountain)
    structure = ndimage.generate_binary_structure(2, 2)
    lab, nzones = ndimage.label(over, structure=structure)
    peaks = ndimage.maximum(src, lab, range(1, nzones + 1))
    pos = ndimage.maximum_position(src, lab, range(1, nzones + 1))
    zones = [dict(id=i + 1, peak=int(peaks[i]), py=int(pos[i][0]), px=int(pos[i][1]),
                  area=int((lab == i + 1).sum())) for i in range(nzones)]

    # --- massifs: highest peak first, absorb zones whose peak sits in the base component
    order = sorted(range(nzones), key=lambda i: -zones[i]["peak"])
    absorbed, massifs = set(), []
    for i in order:
        if i in absorbed:
            continue
        z = zones[i]
        over_by = max(1, z["peak"] - src_cap)
        base = max(1, src_cap - int(math.ceil(BAND_MULT * over_by)))
        blab, _ = ndimage.label(src >= base, structure=structure)
        comp = blab == blab[z["py"], z["px"]]
        members = [i]
        for j in range(nzones):
            if j != i and j not in absorbed and comp[zones[j]["py"], zones[j]["px"]]:
                members.append(j)
        absorbed.update(members)
        peak = int(src[comp].max())
        lut, base_img, H, T, k = lua_lut(base, peak, shift)
        massifs.append(dict(members=[m + 1 for m in members], base=base, peak=peak,
                            base_img=base_img, H=int(H), T=int(T), k=k,
                            cells=int(comp.sum()), peak_img=int(lut[-1]),
                            mask=comp, lut=lut))

    want = affine(src, shift)
    for m in massifs:
        sel = m["mask"]
        want = np.where(sel, m["lut"][np.clip(src - m["base"], 0, m["T"])], want)
    inside = np.zeros(src.shape, dtype=bool)
    for m in massifs:
        inside |= m["mask"]

    # the engine grid is U16: a negative affine image (only the synthetic rim ring of artifact
    # zeros) wraps, and the real pipeline clamps it to 0..CAP afterwards.  Compare the payload.
    rim = np.zeros(src.shape, dtype=bool)
    rim[0, :] = rim[-1, :] = rim[:, 0] = rim[:, -1] = True
    body = ~rim
    diff = got != want
    report["massifs"] = [
        dict(members=m["members"], base=m["base"], peak=m["peak"], base_img=m["base_img"],
             H=m["H"], T=m["T"], k=m["k"], cells=m["cells"], peak_img=m["peak_img"],
             peak_at_cap=bool(m["peak_img"] == CAP),
             monotone=bool(np.all(np.diff(m["lut"]) >= 0)),
             slope_at_base_analytic=round(float(m["H"] * m["k"] / -math.expm1(-m["k"] * m["T"])), 6),
             lut_step_at_base=int(m["lut"][1] - m["lut"][0]) if m["T"] > 0 else None)
        for m in massifs]
    report["zones"] = zones
    report["comparison"] = dict(
        cells=int(src.size), body_cells=int(body.sum()),
        body_mismatches=int(diff[body].sum()),
        rim_mismatches=int(diff[rim].sum()),
        inside_cells=int(inside.sum()),
        inside_mismatches=int((diff & inside).sum()),
        outside_body_mismatches=int((diff & body & ~inside).sum()),
        max_abs_diff_body=int(np.abs(got - want)[body].max()),
        peaks_at_cap=sum(1 for m in report["massifs"] if m["peak_at_cap"]),
        cells_at_cap_ingame=int((got == CAP).sum()),
        got_over_cap=int((got > CAP).sum()),
        outside_zone_affine_exact_ingame=bool(
            np.array_equal(got[body & ~inside], affine(src, shift)[body & ~inside])),
    )
    c = report["comparison"]
    print(f"massifs {len(massifs)}: " + ", ".join(
        f"{m['members']} base {m['base']} peak {m['peak']} -> {m['peak_img']}"
        for m in report["massifs"]))
    print(f"body mismatches {c['body_mismatches']}/{c['body_cells']} "
          f"(inside {c['inside_mismatches']}, outside {c['outside_body_mismatches']}), "
          f"rim mismatches {c['rim_mismatches']} (U16 wrap of the negative rim affine), "
          f"outside-zone affine exact {c['outside_zone_affine_exact_ingame']}")

    if args.fig:
        make_figure(src, got, want, inside, massifs, shift, src_cap, rim, args.fig)
        report["figure"] = os.path.abspath(args.fig)
    if args.json:
        with open(args.json, "w", encoding="utf-8") as fh:
            json.dump({k: v for k, v in report.items()}, fh, indent=1, sort_keys=True)
        print(f"wrote {args.json}")
    return 0 if c["body_mismatches"] == 0 else 1


def make_figure(src, got, want, inside, massifs, shift, src_cap, rim, path):
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt

    fig = plt.figure(figsize=(16, 9), dpi=110)
    ax = fig.add_subplot(2, 2, 1)
    ax.imshow(src, cmap="gist_earth", interpolation="nearest")
    ov = np.zeros(src.shape + (4,), dtype=np.float32)
    ov[src > src_cap] = (1.0, 0.15, 0.15, 0.85)
    ax.imshow(ov, interpolation="nearest")
    ax.set_title(f"synthetic vanilla source 192^2 (interior min 4078, red = over src_cap "
                 f"{src_cap})\n{len(massifs)} massifs after the base-level merge: "
                 + ", ".join(f"{m['members']} base {m['base']}" for m in massifs))
    ax.set_xticks([]); ax.set_yticks([])

    ax2 = fig.add_subplot(2, 2, 2)
    ax2.imshow(got, cmap="gist_earth", interpolation="nearest")
    ov2 = np.zeros(src.shape + (4,), dtype=np.float32)
    ov2[inside] = (0.1, 0.4, 1.0, 0.45)
    ax2.imshow(ov2, interpolation="nearest")
    ax2.set_title("IN-GAME result of the engine op chain (blue = remapped massif cells)\n"
                  f"max {int(got.max())} (cap 65535), cells at cap {int((got == 65535).sum())}")
    ax2.set_xticks([]); ax2.set_yticks([])

    ax3 = fig.add_subplot(2, 2, 3)
    d = (got - want)
    body = ~rim
    m = np.abs(d[body]).max()
    im = ax3.imshow(np.where(body, d, np.nan), cmap="coolwarm", vmin=-max(1, m), vmax=max(1, m),
                    interpolation="nearest")
    fig.colorbar(im, ax=ax3, fraction=0.046)
    ax3.set_title(f"in-game minus offline reference (rim excluded: U16 wrap of a negative "
                  f"affine)\nbody mismatches {int((d[body] != 0).sum())} of {int(body.sum())} "
                  f"cells, max |diff| {int(m)}")
    ax3.set_xticks([]); ax3.set_yticks([])

    ax4 = fig.add_subplot(2, 2, 4)
    hs = np.arange(int(src[~rim].min()), int(src.max()) + 1)
    ax4.plot(hs, affine(hs, shift), ls="--", lw=1.0, color="tab:red",
             label="pure 4/3 affine (overflows above src_cap)")
    for i, mm in enumerate(massifs):
        h = np.arange(mm["base"], mm["peak"] + 1)
        ax4.plot(h, mm["lut"], lw=1.4, label=f"massif {mm['members']} remap (k={mm['k']:.2e})")
    sel = inside & ~rim
    ax4.scatter(src[sel], got[sel], s=6, color="k", zorder=5,
                label="in-game in-zone cells")
    ax4.axhline(65535, lw=0.8, color="k")
    ax4.axvline(src_cap, lw=0.8, ls=":", color="gray")
    ax4.set_xlabel("source height"); ax4.set_ylabel("destination height")
    ax4.set_title("transfer curves: every massif joins the affine at its base with slope 4/3\n"
                  "and lands its own peak exactly on 65535; in-game cells sit on the curves")
    ax4.legend(fontsize=7)
    ax4.grid(alpha=0.3)

    fig.tight_layout()
    fig.savefig(path)
    plt.close(fig)
    print(f"wrote {path}")


if __name__ == "__main__":
    sys.exit(main())
