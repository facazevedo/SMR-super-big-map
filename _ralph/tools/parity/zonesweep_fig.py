"""Plot the zone-coverage vs summit-slope tradeoff measured by `zonefit.py --factor-sweep`.

One knob controls the whole family: with average in-zone slope factor f (relative to the
4/3 similarity), a massif's compressed band is f/(1-f) x its overflow deep, so gentle
summits force deep bases and wide zones.  This renders that curve so the operating point is
a visible decision rather than a buried constant.

    python zonesweep_fig.py <factorsweep.json> <out.png>
"""

from __future__ import annotations

import json
import sys

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt


def main(argv):
    if len(argv) != 3:
        raise SystemExit(__doc__)
    with open(argv[1], encoding="utf-8") as fh:
        rep = json.load(fh)
    rows = rep["sweep"]
    t = rep["transform"]
    f = [r["factor"] for r in rows]
    pct = [r["pct_of_map"] for r in rows]
    nm = [r["massifs"] for r in rows]
    base = [r["deepest_base"] for r in rows]

    fig, (ax, ax2) = plt.subplots(1, 2, figsize=(15, 6.2), dpi=110)
    ax.plot(f, pct, "o-", color="tab:red", lw=1.8)
    for x, y, n in zip(f, pct, nm):
        ax.annotate(f"{y:.2f}%\n{n} massifs", (x, y), textcoords="offset points",
                    xytext=(6, 4), fontsize=7.5)
    ax.axhline(1.0, ls=":", lw=1.0, color="gray")
    ax.annotate("contract expectation ~1% of cells", (f[0], 1.0), fontsize=8,
                textcoords="offset points", xytext=(4, -12), color="gray")
    ax.set_yscale("log")
    ax.set_xlabel("average in-zone slope factor f (1.0 = exact 4/3 similarity)")
    ax.set_ylabel("share of the map inside compression zones (%)")
    ax.set_title("zone coverage explodes as the summits are kept gentle\n"
                 f"src_cap {t['src_cap']}, shift {t['shift']}, "
                 f"{rep['overflow']['zones']} overflow zones over "
                 f"{rep['overflow']['pct']:.3f}% of cells")
    ax.grid(alpha=0.3, which="both")

    ax2.plot(f, base, "o-", color="tab:blue", lw=1.8)
    ax2.axhline(t["src_cap"], ls="--", lw=1.0, color="k")
    ax2.annotate(f"src_cap {t['src_cap']}", (f[0], t["src_cap"]), fontsize=8,
                 textcoords="offset points", xytext=(4, 4))
    ax2.axhline(rep["source"]["interior_min"], ls=":", lw=1.0, color="gray")
    ax2.annotate(f"map floor {rep['source']['interior_min']}",
                 (f[0], rep["source"]["interior_min"]), fontsize=8,
                 textcoords="offset points", xytext=(4, 4), color="gray")
    ax2.set_xlabel("average in-zone slope factor f")
    ax2.set_ylabel("deepest massif base (source height units)")
    ax2.set_title("how far down the tallest massif's base must sit\n"
                  f"band depth = f/(1-f) x overflow; tallest overflow "
                  f"{rep['source']['full_max'] - t['src_cap']} units above src_cap")
    ax2.grid(alpha=0.3)

    fig.suptitle(rep.get("label", ""), fontsize=9)
    fig.tight_layout()
    fig.savefig(argv[2])
    print(f"wrote {argv[2]}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
