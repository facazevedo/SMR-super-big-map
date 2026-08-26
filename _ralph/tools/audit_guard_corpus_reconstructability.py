#!/usr/bin/env python3
"""Audit whether the accepted guard corpus can be rebuilt after generation.

This is a fail-closed source audit.  It does not claim that a corpus cannot be
captured at the preparation boundary; it checks the narrower iteration-88
hypothesis that both ordered calls can be reconstructed later from public map
state without observing or changing PrepareOuterResourceTerrain.
"""

from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path


SCHEMA = "smr.ralph.guard_corpus_reconstructability.v1"


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest().upper()


def line_of(lines: list[str], needle: str, *, start: int = 0) -> int:
    for index in range(start, len(lines)):
        if needle in lines[index]:
            return index + 1
    raise ValueError(f"required source token is missing: {needle}")


def ordered_lines(lines: list[str], needles: list[str]) -> list[int]:
    result: list[int] = []
    cursor = 0
    for needle in needles:
        found = line_of(lines, needle, start=cursor)
        result.append(found)
        cursor = found
    return result


def audit(terrain_path: Path, generation_path: Path) -> dict:
    terrain = terrain_path.read_text(encoding="utf-8").splitlines()
    generation = generation_path.read_text(encoding="utf-8").splitlines()

    function_start = line_of(terrain, "local function PrepareOuterResourceTerrain(map)")
    function_end = line_of(terrain, "local function AuditOuterResourceTerrain(map)") - 1
    body = terrain[function_start - 1:function_end]

    transient_guard = line_of(terrain, "local protected_ready_sites = {}", start=function_start - 1)
    transient_patches = line_of(terrain, "local patches, resource_sites, rocket_sites = {}, {}, {}",
                                start=function_start - 1)
    adaptive_dependency = ordered_lines(terrain, [
        "local maximum_core_delta = 0",
        "local old = grid_value(patch.cx + dx, patch.cy + dy)",
        "patch.outer_cells = patch.core_cells",
    ])
    guard_use = line_of(terrain, "for _, protected in ipairs(protected_ready_sites) do",
                        start=function_start - 1)
    public_overwrites = ordered_lines(terrain, [
        "map.SuperBigMapOuterResourceTerrainSites = resource_sites",
        "map.SuperBigMapOuterResourceRocketPads = rocket_sites",
        "map.SuperBigMapOuterResourceTerrainReport = report",
    ])
    prior_read = line_of(terrain,
                         "if type(map.SuperBigMapOuterResourceTerrainSites) == \"table\" then",
                         start=function_start - 1)
    repair_loop = line_of(generation,
                          "while resource_terrain_ok ~= true and terrain_repair_attempt < 2")
    repair_call = line_of(generation, "TerrainCopy.PrepareOuterResourceTerrain, map",
                          start=repair_loop - 1)

    forbidden_publications = (
        "SuperBigMapOuterResourceProtectedReadySites",
        "SuperBigMapOuterResourceTerrainPatches",
        "SuperBigMapOuterResourceGuardCorpusHistory",
    )
    absent_publications = [token for token in forbidden_publications
                           if not any(token in row for row in body)]

    checks = {
        "preparation_has_transient_guard_list": transient_guard < function_end,
        "preparation_has_transient_patch_list": transient_patches < function_end,
        "guard_checks_consume_transient_list": guard_use < function_end,
        "pass_radius_depends_on_pre_apply_grid": all(
            function_start <= row <= function_end for row in adaptive_dependency
        ),
        "repair_can_invoke_preparation_again": repair_loop < repair_call,
        "prior_sites_are_read_before_overwrite": prior_read < public_overwrites[0],
        "public_state_is_overwritten_not_appended": all(
            "=" in terrain[row - 1] and "History" not in terrain[row - 1]
            for row in public_overwrites
        ),
        "no_guard_patch_history_publication": len(absent_publications) == len(forbidden_publications),
    }
    source_audit_ok = all(checks.values())

    reasons = [
        {
            "id": "call_history_lost",
            "evidence_lines": {
                "prior_sites_read": prior_read,
                "sites_overwritten": public_overwrites[0],
                "bounded_repair_loop": repair_loop,
                "repair_call": repair_call,
            },
            "detail": (
                "A repair call consumes the previous site table and then replaces it; "
                "post-generation public state cannot distinguish both ordered calls."
            ),
        },
        {
            "id": "ordered_guards_not_published",
            "evidence_lines": {
                "local_guard_list": transient_guard,
                "guard_iteration": guard_use,
            },
            "detail": (
                "The exact protected-ready ordered list exists only as a function local and "
                "has no public history field."
            ),
        },
        {
            "id": "ordered_passes_not_published",
            "evidence_lines": {
                "local_patch_list": transient_patches,
                "adaptive_delta": adaptive_dependency[0],
                "pre_apply_grid_read": adaptive_dependency[1],
                "outer_radius_update": adaptive_dependency[2],
            },
            "detail": (
                "Each shaping pass radius depends on a transient patch and height samples from "
                "the grid as it existed before that call; the final grid and count-only report "
                "do not retain those values."
            ),
        },
    ]

    return {
        "schema": SCHEMA,
        "source_audit_ok": source_audit_ok,
        "exact_post_generation_reconstruction_possible": False if source_audit_ok else None,
        "scope": (
            "accepted PrepareOuterResourceTerrain ordered guards and shaping/core passes for "
            "all initial/repair calls"
        ),
        "terrain_source": {
            "path": terrain_path.as_posix(),
            "sha256": sha256(terrain_path),
            "function_start_line": function_start,
            "function_end_line": function_end,
        },
        "generation_source": {
            "path": generation_path.as_posix(),
            "sha256": sha256(generation_path),
        },
        "checks": checks,
        "reasons": reasons,
        "conclusion": (
            "An exact corpus requires a boundary-time observation or an independently preserved "
            "pre-call snapshot; accepted post-generation public state alone is insufficient."
        ) if source_audit_ok else "Source shape changed; no conclusion is authorized.",
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--terrain", type=Path, default=Path("Code/sbm_terrain_copy.lua"))
    parser.add_argument("--generation", type=Path, default=Path("Code/sbm_map_generation.lua"))
    parser.add_argument("--out", type=Path, required=True)
    args = parser.parse_args()
    report = audit(args.terrain.resolve(), args.generation.resolve())
    args.out.resolve().parent.mkdir(parents=True, exist_ok=True)
    args.out.resolve().write_text(json.dumps(report, indent=2, sort_keys=True) + "\n",
                                  encoding="utf-8")
    print(json.dumps(report, indent=2, sort_keys=True))
    return 0 if report["source_audit_ok"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
