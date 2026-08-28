"""Prove v958's destination crease direct dispatch preserves the literal scalar trace."""

from __future__ import annotations

import json
import math
from pathlib import Path


ROOT = Path(__file__).resolve().parents[3]
TERRAIN = (ROOT / "Code" / "sbm_terrain_copy.lua").read_text(encoding="utf-8")
CONFIG = (ROOT / "Code" / "sbm_config.lua").read_text(encoding="utf-8")
METADATA = (ROOT / "metadata.lua").read_text(encoding="utf-8")


class TraceGrid:
    def __init__(self, cells: dict[tuple[int, int], object]):
        self.cells = dict(cells)
        self.trace: list[tuple[object, ...]] = []

    def get(self, x: int, y: int):
        self.trace.append(("get", x, y))
        return self.cells[(x, y)]

    def set(self, x: int, y: int, value: int):
        self.trace.append(("set", x, y, value))
        self.cells[(x, y)] = value


def literal(grid: TraceGrid, axis: str, along: int, lo: int, hi: int,
            join_lo: int, join_hi: int, offset: int, maximum: int) -> int:
    modified = 0

    def at(perp: int):
        return grid.get(perp, along) if axis == "x" else grid.get(along, perp)

    def put(perp: int, value: int):
        if axis == "x":
            grid.set(perp, along, value)
        else:
            grid.set(along, perp, value)

    for perp in range(lo, hi + 1):
        original = at(perp)
        # bool is not a Lua number; keep the model honest about type-test skips.
        if isinstance(original, (int, float)) and not isinstance(original, bool):
            put(perp, min(maximum, original + offset))
            modified += 1
    if join_hi - join_lo >= 4:
        v0, v0_prev = at(join_lo), at(join_lo - 1)
        v1, v1_next = at(join_hi), at(join_hi + 1)
        if all(isinstance(value, (int, float)) and not isinstance(value, bool)
               for value in (v0, v0_prev, v1, v1_next)):
            slope0, slope1 = v0 - v0_prev, v1_next - v1
            span = join_hi - join_lo
            for perp in range(join_lo + 1, join_hi):
                t = (perp - join_lo + 0.0) / span
                smooth = t * t * t * (t * (t * 6 - 15) + 10)
                left = v0 + slope0 * (perp - join_lo)
                right = v1 + slope1 * (perp - join_hi)
                value = math.floor(left + (right - left) * smooth + 0.5)
                put(perp, max(0, min(maximum, value)))
                modified += 1
    return modified


def direct(grid: TraceGrid, axis: str, along: int, lo: int, hi: int,
           join_lo: int, join_hi: int, offset: int, maximum: int) -> int:
    modified = 0
    direct_get, direct_set = grid.get, grid.set
    if axis == "x":
        for perp in range(lo, hi + 1):
            original = direct_get(perp, along)
            if isinstance(original, (int, float)) and not isinstance(original, bool):
                direct_set(perp, along, min(maximum, original + offset))
                modified += 1
    else:
        for perp in range(lo, hi + 1):
            original = direct_get(along, perp)
            if isinstance(original, (int, float)) and not isinstance(original, bool):
                direct_set(along, perp, min(maximum, original + offset))
                modified += 1
    if join_hi - join_lo >= 4:
        if axis == "x":
            v0, v0_prev = direct_get(join_lo, along), direct_get(join_lo - 1, along)
            v1, v1_next = direct_get(join_hi, along), direct_get(join_hi + 1, along)
        else:
            v0, v0_prev = direct_get(along, join_lo), direct_get(along, join_lo - 1)
            v1, v1_next = direct_get(along, join_hi), direct_get(along, join_hi + 1)
        if all(isinstance(value, (int, float)) and not isinstance(value, bool)
               for value in (v0, v0_prev, v1, v1_next)):
            slope0, slope1 = v0 - v0_prev, v1_next - v1
            span = join_hi - join_lo
            for perp in range(join_lo + 1, join_hi):
                t = (perp - join_lo + 0.0) / span
                smooth = t * t * t * (t * (t * 6 - 15) + 10)
                left = v0 + slope0 * (perp - join_lo)
                right = v1 + slope1 * (perp - join_hi)
                value = math.floor(left + (right - left) * smooth + 0.5)
                value = max(0, min(maximum, value))
                if axis == "x":
                    direct_set(perp, along, value)
                else:
                    direct_set(along, perp, value)
                modified += 1
    return modified


def modeled_cases() -> list[dict[str, object]]:
    cases: list[dict[str, object]] = []
    for axis in ("x", "y"):
        for along in (0, 3, 11):
            for lo, hi in ((0, 0), (0, 7), (4, 11)):
                join_lo, join_hi = (
                    (0, 3) if hi == 0 else (1, 7) if lo == 0 else (3, 11)
                )
                for offset in (1, 257, 65535):
                    cells: dict[tuple[int, int], object] = {}
                    first = min(lo, join_lo - 1)
                    last = max(hi, join_hi + 1)
                    for perp in range(first, last + 1):
                        coord = (perp, along) if axis == "x" else (along, perp)
                        value: object = (perp * 7919 + along * 104729 + offset) % 65536
                        if (perp + along + offset) % 7 == 0:
                            value = "missing"
                        cells[coord] = value
                    old, new = TraceGrid(cells), TraceGrid(cells)
                    old_count = literal(
                        old, axis, along, lo, hi, join_lo, join_hi, offset, 65535
                    )
                    new_count = direct(
                        new, axis, along, lo, hi, join_lo, join_hi, offset, 65535
                    )
                    cases.append({
                        "axis": axis,
                        "along": along,
                        "lo": lo,
                        "hi": hi,
                        "join_lo": join_lo,
                        "join_hi": join_hi,
                        "offset": offset,
                        "modified_exact": old_count == new_count,
                        "trace_exact": old.trace == new.trace,
                        "grid_exact": old.cells == new.cells,
                    })
    return cases


hot_start = TERRAIN.index("if direct_dispatch_requested then", TERRAIN.index("local perp0"))
hot_end = TERRAIN.index("selected.modified = modified", hot_start)
hot = TERRAIN[hot_start:hot_end]
static_checks = {
    "default_on_and_compiled": (
        "config.OptimizeHeightStepDirectGridDispatch = true" in CONFIG
        and "C.OPTIMIZE_HEIGHT_STEP_DIRECT_GRID_DISPATCH =" in CONFIG
        and 'cfg_bool("OPTIMIZE_HEIGHT_STEP_DIRECT_GRID_DISPATCH", true)' in TERRAIN
    ),
    "version_958": "'version', 958" in METADATA,
    "methods_and_axis_are_hoisted": all(token in hot for token in (
        'if selected.axis == "x" then',
        "direct_get(grid, p, along)",
        "direct_get(grid, along, p)",
        "direct_set(grid, p, along,",
        "direct_set(grid, along, p,",
        "v0, v0_prev = direct_get(grid, join_lo, along)",
        "v0, v0_prev = direct_get(grid, along, join_lo)",
        "direct_dispatch_feather_cells + feather_changed",
    )),
    "literal_scalar_fallback_retained": all(token in hot for token in (
        "else\n\t\t\t\t\t\t\t\tfor p = perp0, perp1 do",
        "local original = at(selected.axis, p, along)",
        "put(selected.axis, p, along,",
    )),
    "no_native_or_collection_allocation_in_dispatch": not any(token in hot for token in (
        "NewComputeGrid", ".new_instance", ":clone", ":copyrect", "GridRepack",
        "GridMulDivAdd", "GridAdd", "GridForeach", "{}",
    )),
    "telemetry_separates_translation_and_feather_cells": all(token in hot for token in (
        "local before_modified = modified",
        "local translated = modified - before_modified",
        "direct_dispatch_translation_cells + translated",
        "direct_dispatch_feather_cells + feather_changed",
    )),
}

cases = modeled_cases()
case_checks = {
    "all_modified_counts_exact": all(case["modified_exact"] for case in cases),
    "all_native_call_traces_exact": all(case["trace_exact"] for case in cases),
    "all_final_grids_exact": all(case["grid_exact"] for case in cases),
    "both_axes_covered": {case["axis"] for case in cases} == {"x", "y"},
    "clamp_and_nonnumeric_cases_covered": any(case["offset"] == 65535 for case in cases)
        and len(cases) == 54,
}

report = {
    "schema": "smr.ralph.destination_crease_direct_grid_dispatch_check",
    "schema_version": 1,
    "static_checks": static_checks,
    "case_checks": case_checks,
    "cases": cases,
    "ok": all(static_checks.values()) and all(case_checks.values()),
}
print(json.dumps(report, indent=2, sort_keys=True))
raise SystemExit(0 if report["ok"] else 1)
