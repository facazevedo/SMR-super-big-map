#!/usr/bin/env python3
"""Test stock perimeter mechanisms against exact 4/3 property-site membership.

The map loader requires ``PassBorder`` to be MapPatchSize-aligned.  This tool
keeps the production zero-difference rule intact and asks a narrower question:
can the engine's stock arbitrary-box passability hook represent the exact
source-border image on the expanded property's staggered lattice?

It consumes preserved ``property_probe.lua`` stamps, uses propertycheck.py's
measured alternating-row geometry, and reports three models:

* the ideal unaligned symmetric scalar;
* the tightest single axis-aligned interior rectangle;
* row/column-striped edge thresholds; and
* a compact, concrete union of closed stock boxes: four core edge slabs plus
  guarded runs for the mapped sites left on the interior rectangle boundary.

The striped result is a representability proof, not an implementation or an
acceptance pass.  Buildability has a separate stock ``map_border`` input and is
explicitly not changed or scored here.
"""

from __future__ import annotations

import argparse
import hashlib
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


def box_membership(world: np.ndarray, boxes: list[dict[str, object]]) -> np.ndarray:
    """Replay the live-proven closed-edge ClearPassabilityBox convention."""
    x, y = world
    predicted = np.zeros(x.shape, dtype=bool)
    for box in boxes:
        predicted |= (
            (x >= float(box["minx"]))
            & (x <= float(box["maxx"]))
            & (y >= float(box["miny"]))
            & (y <= float(box["maxy"]))
        )
    return predicted


def minimum_coordinate_gap(values: np.ndarray, name: str) -> float:
    distinct = np.unique(values)
    gaps = np.diff(distinct)
    positive = gaps[gaps > 0]
    if positive.size == 0:
        raise RuntimeError(f"mapped lattice has no positive {name} separation")
    return float(positive.min())


def fringe_run_boxes(
    expected: np.ndarray,
    missing: np.ndarray,
    world: np.ndarray,
    axis: str,
    guard_x: float,
    guard_y: float,
) -> list[dict[str, object]]:
    """Cover missing sites in maximal safe runs along one lattice axis.

    A run may bridge another expected-border site or empty lattice space, but
    never an interior site.  The guards are derived from the calibrated
    lattice's minimum coordinate gaps, so a run cannot touch the neighbouring
    parallel lattice line.
    """
    x, y = world
    fixed, along = (x, y) if axis == "vertical" else (y, x)
    guard_fixed, guard_along = (
        (guard_x, guard_y) if axis == "vertical" else (guard_y, guard_x)
    )
    boxes: list[dict[str, object]] = []
    for fixed_value in np.unique(fixed[missing]):
        on_line = fixed == fixed_value
        selected = sorted(float(value) for value in along[missing & on_line])
        forbidden = np.sort(along[(~expected) & on_line])
        if not selected:
            continue
        runs: list[list[float]] = [[selected[0]]]
        for value in selected[1:]:
            previous = runs[-1][-1]
            if bool(np.any((forbidden > previous) & (forbidden < value))):
                runs.append([value])
            else:
                runs[-1].append(value)
        for run in runs:
            fixed_min = float(fixed_value) - guard_fixed
            fixed_max = float(fixed_value) + guard_fixed
            along_min = min(run) - guard_along
            along_max = max(run) + guard_along
            if axis == "vertical":
                bounds = (fixed_min, along_min, fixed_max, along_max)
            else:
                bounds = (along_min, fixed_min, along_max, fixed_max)
            boxes.append({
                "kind": f"fringe_{axis}",
                "minx": bounds[0], "miny": bounds[1],
                "maxx": bounds[2], "maxy": bounds[3],
                "sites_in_run": len(run),
            })
    return boxes


def compact_box_union(
    expected: np.ndarray,
    world: np.ndarray,
) -> tuple[np.ndarray, dict[str, object], list[dict[str, object]]]:
    """Derive an exact compact closed-box union without scenario constants."""
    x, y = world
    interior = ~expected
    if not bool(interior.any()) or not bool(expected.any()):
        raise RuntimeError("border discriminator needs both border and interior sites")

    interior_bounds = {
        "minx": float(x[interior].min()),
        "maxx": float(x[interior].max()),
        "miny": float(y[interior].min()),
        "maxy": float(y[interior].max()),
    }
    lattice_bounds = {
        "minx": float(x.min()), "maxx": float(x.max()),
        "miny": float(y.min()), "maxy": float(y.max()),
    }
    core: list[dict[str, object]] = []
    core_specs = (
        ("core_left", x < interior_bounds["minx"], "x", "max"),
        ("core_right", x > interior_bounds["maxx"], "x", "min"),
        ("core_top", y < interior_bounds["miny"], "y", "max"),
        ("core_bottom", y > interior_bounds["maxy"], "y", "min"),
    )
    for kind, selected, coordinate, side in core_specs:
        if not bool(selected.any()):
            continue
        if coordinate == "x":
            edge = float(x[selected].max() if side == "max" else x[selected].min())
            minx, maxx = ((lattice_bounds["minx"], edge) if side == "max"
                          else (edge, lattice_bounds["maxx"]))
            miny, maxy = lattice_bounds["miny"], lattice_bounds["maxy"]
        else:
            edge = float(y[selected].max() if side == "max" else y[selected].min())
            miny, maxy = ((lattice_bounds["miny"], edge) if side == "max"
                          else (edge, lattice_bounds["maxy"]))
            minx, maxx = lattice_bounds["minx"], lattice_bounds["maxx"]
        core.append({
            "kind": kind, "minx": minx, "miny": miny,
            "maxx": maxx, "maxy": maxy,
        })

    core_prediction = box_membership(world, core)
    if bool(np.any(core_prediction & ~expected)):
        raise RuntimeError("core border slabs cover an expected-interior site")
    missing = expected & ~core_prediction

    gap_x = minimum_coordinate_gap(x, "x")
    gap_y = minimum_coordinate_gap(y, "y")
    # Strictly less than half a lattice gap keeps each guarded run on its own
    # calibrated coordinate line while giving singleton runs positive area.
    guard_x, guard_y = gap_x / 4.0, gap_y / 4.0
    candidates: list[tuple[str, list[dict[str, object]], np.ndarray]] = []
    for axis in ("vertical", "horizontal"):
        fringe = fringe_run_boxes(
            expected, missing, world, axis, guard_x, guard_y)
        boxes = core + fringe
        predicted = box_membership(world, boxes)
        if np.array_equal(predicted, expected):
            candidates.append((axis, boxes, predicted))
    if not candidates:
        raise RuntimeError("neither guarded fringe-run orientation is exact")
    axis, boxes, predicted = min(candidates, key=lambda item: len(item[1]))

    fringe = boxes[len(core):]
    serialized = json.dumps(boxes, sort_keys=True, separators=(",", ":"))
    report = {
        "interior_world_box": interior_bounds,
        "lattice_world_box": lattice_bounds,
        "minimum_coordinate_gap_wu": {"x": gap_x, "y": gap_y},
        "guard_wu": {"x": guard_x, "y": guard_y},
        "core_boxes": len(core),
        "fringe_sites": int(missing.sum()),
        "fringe_orientation": axis,
        "fringe_boxes": len(fringe),
        "fringe_run_size_counts": dict(sorted(Counter(
            int(box["sites_in_run"]) for box in fringe).items())),
        "total_boxes": len(boxes),
        "box_union_sha256": hashlib.sha256(serialized.encode("utf-8")).hexdigest(),
        "boxes": boxes,
    }
    return predicted, report, boxes


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
    compact_border, compact_report, compact_boxes = compact_box_union(
        source_border, expanded_world)

    # Anti-vacuity control: replacing the exact striped result with the tightest
    # single rectangle must expose the staggered-lattice boundary conflict.
    rectangle_counts = counts(source_border, rectangle_border)
    if rectangle_counts["differences"] == 0:
        raise RuntimeError("single-rectangle negative control unexpectedly passed")
    striped_counts = counts(source_border, striped_border)
    if striped_counts["differences"] != 0:
        raise RuntimeError("striped stock-box model failed exact membership")
    compact_counts = counts(source_border, compact_border)
    if compact_counts["differences"] != 0:
        raise RuntimeError("compact closed-box union failed exact membership")

    core_count = int(compact_report["core_boxes"])
    fringe_count = int(compact_report["fringe_boxes"])
    if core_count == 0 or fringe_count == 0:
        raise RuntimeError("compact-union controls require core and fringe boxes")
    drop_core = counts(
        source_border,
        box_membership(expanded_world, compact_boxes[1:]),
    )
    drop_fringe = counts(
        source_border,
        box_membership(expanded_world, compact_boxes[:-1]),
    )
    controls = {
        "drop_one_core_box": drop_core,
        "drop_one_fringe_box": drop_fringe,
        "both_controls_reject": (
            drop_core["differences"] > 0 and drop_fringe["differences"] > 0
        ),
    }
    if not controls["both_controls_reject"]:
        raise RuntimeError("compact closed-box negative control unexpectedly passed")

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
        "compact_closed_box_union": {
            "membership": compact_counts,
            **compact_report,
            "reduction_from_edge_stripes": {
                "boxes_saved": sum(
                    edge["stripes"]
                    for edge in (left_report, right_report, top_report, bottom_report)
                ) - int(compact_report["total_boxes"]),
                "fraction_saved": 1.0 - int(compact_report["total_boxes"]) / sum(
                    edge["stripes"]
                    for edge in (left_report, right_report, top_report, bottom_report)
                ),
            },
            "controls": controls,
            "representable_exactly": compact_counts["differences"] == 0,
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
        "schema": "smr.perimetercheck.v2",
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
                "border membership with a compact, data-derived closed-box union."),
            "not_yet_proven": (
                "Closed-edge box semantics and rebuild persistence are live-proven, but this "
                "complete compact union has not yet been replayed in the game."),
            "buildability": (
                "This result does not solve or relax buildability parity; its stock path remains "
                "a separate scalar map_border input."),
        },
        "maps": maps,
        "gate_ok": all(
            data["stock_clear_box_stripes"]["representable_exactly"]
            and data["compact_closed_box_union"]["representable_exactly"]
            and data["compact_closed_box_union"]["controls"]["both_controls_reject"]
            for data in maps.values()
        ),
    }
    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(report, indent=2))
    return 0 if report["gate_ok"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
