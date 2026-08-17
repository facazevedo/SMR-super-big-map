#!/usr/bin/env python3
"""Bind the production Lua pass-border derivation to the preserved exact report."""

from __future__ import annotations

import argparse
import json
import math
import shutil
import subprocess
from pathlib import Path


HERE = Path(__file__).resolve().parent
PROJECT = HERE.parents[2]


def fields(line: str) -> dict[str, str]:
    return dict(part.split("=", 1) for part in line.split(",")[1:] if "=" in part)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--report", type=Path, required=True)
    parser.add_argument("--out", type=Path, required=True)
    args = parser.parse_args()

    lua = shutil.which("lua")
    if not lua:
        raise SystemExit("lua interpreter unavailable")
    module = PROJECT / "Code" / "sbm_pass_border.lua"
    stub = HERE / "passborderderive_stub.lua"
    run = subprocess.run(
        [lua, str(stub), str(module)], text=True, capture_output=True, check=False)
    if run.returncode != 0:
        raise SystemExit(f"production Lua derivation failed:\n{run.stdout}{run.stderr}")
    lines = [line for line in run.stdout.splitlines() if line.strip()]
    if not lines or not lines[0].startswith("stats,"):
        raise SystemExit("production Lua derivation emitted no stats")
    actual_stats = fields(lines[0])
    actual_boxes = []
    for line in lines[1:]:
        if not line.startswith("box,"):
            raise SystemExit(f"unexpected Lua output: {line}")
        row = fields(line)
        actual_boxes.append({
            "minx": int(row["minx"]), "miny": int(row["miny"]),
            "maxx": int(row["maxx"]), "maxy": int(row["maxy"]),
        })

    report = json.loads(args.report.read_text(encoding="utf-8"))
    compact = report["maps"]["surface"]["compact_closed_box_union"]
    expected_boxes = [
        {
            "minx": math.floor(float(row["minx"])),
            "miny": math.floor(float(row["miny"])),
            "maxx": math.ceil(float(row["maxx"])),
            "maxy": math.ceil(float(row["maxy"])),
        }
        for row in compact["boxes"]
    ]
    expected_stats = {
        "boxes": str(compact["total_boxes"]),
        "core": str(compact["core_boxes"]),
        "fringe": str(compact["fringe_boxes"]),
        "fringe_sites": str(compact["fringe_sites"]),
        "mapped": str(report["maps"]["surface"]["mapped_sites"]),
        "border": str(report["maps"]["surface"]["source_border_sites"]),
        "source_gw": "615", "source_gh": "710",
        "expanded_gw": "820", "expanded_gh": "946",
        "orientation": str(compact["fringe_orientation"]),
    }
    stat_checks = {
        key: actual_stats.get(key) == expected
        for key, expected in expected_stats.items()
    }
    source_text = module.read_text(encoding="utf-8")
    forbidden_literals = ["136000", "683500", "33S163E", "5907906148490074980", "t97"]
    literal_hits = [literal for literal in forbidden_literals if literal in source_text]
    first_difference = None
    for index, (actual, expected) in enumerate(zip(actual_boxes, expected_boxes), start=1):
        if actual != expected:
            first_difference = {"index": index, "actual": actual, "expected": expected}
            break
    gate_ok = (
        len(actual_boxes) == len(expected_boxes)
        and first_difference is None
        and all(stat_checks.values())
        and not literal_hits
    )
    result = {
        "schema": "smr.passborderderivecheck.v1",
        "gate_ok": gate_ok,
        "production_module": str(module),
        "preserved_report": str(args.report.resolve()),
        "lua_returncode": run.returncode,
        "actual_box_count": len(actual_boxes),
        "expected_box_count": len(expected_boxes),
        "all_boxes_identical_in_order": first_difference is None
        and len(actual_boxes) == len(expected_boxes),
        "first_box_difference": first_difference,
        "stat_checks": stat_checks,
        "actual_stats": actual_stats,
        "forbidden_coordinate_or_scenario_literals": literal_hits,
    }
    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_text(json.dumps(result, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(result, indent=2))
    return 0 if gate_ok else 1


if __name__ == "__main__":
    raise SystemExit(main())
