#!/usr/bin/env python3
"""Score the self-restoring live ClearPassabilityBox perimeter probe."""

from __future__ import annotations

import argparse
import csv
import json
from pathlib import Path


def parse(path: Path) -> tuple[dict[str, dict], list[dict[str, str]]]:
    meta: dict[str, dict] = {}
    data_lines: list[str] = []
    for line in path.read_text(encoding="utf-8").splitlines():
        if line.startswith("#meta,"):
            parts = line.split(",")
            env = parts[1]
            meta.setdefault(env, {})["meta"] = dict(p.split("=", 1) for p in parts[2:])
        elif line.startswith("#box,"):
            _, env, _box_id, x0, y0, x1, y1 = line.split(",")
            meta.setdefault(env, {}).setdefault("boxes", []).append(
                (int(x0), int(y0), int(x1), int(y1)))
        elif line.startswith("#hash,"):
            parts = line.split(",")
            env = parts[1]
            meta.setdefault(env, {})["hashes"] = dict(p.split("=", 1) for p in parts[2:])
        elif line and not line.startswith("#"):
            data_lines.append(line)
    rows = list(csv.DictReader(data_lines))
    return meta, rows


def inside(value: int, low: int, high: int,
           low_inclusive: bool, high_inclusive: bool) -> bool:
    return (value >= low if low_inclusive else value > low) and (
        value <= high if high_inclusive else value < high)


def score_env(env: str, info: dict, rows: list[dict[str, str]]) -> dict:
    env_rows = [row for row in rows if row["env"] == env]
    boxes = info["boxes"]
    hashes = info["hashes"]
    numeric = [{key: int(value) for key, value in row.items() if key != "env"}
               for row in env_rows]

    stage_diffs = {
        "direct_vs_baseline": sum(r["p_direct"] != r["p0"] for r in numeric),
        "bare_vs_baseline": sum(r["p_bare"] != r["p0"] for r in numeric),
        "marker1_vs_direct": sum(r["p_marker1"] != r["p_direct"] for r in numeric),
        "marker2_vs_marker1": sum(r["p_marker2"] != r["p_marker1"] for r in numeric),
        "cleanup_vs_baseline": sum(r["p_cleanup"] != r["p0"] for r in numeric),
    }
    direct_blocked = sum(r["p0"] == 1 and r["p_direct"] == 0 for r in numeric)
    direct_unblocked = sum(r["p0"] == 0 and r["p_direct"] == 1 for r in numeric)

    conventions = []
    exact_names = []
    for xmin_inc in (False, True):
        for xmax_inc in (False, True):
            for ymin_inc in (False, True):
                for ymax_inc in (False, True):
                    name = (
                        f"x{'[' if xmin_inc else '('}min,max{']' if xmax_inc else ')'}_"
                        f"y{'[' if ymin_inc else '('}min,max{']' if ymax_inc else ')'}"
                    )
                    differences = 0
                    for row in numeric:
                        expected = row["p0"] == 1 and any(
                            inside(row["x"], x0, x1, xmin_inc, xmax_inc)
                            and inside(row["y"], y0, y1, ymin_inc, ymax_inc)
                            for x0, y0, x1, y1 in boxes
                        )
                        actual = row["p0"] == 1 and row["p_direct"] == 0
                        differences += expected != actual
                    conventions.append({"name": name, "differences": differences})
                    if differences == 0:
                        exact_names.append(name)

    checks = {
        "two_boxes": len(boxes) == 2,
        "samples_present": len(numeric) > 0,
        "direct_write_observable": direct_blocked > 0,
        "direct_never_unblocks": direct_unblocked == 0,
        "bare_rebuild_restores_local": stage_diffs["bare_vs_baseline"] == 0,
        "marker_replay_matches_direct_local": stage_diffs["marker1_vs_direct"] == 0,
        "marker_repeat_is_stable_local": stage_diffs["marker2_vs_marker1"] == 0,
        "cleanup_restores_local": stage_diffs["cleanup_vs_baseline"] == 0,
        "bare_rebuild_restores_hash": hashes["bare"] == hashes["baseline"],
        "marker_replay_matches_direct_hash": hashes["marker1"] == hashes["direct"],
        "marker_repeat_is_stable_hash": hashes["marker2"] == hashes["marker1"],
        "cleanup_restores_hash": hashes["cleanup"] == hashes["baseline"],
        "boundary_convention_exact": bool(exact_names),
        "boundary_controls_nonvacuous": sum(c["differences"] > 0 for c in conventions) >= 3,
    }
    return {
        "samples": len(numeric),
        "boxes": [list(box) for box in boxes],
        "selection": {key: int(value) for key, value in info["meta"].items()},
        "hashes": hashes,
        "stage_differences": stage_diffs,
        "direct_blocked": direct_blocked,
        "direct_unblocked": direct_unblocked,
        "boundary_conventions": conventions,
        "exact_boundary_conventions": exact_names,
        "checks": checks,
        "gate_ok": all(checks.values()),
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--probe", type=Path, required=True)
    parser.add_argument("--out", type=Path, required=True)
    args = parser.parse_args()

    meta, rows = parse(args.probe)
    maps = {env: score_env(env, meta[env], rows) for env in ("surface", "underground")}
    common = sorted(set(maps["surface"]["exact_boundary_conventions"])
                    & set(maps["underground"]["exact_boundary_conventions"]))
    report = {
        "schema": "smr.perimeterprobecheck.v1",
        "probe": str(args.probe),
        "maps": maps,
        "common_exact_boundary_conventions": common,
        "checks": {
            "surface_gate": maps["surface"]["gate_ok"],
            "underground_gate": maps["underground"]["gate_ok"],
            "same_boundary_semantics": bool(common),
        },
    }
    report["gate_ok"] = all(report["checks"].values())
    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(report, indent=2))
    return 0 if report["gate_ok"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
