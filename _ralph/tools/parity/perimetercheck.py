#!/usr/bin/env python3
"""Test stock perimeter mechanisms against exact 4/3 property-site membership.

The map loader requires ``PassBorder`` to be MapPatchSize-aligned.  This tool
keeps the production zero-difference rule intact and asks a narrower question:
can the engine's stock arbitrary-box passability hook represent the exact
source-border image on the expanded property's staggered lattice?

It consumes preserved ``property_probe.lua`` stamps, uses propertycheck.py's
measured alternating-row geometry, and reports three models:

* the ideal unaligned symmetric scalar;
* the tightest single axis-aligned interior rectangle; and
* row/column-striped edge thresholds suitable for stock
  ``terrain.ClearPassabilityBox`` calls during ``OnPassabilityRebuilding``.

The striped result is a representability proof, not an implementation or an
acceptance pass.  Buildability has a separate stock ``map_border`` input and is
explicitly not changed or scored here.
"""

from __future__ import annotations

import argparse
import json
from collections import Counter
from pathlib import Path

import numpy as np

import propertycheck


HERE = Path(__file__).resolve().parent
DEFAULT_OUT_DIR = HERE / "out"


def stamp_path(out_dir: Path, tag: str) -> Path:
    return out_dir / f"property-{tag}-property.txt"


def map_size_wu(stamp: propertycheck.ProbeStamp, env: str) -> tuple[float, float]:
    row = stamp.maps[env]
    return (
        float(row["height_gw"]) * float(row["tile"]),
        float(row["height_gh"]) * float(row["tile"]),
    )


def counts(expected: np.ndarray, actual: np.ndarray) -> dict[str, int]:
    return {
        "sites": int(expected.size),
        "differences": int(np.count_nonzero(expected != actual)),
        "source_border_but_candidate_interior": int(np.count_nonzero(expected & ~actual)),
        "source_interior_but_candidate_border": int(np.count_nonzero(~expected & actual)),
    }


def stripe_edge(
    expected_edge: np.ndarray,
    coordinate: np.ndarray,
    stripe: np.ndarray,
    low_side: bool,
) -> tuple[np.ndarray, dict[str, object]]:
    predicted = np.zeros(expected_edge.shape, dtype=bool)
    thresholds: list[tuple[int, float]] = []
    minimum_gap = float("inf")

    for stripe_id in np.unique(stripe):
        selected = stripe == stripe_id
        edge_values = coordinate[selected & expected_edge]
        other_values = coordinate[selected & ~expected_edge]
        if edge_values.size == 0 or other_values.size == 0:
            raise RuntimeError(f"stripe {stripe_id} does not discriminate both memberships")
        if low_side:
            edge_limit = float(edge_values.max())
            other_limit = float(other_values.min())
            gap = other_limit - edge_limit
        else:
            edge_limit = float(edge_values.min())
            other_limit = float(other_values.max())
            gap = edge_limit - other_limit
        if gap <= 0:
            raise RuntimeError(
                f"stripe {stripe_id} is not separable: edge={edge_limit}, other={other_limit}")
        threshold = (edge_limit + other_limit) / 2.0
        predicted[selected] = (
            coordinate[selected] < threshold if low_side else coordinate[selected] > threshold)
        thresholds.append((int(stripe_id), threshold))
        minimum_gap = min(minimum_gap, gap)

    if not np.array_equal(predicted, expected_edge):
        raise RuntimeError("constructed stripe thresholds do not reproduce their source edge")

    threshold_counts = Counter(threshold for _, threshold in thresholds)
    ordered = sorted(thresholds)
    runs = 0
    last_stripe: int | None = None
    last_threshold: float | None = None
    for stripe_id, threshold in ordered:
        if (last_stripe is None or stripe_id != last_stripe + 1
                or threshold != last_threshold):
            runs += 1
        last_stripe, last_threshold = stripe_id, threshold

    return predicted, {
        "stripes": len(thresholds),
        "minimum_separation_wu": minimum_gap,
        "distinct_thresholds_wu": [
            {"threshold": threshold, "stripes": count}
            for threshold, count in sorted(threshold_counts.items())
        ],
        "contiguous_equal_threshold_runs": runs,
    }


def score_environment(
    vanilla: propertycheck.ProbeStamp,
    expanded: propertycheck.ProbeStamp,
    env: str,
) -> dict[str, object]:
    mapping = propertycheck.map_sites(vanilla, expanded, env)
    vgeometry = propertycheck.geometry_for(vanilla, env)
    egeometry = propertycheck.geometry_for(expanded, env)
    vgw, vgh = propertycheck.dims(vanilla, env)
    sy, sx = np.indices((vgh, vgw), dtype=np.float64)
    vanilla_world = propertycheck.storage_to_world(vgeometry, sx.ravel(), sy.ravel())
    ex = np.asarray(mapping["ex"]).ravel()
    ey = np.asarray(mapping["ey"]).ravel()
    expanded_world = propertycheck.storage_to_world(egeometry, ex, ey)

    vwidth, vheight = map_size_wu(vanilla, env)
    ewidth, eheight = map_size_wu(expanded, env)
    border = float(vanilla.maps[env]["pass_border"])
    scale = float(mapping["scale"])

    left = vanilla_world[0] < border
    right = vanilla_world[0] > vwidth - border
    top = vanilla_world[1] < border
    bottom = vanilla_world[1] > vheight - border
    source_border = left | right | top | bottom

    ideal = border * scale
    ideal_border = (
        (expanded_world[0] < ideal)
        | (expanded_world[0] > ewidth - ideal)
        | (expanded_world[1] < ideal)
        | (expanded_world[1] > eheight - ideal)
    )

    source_interior = ~source_border
    interior_x = expanded_world[0, source_interior]
    interior_y = expanded_world[1, source_interior]
    rectangle = {
        "minx": float(interior_x.min()),
        "maxx": float(interior_x.max()),
        "miny": float(interior_y.min()),
        "maxy": float(interior_y.max()),
    }
    rectangle_border = ~(
        (expanded_world[0] >= rectangle["minx"])
        & (expanded_world[0] <= rectangle["maxx"])
        & (expanded_world[1] >= rectangle["miny"])
        & (expanded_world[1] <= rectangle["maxy"])
    )

    left_pred, left_report = stripe_edge(left, expanded_world[0], ey, True)
    right_pred, right_report = stripe_edge(right, expanded_world[0], ey, False)
    top_pred, top_report = stripe_edge(top, expanded_world[1], ex, True)
    bottom_pred, bottom_report = stripe_edge(bottom, expanded_world[1], ex, False)
    striped_border = left_pred | right_pred | top_pred | bottom_pred

    # Anti-vacuity control: replacing the exact striped result with the tightest
    # single rectangle must expose the staggered-lattice boundary conflict.
    rectangle_counts = counts(source_border, rectangle_border)
    if rectangle_counts["differences"] == 0:
        raise RuntimeError("single-rectangle negative control unexpectedly passed")
    striped_counts = counts(source_border, striped_border)
    if striped_counts["differences"] != 0:
        raise RuntimeError("striped stock-box model failed exact membership")

    return {
        "scale": scale,
        "vanilla_pass_border": border,
        "expanded_ideal_border": ideal,
        "mapped_sites": int(mapping["sites"]),
        "exact_world_sites": int(mapping["exact_world_sites"]),
        "source_border_sites": int(source_border.sum()),
        "ideal_unaligned_scalar": counts(source_border, ideal_border),
        "tightest_single_rectangle": {
            "interior_world_box": rectangle,
            **rectangle_counts,
        },
        "stock_clear_box_stripes": {
            "membership": striped_counts,
            "edges": {
                "left": left_report,
                "right": right_report,
                "top": top_report,
                "bottom": bottom_report,
            },
            "total_edge_stripes": sum(
                edge["stripes"]
                for edge in (left_report, right_report, top_report, bottom_report)
            ),
            "representable_exactly": striped_counts["differences"] == 0,
        },
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--vanilla", required=True)
    parser.add_argument("--expanded", required=True)
    parser.add_argument("--out", type=Path, required=True)
    parser.add_argument("--dump-dir", type=Path, default=DEFAULT_OUT_DIR)
    args = parser.parse_args()

    vanilla = propertycheck.parse_probe_stamp(stamp_path(args.dump_dir, args.vanilla))
    expanded = propertycheck.parse_probe_stamp(stamp_path(args.dump_dir, args.expanded))
    maps = {
        env: score_environment(vanilla, expanded, env)
        for env in ("surface", "underground")
    }
    report = {
        "schema": "smr.perimetercheck.v1",
        "inputs": {"vanilla": args.vanilla, "expanded": args.expanded},
        "production_gate_changed": False,
        "source_trace": {
            "passability_candidate": (
                "CommonLua/Classes/marker.lua:771-778: ForcedImpassableMarker handles "
                "OnPassabilityRebuilding and calls terrain.ClearPassabilityBox for every "
                "intersecting arbitrary box"),
            "play_area_limit": (
                "CommonLua/Core/map.lua:967-1001: Map:SetPlayArea stores an arbitrary box, "
                "but callers use it for camera/query clamping; it is not a pass-grid writer"),
            "buildability_limit": (
                "Lua/BuildableGrid.lua:57-75: stock InitBuildableGrid receives one scalar "
                "map_border; no arbitrary buildability mask is established by this trace"),
        },
        "interpretation": {
            "passability": (
                "The stock rebuild-time ClearPassabilityBox hook can represent exact mapped "
                "border membership when thresholds are derived per target lattice stripe."),
            "not_yet_proven": (
                "No live mutation was performed; box boundary semantics and a general compact "
                "stripe construction still require an engine probe before payload work."),
            "buildability": (
                "This result does not solve or relax buildability parity; its stock path remains "
                "a separate scalar map_border input."),
        },
        "maps": maps,
        "gate_ok": all(
            data["stock_clear_box_stripes"]["representable_exactly"]
            for data in maps.values()
        ),
    }
    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(report, indent=2))
    return 0 if report["gate_ok"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
