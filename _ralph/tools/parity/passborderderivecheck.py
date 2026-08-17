#!/usr/bin/env python3
"""Bind the production Lua pass-border derivation to the preserved exact report."""

from __future__ import annotations

import argparse
import json
import math
import shutil
import subprocess
import tempfile
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
    source_text = module.read_text(encoding="utf-8")
    promotion_sites = [
        "(expanded_gw * source_w + 0.0) / desired_w",
        "(expanded_gh * source_h + 0.0) / desired_h",
        "(desired_w + 0.0) / source_w",
        "(desired_h + 0.0) / source_h",
    ]
    run = subprocess.run(
        [lua, str(stub), str(module)], text=True, capture_output=True, check=False)
    if run.returncode != 0:
        raise SystemExit(f"production Lua derivation failed:\n{run.stdout}{run.stderr}")
    lines = [line for line in run.stdout.splitlines() if line.strip()]
    if not lines or not lines[0].startswith("stats,"):
        raise SystemExit("production Lua derivation emitted no stats")
    actual_stats = fields(lines[0])
    actual_boxes = []
    idiv_control = None
    for line in lines[1:]:
        if line.startswith("idiv_control,"):
            if idiv_control is not None:
                raise SystemExit("production Lua derivation emitted duplicate idiv controls")
            idiv_control = fields(line)
            continue
        if not line.startswith("box,"):
            raise SystemExit(f"unexpected Lua output: {line}")
        row = fields(line)
        actual_boxes.append({
            "minx": int(row["minx"]), "miny": int(row["miny"]),
            "maxx": int(row["maxx"]), "maxy": int(row["maxy"]),
            "kind": row["kind"],
        })

    report = json.loads(args.report.read_text(encoding="utf-8"))
    compact = report["maps"]["surface"]["compact_closed_box_union"]
    expected_boxes = [
        {
            "minx": math.floor(float(row["minx"])),
            "miny": (math.ceil(float(row["miny"]))
                     if str(row["kind"]).startswith("fringe_")
                     else math.floor(float(row["miny"]))),
            "maxx": math.ceil(float(row["maxx"])),
            "maxy": math.ceil(float(row["maxy"])),
            "kind": str(row["kind"]),
        }
        for row in compact["boxes"]
    ]
    previous_outward_boxes = [
        {**row, "miny": math.floor(float(source["miny"]))}
        for row, source in zip(expected_boxes, compact["boxes"])
    ]
    inward_changed_indices = [
        index for index, (old, new) in enumerate(
            zip(previous_outward_boxes, expected_boxes), start=1)
        if old != new
    ]
    quantization_checks = {
        "core_boxes_keep_outward_lower_y": all(
            actual["miny"] == math.floor(float(source["miny"]))
            for actual, source in zip(actual_boxes, compact["boxes"])
            if str(source["kind"]).startswith("core_")),
        "all_fringe_boxes_use_inward_lower_y": all(
            actual["miny"] == math.ceil(float(source["miny"]))
            for actual, source in zip(actual_boxes, compact["boxes"])
            if str(source["kind"]).startswith("fringe_")),
        "inward_policy_changes_at_least_one_box": bool(inward_changed_indices),
    }
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
    expected_idiv_control = {
        "promotions": "4",
        "unpromoted_source_gw": "615",
        "unpromoted_source_gh": "709",
        "promoted_source_gw": "615",
        "promoted_source_gh": "710",
        "unpromoted_scale": "1.000000",
        "promoted_scale": "1.333333",
    }
    idiv_checks = {
        key: idiv_control is not None and idiv_control.get(key) == expected
        for key, expected in expected_idiv_control.items()
    }
    missing_promotion_controls = []
    temp_root = PROJECT / "_ralph" / "tmp"
    with tempfile.TemporaryDirectory(
            prefix=".tmp_fzp_passborderderive_", dir=temp_root) as temp_dir:
        for index, promotion in enumerate(promotion_sites, start=1):
            occurrence_count = source_text.count(promotion)
            demoted_source = source_text.replace(
                promotion, promotion.replace(" + 0.0", ""), 1)
            demoted_module = Path(temp_dir) / f"sbm_pass_border_missing_{index}.lua"
            demoted_module.write_text(demoted_source, encoding="utf-8")
            control_run = subprocess.run(
                [lua, str(stub), str(demoted_module)],
                text=True, capture_output=True, check=False)
            diagnostic = control_run.stdout + control_run.stderr
            missing_promotion_controls.append({
                "site": promotion,
                "source_occurrences": occurrence_count,
                "returncode": control_run.returncode,
                "rejected": control_run.returncode != 0
                and "lacks explicit float promotion" in diagnostic,
            })
    missing_promotion_controls_ok = all(
        row["source_occurrences"] == 1 and row["rejected"]
        for row in missing_promotion_controls
    )
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
        and all(quantization_checks.values())
        and all(idiv_checks.values())
        and missing_promotion_controls_ok
        and not literal_hits
    )
    result = {
        "schema": "smr.passborderderivecheck.v3",
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
        "quantization_checks": quantization_checks,
        "inward_lower_y_changed_box_count": len(inward_changed_indices),
        "inward_lower_y_changed_box_indices": inward_changed_indices,
        "integer_division_control_checks": idiv_checks,
        "integer_division_control": idiv_control,
        "missing_promotion_controls_ok": missing_promotion_controls_ok,
        "missing_promotion_controls": missing_promotion_controls,
        "forbidden_coordinate_or_scenario_literals": literal_hits,
    }
    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_text(json.dumps(result, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(result, indent=2))
    return 0 if gate_ok else 1


if __name__ == "__main__":
    raise SystemExit(main())
