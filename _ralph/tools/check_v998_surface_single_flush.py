#!/usr/bin/env python3
"""Fail-closed static contract for v998 Surface single-flush finalization."""

from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[2]
MAP = (ROOT / "Code/sbm_map_generation.lua").read_text(encoding="utf-8")
TERRAIN = (ROOT / "Code/sbm_terrain_copy.lua").read_text(encoding="utf-8")
CONFIG = (ROOT / "Code/sbm_config.lua").read_text(encoding="utf-8")

required_map = (
    'local surface_single_flush_transactions = setmetatable({}, { __mode = "k" })',
    "function SuperBigMap.GenerationGrids.RebuildSurfaceSingleFlush(map, phase, transaction)",
    'phase ~= "preplan" and phase ~= "closing"',
    "passage_pad_finalization_dirty_provenance_exact ~= true",
    "dirty_digest ~= terrain_report.passage_pad_finalization_dirty_digest",
    "coverage_permille > 150",
    "surface_single_flush_transactions[transaction] ~= map",
    "report.object_containment_failures ~= 0",
	"report.object_association_failures ~= 0",
	"radius ~= math.ceil(certified_radius)",
    'grid_count(difference, 1, 2147483647)',
    '"surface capsule publication changed certified height"',
    "ReleaseSurfaceSingleFlushTransaction(transaction)",
    'reason .. " before fresh-grid capsule planning")',
    'reason .. " after fresh-grid capsule publication")',
	"report.outer_passage_pad_finalization_dirty_provenance_exact =",
    "report.surface_single_flush_local_passability_calls == 4",
    "report.surface_single_flush_buildable_calls == 1",
    "report.surface_single_flush_height_mismatches == 0",
    "report.surface_single_flush_object_family_count == 6",
	"report.surface_single_flush_object_association_failures == 0",
	"report.surface_single_flush_dirty_digest",
	"report.surface_single_flush_coverage_permille <= 150",
    "report.surface_single_flush_cleanup_complete == true",
    'OptimizationTrace.Before(\n\t\t\t\t"surface single-flush preplan local rebuild"',
    'OptimizationTrace.Before(\n\t\t\t\t"surface single-flush closing local rebuild"',
)
required_terrain = (
    "site.finalization_dirty_radius_world",
    "site.finalization_dirty_provenance_version = 1",
    "passage_plan.finalization_dirty_digest",
    "passage_pad_finalization_dirty_provenance_exact",
)
required_config = (
    "config.OptimizeSurfaceSingleFlushFinalization = true",
    "C.OPTIMIZE_SURFACE_SINGLE_FLUSH_FINALIZATION",
)

errors = []
for token in required_map:
    if token not in MAP:
        errors.append(f"map contract missing: {token!r}")
for token in required_terrain:
    if token not in TERRAIN:
        errors.append(f"terrain contract missing: {token!r}")
for token in required_config:
    if token not in CONFIG:
        errors.append(f"config contract missing: {token!r}")

helper = MAP[MAP.index("function SuperBigMap.GenerationGrids.RebuildSurfaceSingleFlush") :]
helper = helper[: helper.index("-- Stretch-only surface expansion readiness gate.")]
for forbidden in ("AsyncRand", "InteractionRand", "SetHeightGrid", "SetPos", "DoneObject"):
    if forbidden in helper:
        errors.append(f"local finalizer contains forbidden mutation/RNG token: {forbidden}")

if "SuperBigMap.OptimizationTrace.Step = SuperBigMap.OptimizationTrace.Noop" not in MAP:
    errors.append("default-off trace no-op is absent")
if MAP.count("function SuperBigMap.GenerationGrids.RebuildSurfaceSingleFlush") != 1:
    errors.append("single-flush helper definition is not unique")

# Dirty provenance selects the optimization; it must not become a new gameplay/planner
# prerequisite because the former canonical path is the explicit fail-closed fallback.
planner_gate = MAP[MAP.index("function Lazy.BuildCapsulePlanMode") :
                   MAP.index("function Lazy.PrepareImplementationCapsules")]
if "terrain_report.passage_pad_finalization_dirty_provenance_exact ~= true" in planner_gate:
    errors.append("dirty provenance incorrectly blocks the canonical planner fallback")

if errors:
    print("v998 surface single-flush static contract: FAIL", file=sys.stderr)
    for error in errors:
        print(f"- {error}", file=sys.stderr)
    raise SystemExit(1)
print("v998 surface single-flush static contract: ok")
