#!/usr/bin/env python3
"""Validate the generalized pre-Init/post-Init/post-Process BuildableGrid bundle."""

from __future__ import annotations

import argparse
import csv
import hashlib
import json
from contextlib import ExitStack
from pathlib import Path
from typing import Iterable


STAGES = ("preinit", "postinit", "postprocess-input", "postprocess-output", "shipped")
MAPS = ("surface", "underground")


def parse_fields(line: str, fixed: int) -> tuple[list[str], dict[str, str]]:
    parts = next(csv.reader([line.rstrip("\r\n")]))
    if len(parts) < fixed:
        raise ValueError(f"short record: {line!r}")
    fields: dict[str, str] = {}
    for item in parts[fixed:]:
        if "=" not in item:
            raise ValueError(f"non-key field after prefix: {item!r}")
        key, value = item.split("=", 1)
        if not key or key in fields:
            raise ValueError(f"invalid/duplicate key: {key!r}")
        fields[key] = value
    return parts[:fixed], fields


def parse_grid_header(line: str) -> dict[str, object]:
    prefix, fields = parse_fields(line, 1)
    if prefix != ["#schema=smr.ralph.buildphase.grid"]:
        raise ValueError(f"wrong grid schema: {prefix!r}")
    required = {"v", "map", "stage", "gw", "gh", "unbuildable_z"}
    if set(fields) != required:
        raise ValueError(f"grid header keys differ: {sorted(fields)}")
    header: dict[str, object] = dict(fields)
    for key in ("v", "gw", "gh", "unbuildable_z"):
        header[key] = int(fields[key])
    if header["v"] != 1 or header["map"] not in MAPS or header["stage"] not in STAGES:
        raise ValueError(f"unsupported grid header: {header!r}")
    if header["gw"] <= 0 or header["gh"] <= 0 or not 0 <= header["unbuildable_z"] <= 65535:
        raise ValueError(f"invalid grid bounds: {header!r}")
    return header


def parse_stamp(path: Path) -> tuple[dict[str, dict[str, str]], list[dict[str, str]], dict[str, int]]:
    maps: dict[str, dict[str, str]] = {}
    sites: list[dict[str, str]] = []
    object_counts: dict[str, int] = {}
    for line in path.read_text(encoding="utf-8").splitlines():
        if not line:
            continue
        kind = line.split(",", 1)[0]
        if kind == "map":
            prefix, fields = parse_fields(line, 2)
            maps[prefix[1]] = fields
        elif kind == "site":
            prefix, fields = parse_fields(line, 3)
            fields = dict(fields)
            fields.update(map=prefix[1], site_id=prefix[2])
            sites.append(fields)
        elif kind == "objects":
            prefix, fields = parse_fields(line, 2)
            object_counts[prefix[1]] = int(fields["collision_candidates"])
        else:
            raise ValueError(f"unknown stamp record: {kind!r}")
    return maps, sites, object_counts


def phase_classification(postinit: int, processed: int, sentinel: int) -> str:
    if postinit == sentinel:
        return "init_rejected"
    if processed == sentinel:
        return "process_rejected"
    return "remains_buildable"


def new_stats() -> dict[str, int]:
    return {
        "cells": 0,
        "preinit_not_sentinel": 0,
        "postinit_process_input_diff": 0,
        "processed_shipped_diff": 0,
        "postinit_sentinel": 0,
        "processed_sentinel": 0,
        "shipped_sentinel": 0,
    }


def update_stats(stats: dict[str, int], vectors: Iterable[tuple[int, int, int, int, int]], sentinel: int) -> None:
    for preinit, postinit, process_input, processed, shipped in vectors:
        stats["cells"] += 1
        stats["preinit_not_sentinel"] += preinit != sentinel
        stats["postinit_process_input_diff"] += postinit != process_input
        stats["processed_shipped_diff"] += processed != shipped
        stats["postinit_sentinel"] += postinit == sentinel
        stats["processed_sentinel"] += processed == sentinel
        stats["shipped_sentinel"] += shipped == sentinel


def score_map(base: Path, env: str, sites: list[dict[str, str]]) -> dict[str, object]:
    paths = [Path(f"{base}-{env}-{stage}.txt") for stage in STAGES]
    for path in paths:
        if not path.is_file():
            raise FileNotFoundError(path)
    stats = new_stats()
    focus = {(int(site["sx"]), int(site["sy"])) for site in sites if site["map"] == env}
    focus_values: dict[tuple[int, int], tuple[int, int, int, int, int]] = {}
    hashes = {stage: hashlib.sha256() for stage in STAGES}
    with ExitStack() as stack:
        files = [stack.enter_context(path.open("r", encoding="ascii", newline="")) for path in paths]
        header_lines = [handle.readline() for handle in files]
        for stage, line in zip(STAGES, header_lines):
            hashes[stage].update(line.encode("ascii"))
        headers = [parse_grid_header(line) for line in header_lines]
        first = headers[0]
        if any(
            header["map"] != env
            or header["stage"] != stage
            or header["gw"] != first["gw"]
            or header["gh"] != first["gh"]
            or header["unbuildable_z"] != first["unbuildable_z"]
            for stage, header in zip(STAGES, headers)
        ):
            raise ValueError(f"{env}: stage header disagreement")
        gw, gh, sentinel = int(first["gw"]), int(first["gh"]), int(first["unbuildable_z"])
        for y in range(gh):
            lines = [handle.readline() for handle in files]
            if any(not line for line in lines):
                raise ValueError(f"{env}: truncated at row {y}")
            for stage, line in zip(STAGES, lines):
                hashes[stage].update(line.encode("ascii"))
            stage_rows = []
            for stage, line in zip(STAGES, lines):
                try:
                    values = [int(value) for value in line.rstrip("\r\n").split(",")]
                except ValueError as exc:
                    raise ValueError(f"{env}/{stage}: non-integer row {y}") from exc
                if len(values) != gw or any(value < 0 or value > 65535 for value in values):
                    raise ValueError(f"{env}/{stage}: invalid row {y}")
                stage_rows.append(values)
            update_stats(stats, zip(*stage_rows), sentinel)
            for x, sy in focus:
                if sy == y:
                    focus_values[(x, y)] = tuple(row[x] for row in stage_rows)
        for stage, handle in zip(STAGES, files):
            tail = handle.read()
            if tail:
                hashes[stage].update(tail.encode("ascii"))
                if tail.strip():
                    raise ValueError(f"{env}/{stage}: extra nonblank rows")
    scored_sites = []
    for site in sites:
        if site["map"] != env:
            continue
        key = int(site["sx"]), int(site["sy"])
        if key not in focus_values:
            raise ValueError(f"{env}: focus site outside grid {key}")
        values = focus_values[key]
        stamped = tuple(int(site[name]) for name in ("preinit", "postinit", "postprocess", "shipped"))
        if stamped != (values[0], values[1], values[3], values[4]):
            raise ValueError(f"{env}: focus stamp/grid mismatch at {key}")
        scored_sites.append(
            {
                "site_id": int(site["site_id"]),
                "source_sx": int(site["source_sx"]),
                "source_sy": int(site["source_sy"]),
                "sx": key[0],
                "sy": key[1],
                "postinit": values[1],
                "postprocess": values[3],
                "shipped": values[4],
                "classification": phase_classification(values[1], values[3], sentinel),
            }
        )
    return {
        "gw": gw,
        "gh": gh,
        "sentinel": sentinel,
        **stats,
        "sites": scored_sites,
        "sha256": {stage: digest.hexdigest().upper() for stage, digest in hashes.items()},
    }


def score_bundle(base: Path) -> dict[str, object]:
    stamp_path = Path(f"{base}-buildphase.txt")
    object_path = Path(f"{base}-collision-objects.csv")
    maps, sites, stamped_object_counts = parse_stamp(stamp_path)
    collision_counts = {env: 0 for env in MAPS}
    with object_path.open("r", encoding="utf-8", newline="") as handle:
        reader = csv.DictReader(handle)
        required = {"map", "class", "entity", "handle", "x", "y", "bbox_minx", "bbox_maxx", "shape_nodes"}
        if reader.fieldnames is None or not required.issubset(reader.fieldnames):
            raise ValueError("collision-object columns incomplete")
        for row in reader:
            env = row["map"]
            if env not in collision_counts:
                raise ValueError(f"unknown collision-object map: {env!r}")
            collision_counts[env] += 1
    results = {env: score_map(base, env, sites) for env in MAPS}
    checks = {
        "both_maps_present": all(maps.get(env, {}).get("present") == "true" for env in MAPS),
        "six_surface_focus_sites": len([site for site in sites if site["map"] == "surface"]) == 6,
        "no_underground_focus_sites": not any(site["map"] == "underground" for site in sites),
        "preinit_all_sentinel": all(results[env]["preinit_not_sentinel"] == 0 for env in MAPS),
        "process_does_not_mutate_raw_input": all(
            results[env]["postinit_process_input_diff"] == 0 for env in MAPS
        ),
        "processed_equals_shipped": all(results[env]["processed_shipped_diff"] == 0 for env in MAPS),
        "collision_counts_match_stamp": collision_counts == stamped_object_counts,
        "collision_candidates_present": all(collision_counts[env] > 0 for env in MAPS),
        "stamp_diff_metrics_zero": all(
            maps[env].get("postinit_process_input_diff") == "0"
            and maps[env].get("processed_shipped_diff") == "0"
            for env in MAPS
        ),
    }
    return {
        "schema": "smr.ralph.buildphase.verdict",
        "schema_version": 1,
        "base": str(base),
        "maps": results,
        "collision_candidates": collision_counts,
        "checks": checks,
        "checks_total": len(checks),
        "checks_passed": sum(checks.values()),
        "checks_ok": all(checks.values()),
    }


def self_test() -> dict[str, object]:
    checks: dict[str, bool] = {}
    header = parse_grid_header(
        "#schema=smr.ralph.buildphase.grid,v=1,map=surface,stage=preinit,gw=2,gh=1,unbuildable_z=65535"
    )
    checks["header_parser"] = header == {
        "v": 1,
        "map": "surface",
        "stage": "preinit",
        "gw": 2,
        "gh": 1,
        "unbuildable_z": 65535,
    }
    try:
        parse_grid_header("#schema=bad,v=1,map=surface,stage=preinit,gw=2,gh=1,unbuildable_z=65535")
        checks["bad_schema_rejected"] = False
    except ValueError:
        checks["bad_schema_rejected"] = True
    stats = new_stats()
    update_stats(
        stats,
        [
            (65535, 100, 100, 100, 100),
            (65535, 200, 200, 65535, 65535),
            (65535, 65535, 65535, 65535, 65535),
        ],
        65535,
    )
    checks["synthetic_preinit_exact"] = stats["preinit_not_sentinel"] == 0
    checks["synthetic_raw_preserved"] = stats["postinit_process_input_diff"] == 0
    checks["synthetic_shipped_exact"] = stats["processed_shipped_diff"] == 0
    checks["classifies_init"] = phase_classification(65535, 65535, 65535) == "init_rejected"
    checks["classifies_process"] = phase_classification(200, 65535, 65535) == "process_rejected"
    checks["classifies_buildable"] = phase_classification(100, 100, 65535) == "remains_buildable"
    changed = new_stats()
    update_stats(changed, [(65535, 100, 101, 100, 101)], 65535)
    checks["detects_raw_mutation"] = changed["postinit_process_input_diff"] == 1
    checks["detects_shipped_mismatch"] = changed["processed_shipped_diff"] == 1
    return {
        "schema": "smr.ralph.buildphase.selftest",
        "schema_version": 1,
        "checks": checks,
        "checks_total": len(checks),
        "checks_passed": sum(checks.values()),
        "checks_ok": all(checks.values()),
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("base", nargs="?", type=Path)
    parser.add_argument("--self-test", action="store_true")
    parser.add_argument("--out", type=Path)
    args = parser.parse_args()
    if args.self_test:
        report = self_test()
    else:
        if args.base is None:
            parser.error("base is required unless --self-test is used")
        report = score_bundle(args.base)
    rendered = json.dumps(report, indent=2, sort_keys=True)
    if args.out:
        args.out.write_text(rendered + "\n", encoding="utf-8")
    print(rendered)
    return 0 if report["checks_ok"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
