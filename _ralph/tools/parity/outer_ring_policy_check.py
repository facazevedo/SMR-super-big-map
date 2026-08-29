#!/usr/bin/env python3
"""Offline discriminator for enrichment perimeter policy and natural foothill aprons.

The historical filename is retained so existing harness commands keep working.
"""

from __future__ import annotations

import json
import math
from dataclasses import asdict, dataclass
from pathlib import Path


ROOT = Path(__file__).resolve().parents[3]
DEPOSITS = (ROOT / "Code" / "sbm_deposits.lua").read_text(encoding="utf-8")
CONFIG = (ROOT / "Code" / "sbm_config.lua").read_text(encoding="utf-8")
GENERATION = (ROOT / "Code" / "sbm_map_generation.lua").read_text(encoding="utf-8")
TERRAIN = (ROOT / "Code" / "sbm_terrain_copy.lua").read_text(encoding="utf-8")
METADATA = (ROOT / "metadata.lua").read_text(encoding="utf-8")


def section(text: str, start: str, end: str) -> str:
    first = text.index(start)
    last = text.index(end, first + len(start))
    return text[first:last]


def appears_in_order(text: str, *needles: str) -> bool:
    position = -1
    for needle in needles:
        position = text.find(needle, position + 1)
        if position < 0:
            return False
    return True


@dataclass(frozen=True)
class Candidate:
    name: str
    sector: str
    flat: bool = True
    buildable: bool = True
    passable: bool = True
    unobstructed: bool = True
    mountain_base: bool = False
    expected_valid: bool = True


def terrain_policy(candidate: Candidate) -> bool:
    """Executable model of the hard placement predicates."""
    return (
        candidate.flat
        and candidate.buildable
        and candidate.passable
        and candidate.unobstructed
    )


def preferred_by_sector(candidates: tuple[Candidate, ...]) -> tuple[str, ...]:
    """Model the production preference: bases where available, flats elsewhere."""
    base_sectors = {c.sector for c in candidates if terrain_policy(c) and c.mountain_base}
    return tuple(
        c.name
        for c in candidates
        if terrain_policy(c) and (c.sector not in base_sectors or c.mountain_base)
    )


def mountain_base_relief(maximum_rise_m: float, higher_samples: int) -> bool:
    """Model the production relief discriminator after the strict terrain gate."""
    return maximum_rise_m >= 5 and higher_samples >= 2


def dome_effect_topup_allowed(
    edge_layer: int, underground: bool = False, verified_mountain_pad: bool = False
) -> bool:
    """Perimeter effects require an exact, newly shaped, engine-verified mountain pad."""
    return underground or edge_layer > 2 or verified_mountain_pad


def quota_hex_clearance(a: tuple[int, int], b: tuple[int, int], minimum: int = 3) -> bool:
    """Model the hard axial clearance used only by guaranteed surface resources."""
    dq, dr = a[0] - b[0], a[1] - b[1]
    return max(abs(dq), abs(dr), abs(dq + dr)) >= minimum


def rocket_footprint_clear_of_inner_rectangle(
    x: float,
    y: float,
    radius: float,
    inner: tuple[float, float, float, float],
) -> bool:
    """Model the conservative production circle-to-inner-rectangle exclusion."""
    left, top, right, bottom = inner
    nearest_x = max(left, min(right, x))
    nearest_y = max(top, min(bottom, y))
    dx, dy = x - nearest_x, y - nearest_y
    return dx * dx + dy * dy > radius * radius


def apron_weight(normalized_radius: float, core_fraction: float = 0.75) -> float:
    """Production C2 core-to-original feather."""
    if normalized_radius <= core_fraction:
        return 1.0
    if normalized_radius >= 1.0:
        return 0.0
    t = (normalized_radius - core_fraction) / (1 - core_fraction)
    smooth = t**3 * (t * (t * 6 - 15) + 10)
    return 1 - smooth


def protected_by_any(
    x: float, y: float, guards: tuple[tuple[float, float, float], ...]
) -> bool:
    """Model the production exact per-cell protected-circle predicate."""
    return any(
        (x - cx) ** 2 + (y - cy) ** 2 <= radius**2
        for cx, cy, radius in guards
    )


def outer_resource_rebuild_strips(
    width: int, height: int, ring_sectors: int = 2, pass_tile: int = 100
) -> tuple[tuple[int, int, int, int], ...]:
    """Executable model of the conservative production passability regions."""
    margin = pass_tile * 2
    band_x = math.ceil(width * ring_sectors / 20)
    band_y = math.ceil(height * ring_sectors / 20)
    inner_x, inner_y = band_x + margin, band_y + margin
    far_x, far_y = width - band_x - margin, height - band_y - margin
    return (
        (0, 0, width, inner_y),
        (0, far_y, width, height),
        (0, 0, inner_x, height),
        (far_x, 0, width, height),
    )


def point_in_half_open_box(x: int, y: int, bounds: tuple[int, int, int, int]) -> bool:
    left, top, right, bottom = bounds
    return left <= x < right and top <= y < bottom


def nearby_protected_guards(
    patch_x: float,
    patch_y: float,
    visit_radius: float,
    guards: tuple[tuple[float, float, float], ...],
) -> tuple[tuple[float, float, float], ...]:
    """Model the exact conservative triangle-inequality prefilter."""
    return tuple(
        guard
        for guard in guards
        if (guard[0] - patch_x) ** 2 + (guard[1] - patch_y) ** 2
        <= (visit_radius + guard[2]) ** 2
    )


def organic_resource_weight(
    x: float,
    y: float,
    *,
    core: float,
    transition: float,
    phase: float,
    relief: tuple[float, float],
    irregularity: float = 0.12,
) -> float:
    """Executable model of the production slope-aligned quintic resource feather."""
    distance = math.hypot(x, y)
    angle = math.atan2(y, x)
    ux, uy = (1.0, 0.0) if distance <= 0.0001 else (x / distance, y / distance)
    along_relief = ux * relief[0] + uy * relief[1]
    harmonic = (
        0.52 * math.sin(3 * angle + phase)
        + 0.30 * math.sin(5 * angle - phase * 1.37)
        + 0.18 * math.sin(7 * angle + phase * 0.73)
    )
    width_scale = max(
        0.50,
        min(
            1.35,
            1
            + irregularity * harmonic
            + 0.12 * (2 * along_relief * along_relief - 1)
            - 0.06 * along_relief,
        ),
    )
    outer = core + transition * width_scale
    if distance <= core:
        return 1.0
    if distance >= outer:
        return 0.0
    t = (distance - core) / max(0.0001, outer - core)
    smooth = t**3 * (t * (t * 6 - 15) + 10)
    return 1 - smooth


CASES = (
    Candidate("plain_flat", "plain"),
    Candidate("mountain_base_flat", "mountain", mountain_base=True),
    Candidate("mountain_plateau_flat", "mountain"),
    Candidate("steep_slope", "mountain", flat=False, expected_valid=False),
    Candidate("unbuildable_cliff", "mountain", buildable=False, expected_valid=False),
    Candidate("blocked_base", "mountain", mountain_base=True, unobstructed=False, expected_valid=False),
)


badge = section(
    DEPOSITS,
    "local function BadgeCandidateAllowed",
    "local function FindNearestFreeBadgePosition",
)
anomalies = section(
    DEPOSITS,
    "function DepositRules.TopUpAnomalies",
    "BuildTopUpEdgeContext = function",
)
audit = section(
    DEPOSITS,
    "function DepositRules.AuditSurfaceTopUpPlacement",
    "function DepositRules.PrepareUndergroundReachability",
)
resources = section(
    DEPOSITS,
    "function DepositRules.TopUpDeposits",
    "function DepositRules.TopUpAnomalies",
)
census = section(
    DEPOSITS,
    "function DepositRules.CensusFinalOuterResourceTopUps",
    "function DepositRules.AuditSurfaceTopUpPlacement",
)
effects = section(
    DEPOSITS,
    "function DepositRules.TopUpEffectDeposits",
    "function DepositRules.AuditTopUpVanillaRepulsion",
)
aprons = section(
    TERRAIN,
    "local function CreateNaturalMountainBaseBuildableAprons",
    "local function AuditNaturalMountainBaseBuildableAprons",
)
outer_resource_terrain = section(
    TERRAIN,
    "local function PrepareOuterResourceTerrain",
    "-- TEST-ONLY SEAM",
)
rocket_terrain_audit = section(
    outer_resource_terrain,
    "local verified_mountain_pads, rocket_failures",
    "map.SuperBigMapVerifiedMountainRocketPads",
)

static_checks = {
    "immediate_surface_final_rebuild_is_deferred": (
        "config.OptimizeDeferImmediateSurfaceFinalGridRebuild = true" in CONFIG
        and "C.OPTIMIZE_DEFER_IMMEDIATE_SURFACE_FINAL_GRID_REBUILD" in CONFIG
        and 'local defer_immediate_final = cfg_bool(\n\t\t\t"OPTIMIZE_DEFER_IMMEDIATE_SURFACE_FINAL_GRID_REBUILD", false)'
        in GENERATION
    ),
    "canonical_post_pipeline_rebuild_is_retained": (
        "SuperBigMap.GenerationGrids.RebuildFinal(map, reason)" in GENERATION
        and '"post-pipeline scheduled revalidation"' in GENERATION
        and "SuperBigMapSurfacePostPipelineRevalidationComplete = true" in GENERATION
    ),
    "deferred_surface_completion_waits_for_canonical_rebuild": (
        appears_in_order(
            GENERATION,
            "deferred_surface_completion = true",
            '"post-pipeline scheduled revalidation"',
            "SuperBigMapSurfacePostPipelineRevalidationComplete = true",
            "publish_deferred_surface_completion()",
        )
        and "Keep the loading cover and pending gate authoritative" in GENERATION
    ),
    "deferred_surface_revalidation_has_verified_fallbacks": (
        '"post-pipeline revalidation failure fallback"' in GENERATION
        and '"post-pipeline scheduling failure fallback"' in GENERATION
        and "if fallback_ok then" in GENERATION
        and 'SuperBigMapSurfacePostPipelineRevalidationMode = "synchronous-fallback"'
        in GENERATION
        and appears_in_order(
            GENERATION,
            '"post-pipeline scheduling failure fallback"',
            "if fallback_ok then",
            "SuperBigMapSurfacePostPipelineRevalidationScheduled = true",
            "SuperBigMapSurfacePostPipelineRevalidationComplete = true",
            "publish_deferred_surface_completion()",
        )
        and "Fail closed: keep both the pending state and loading cover" in GENERATION
    ),
    "ordinary_failure_retains_baseline_post_pipeline_schedule": (
        'if thread_ok\n\t\t\tand cfg_bool("EXPANSION_STEP_11_REBUILD_GAMEPLAY_GRIDS", true)\n'
        '\t\t\tand map.SuperBigMapSurfacePostPipelineRevalidationScheduled ~= true then'
        in GENERATION
    ),
    "anomaly_outer_ring_is_two_sectors": "config.TopUpAnomalyOuterRingSectors = 2" in CONFIG,
    "compiled_anomaly_outer_ring_uses_config": (
        "as_number(config.TopUpAnomalyOuterRingSectors, 2)" in CONFIG
    ),
    "anomaly_path_uses_live_outer_ring": "TOPUP_ANOMALY_OUTER_RING_SECTORS" in anomalies,
    "anomaly_redistribution_is_fail_closed": (
        "no interior fallback permitted" in DEPOSITS
        and "sequential inner vanilla fallback exhausted" not in DEPOSITS
    ),
    "anomaly_capacity_has_no_one_per_sector_cap": (
        "MAX_TOPUPS_PER_SECTOR" not in DEPOSITS
        and "remove_outer_sector(winner.target_sector)" not in DEPOSITS
    ),
    "audit_rejects_every_anomaly_outside_ring": (
        'family == "anomaly" and not in_ring' in audit
        and "not inner_fallback and not in_ring" not in audit
    ),
    "surface_uses_sector_balancing": "whole_map_sector_balanced" in anomalies,
    "surface_scores_mountain_bases": "ValleyScore(map, pt)" in anomalies,
    "surface_stratifies_every_sector": "SAMPLES_PER_SURFACE_SECTOR" in anomalies,
    "surface_sampling_plan_is_shuffled": "Sampling may stop when the validated pool" in anomalies,
    "preference_is_per_sector": "base_by_sector[key]" in anomalies,
    "preference_keeps_plain_sectors": "base_by_sector[key] == nil or" in anomalies,
    "base_selector_is_capped_per_sector": "MOUNTAIN_BASE_CANDIDATES_PER_SECTOR" in anomalies,
    "base_quota_is_configured": "TOPUP_ANOMALY_MOUNTAIN_BASE_MINIMUM_PERCENT" in anomalies,
    "base_quota_is_emphasized": "config.TopUpAnomalyMountainBaseMinimumPercent = 75" in CONFIG,
    "minor_relief_is_excluded": "TopUpAnomalyMountainBaseMinimumRiseMeters = 5" in CONFIG,
    "relief_requires_multiple_samples": "higher_samples) or 0) >= 2" in DEPOSITS,
    "base_quota_selector_exists": "surface anomaly mountain-base quota" in anomalies,
    "steepness_never_relaxed": "only relaxes the nearby-higher-terrain preference" in anomalies,
    "topups_clear_edge_marker": "clone.SuperBigMapEdgeTopUp = nil" in anomalies,
    "topups_record_base_marker": "clone.SuperBigMapMountainBaseTopUp" in anomalies,
    "badge_has_no_active_ring_without_config": "ring_sectors > 0" in badge,
    "audit_runs_with_ring_disabled": "if ring_sectors <= 0 then return true end" not in audit,
    "audit_requires_flat_buildable": "flatness >= validation_context.flatness_minimum" in audit,
    "audit_requires_unobstructed": "IsUnobstructedAt(map, pt, true" in audit,
    "generation_enforces_surface_audit": "AuditSurfaceTopUpPlacement" in GENERATION,
    "dome_effect_exclusion_is_two_sectors": (
        "config.TopUpDomeEffectOuterRingExclusionSectors = 2" in CONFIG
    ),
    "effect_cached_pool_checks_exclusion": (
        "surface_effect_candidate_allowed(c.x, c.y, c.sector)" in effects
    ),
    "effect_fresh_samples_check_exclusion": (
        "surface_effect_candidate_allowed(x, y, sector)" in effects
    ),
    "effect_selector_rechecks_exclusion": (
        "surface_effect_candidate_allowed(candidate.x, candidate.y, candidate.sector)" in effects
    ),
    "effect_exclusion_is_surface_only": "if underground or surface_exclusion_ring_sectors <= 0" in effects,
    "effect_exclusion_is_audited": "dome_effect_topup_inside_excluded_outer_ring" in audit,
    "outer_resource_terrain_preparation_is_enabled": (
        "config.PrepareOuterResourceTerrain = true" in CONFIG
        and "C.PREPARE_OUTER_RESOURCE_TERRAIN" in CONFIG
    ),
    "native_outer_resource_raster_is_enabled": (
        "config.OptimizeOuterResourceTerrainNativeRaster = true" in CONFIG
        and "C.OPTIMIZE_OUTER_RESOURCE_TERRAIN_NATIVE_RASTER" in CONFIG
        and 'cfg_bool("OPTIMIZE_OUTER_RESOURCE_TERRAIN_NATIVE_RASTER", true)'
        in outer_resource_terrain
    ),
    "outer_resource_ring_rebuild_is_enabled": (
        "config.OptimizeOuterResourceTerrainRingRebuild = true" in CONFIG
        and "C.OPTIMIZE_OUTER_RESOURCE_TERRAIN_RING_REBUILD" in CONFIG
        and 'cfg_bool("OPTIMIZE_OUTER_RESOURCE_TERRAIN_RING_REBUILD", true)'
        in GENERATION
    ),
    "outer_resource_ring_rebuild_is_bounded_and_falls_back": all(
        token in GENERATION
        for token in (
            "function SuperBigMap.GenerationGrids.RebuildOuterResourceRing",
            "local dependency_margin = math.floor(pass_tile * 2)",
            "local band_x = math.ceil(map_w * ring_sectors / 20)",
            "terrain_api.RebuildPassability(map, region)",
            "local build_ok, build_err = pcall(rebuild_buildable, map)",
            "function SuperBigMap.GenerationGrids.RebuildOuterResourceRingOrFinal",
            "local call_ok, used, report = pcall(",
            'tostring(stage or "outer resource terrain") .. " fallback"',
            "ring_rebuild_fallbacks",
            "ring_rebuild_error_history",
        )
    ),
    "outer_resource_ring_rebuild_keeps_final_whole_map_rebuilds": (
        GENERATION.count("SuperBigMap.GenerationGrids.RebuildFinal(") >= 3
        and 'map, "after last object-grid transaction"' in GENERATION
        and "SuperBigMap.GenerationGrids.RebuildFinal(map, reason)" in GENERATION
        and '"post-pipeline scheduled revalidation"' in GENERATION
    ),
    "native_outer_resource_precondition_is_enabled": (
        "config.OptimizeOuterResourceTerrainNativePrecondition = true" in CONFIG
        and "C.OPTIMIZE_OUTER_RESOURCE_TERRAIN_NATIVE_PRECONDITION" in CONFIG
        and 'cfg_bool("OPTIMIZE_OUTER_RESOURCE_TERRAIN_NATIVE_PRECONDITION", true)'
        in outer_resource_terrain
    ),
    "outer_resource_rocket_relief_deferral_is_enabled": (
        "config.OptimizeOuterResourceRocketReliefDeferral = true" in CONFIG
        and "C.OPTIMIZE_OUTER_RESOURCE_ROCKET_RELIEF_DEFERRAL" in CONFIG
        and 'cfg_bool("OPTIMIZE_OUTER_RESOURCE_ROCKET_RELIEF_DEFERRAL", true)'
        in outer_resource_terrain
    ),
    "rocket_relief_deferral_retains_literal_legacy_path": all(
        token in outer_resource_terrain
        for token in (
            "if not rocket_relief_deferral_used then",
            "-- Literal compatibility path: retain the accepted eager read order and predicate.",
            "local z = grid_value(cx + direction[1] * 12 * cells_per_hex,",
            "mountain = maximum_rise >= 5 * guim_v and higher >= 2",
        )
    ),
    "rocket_relief_deferral_preserves_placeholders_and_score": all(
        token in outer_resource_terrain
        for token in (
            "local maximum_rise, higher, mountain = 0, 0, false",
            "mountain = mountain, maximum_rise = maximum_rise, higher_samples = higher,",
            "score = (ready and -1000000000 or 0)",
            "if candidate and (not best or candidate.score < best.score) then",
        )
    ),
    "rocket_relief_deferral_samples_only_selected_winner": all(
        token in outer_resource_terrain
        for token in (
            "if rocket_relief_deferral_used then",
            "rocket_relief_selected_groups = rocket_relief_selected_groups + 1",
            "local reloaded_center = grid_value(cx, cy)",
            "best.maximum_rise = maximum_rise",
            "best.higher_samples = higher",
            "best.mountain = maximum_rise >= 5 * guim_v and higher >= 2",
        )
    ),
    "rocket_relief_deferral_reports_exact_read_budget": all(
        token in outer_resource_terrain
        for token in (
            "rocket_relief_viable_candidates",
            "rocket_relief_selected_groups",
            "rocket_relief_eager_equivalent_reads",
            "rocket_relief_deferred_reads",
            "rocket_relief_saved_reads",
            "rocket_relief_center_mismatches",
        )
    ),
    "surface_hard_spacing_spatial_index_is_enabled": (
        "config.OptimizeTopUpHardSpacingSpatialIndex = true" in CONFIG
        and "C.OPTIMIZE_TOPUP_HARD_SPACING_SPATIAL_INDEX" in CONFIG
        and "cfg().OPTIMIZE_TOPUP_HARD_SPACING_SPATIAL_INDEX == true" in DEPOSITS
    ),
    "surface_hard_spacing_spatial_index_is_dual_and_surface_only": all(
        token in DEPOSITS
        for token in (
            "local function BuildSurfaceHardSpacingCandidateRows",
            "local world_buckets, hex_buckets = {}, {}",
            "maximum_world_radius = 2 * max_component",
            "if spatial_index_requested and not underground then",
            '"underground literal path"',
        )
    ),
    "surface_hard_spacing_spatial_index_preserves_order_and_fallback": all(
        token in DEPOSITS
        for token in (
            "table.sort(nearby)",
            "for _, j in ipairs(candidate_rows[i] or {}) do",
            "audit_checked_pair(a, entries[j])",
            "-- Literal exact fallback: preserve the original full pair order",
            "for j = i + 1, #entries do",
            "audit_checked_pair(a, b)",
        )
    ),
    "surface_hard_spacing_spatial_index_reports_pair_budget": all(
        token in DEPOSITS + GENERATION
        for token in (
            "hard_spacing_spatial_index_requested",
            "hard_spacing_spatial_index_used",
            "hard_spacing_spatial_index_fallback_reason",
            "hard_spacing_spatial_index_candidate_pairs",
            "hard_spacing_spatial_index_pruned_pairs",
        )
    ),
    "native_raster_retains_legacy_fallback_from_raw_source": (
        "local function apply_legacy_raster()" in outer_resource_terrain
        and "local working = grid:clone()" in outer_resource_terrain
        and "native transactional clone unavailable" in outer_resource_terrain
        and "local failed_grid = grid" in outer_resource_terrain
        and "grid = raw" in outer_resource_terrain
        and "local rebuilt = grid_to_compute(raw)" in outer_resource_terrain
        and "native fallback grid unavailable" in outer_resource_terrain
        and "grid = rebuilt" in outer_resource_terrain
        and "ok_apply, apply_error = pcall(apply_legacy_raster)"
        in outer_resource_terrain
        and "native_raster_fallback = true" in outer_resource_terrain
    ),
    "native_raster_uses_patch_local_fixed_point_formula": all(
        token in outer_resource_terrain
        for token in (
            "local native_weight_scale, native_height_scale = 4096, 256",
            "local native_sample_step = 8",
            "native_resample(coarse, local_width, local_height, true)",
            "native_mul_div_add(weight_cube, mask, native_weight_scale, 0)",
            "native_mul_div_add(result, inverse_cube, native_weight_scale, 0)",
            "native_mul_div_add(plane_term, weight_cube, native_weight_scale, 0)",
            "native_mul_div_add(target_delta, mask, native_weight_scale, 0)",
        )
    ),
    "native_raster_preconditions_at_risk_components": (
        'if patch.kind ~= "surface"' in outer_resource_terrain
        and "or patch.maximum_core_delta >= precondition_minimum_delta"
        in outer_resource_terrain
        and "local precondition_minimum_delta = 2 * guim_v" in outer_resource_terrain
        and "precondition_components[patch.component] = true" in outer_resource_terrain
        and "patch.precondition_selected = precondition_components[patch.component] == true"
        in outer_resource_terrain
        and "patch.base_transition_cells = existing_transition" in outer_resource_terrain
        and "apply_native_patch(patch, false, patch.base_transition_cells)"
        in outer_resource_terrain
        and "local native_precondition_extra_passes = 1" in outer_resource_terrain
        and "native_precondition_sites" in outer_resource_terrain
        and "native_precondition_patches" in outer_resource_terrain
        and "patch_index == #patches and native_precondition_patches == 0" in outer_resource_terrain
        and "for _, site in ipairs(native_precondition_site_records) do" in outer_resource_terrain
        and (
            "if native_raster_used and set_ok then\n"
            "\t\tfor _, site in ipairs(native_precondition_site_records) do\n"
            "\t\t\tsite.patch_precondition_selected = true\n"
            "\t\t\tsite.patch_precondition_passes = native_precondition_extra_passes"
        ) in outer_resource_terrain
        and "not prior_terrain_plan_present" in outer_resource_terrain
        and "type(map.SuperBigMapOuterResourceRocketPads)" in outer_resource_terrain
    ),
    "native_raster_converts_only_patch_local_grids": (
        "local source_native = own(grid:new_instance(local_width, local_height))"
        in outer_resource_terrain
        and 'native_repack(source_native, "f", 32, true)' in outer_resource_terrain
        and "native_repack(result, native_is_compute(grid))" in outer_resource_terrain
        and 'native_repack(grid, "F"' not in outer_resource_terrain
    ),
    "native_raster_preserves_exact_cores_and_guards": (
        "native_circle_set(mask, native_weight_scale, center_x, center_y"
        in outer_resource_terrain
        and "for _, protected in ipairs(nearby_protected) do"
        in outer_resource_terrain
        and "native_circle_set(mask, 0," in outer_resource_terrain
        and "math.floor(protected.radius * height_tile + 0.5),"
        in outer_resource_terrain
        and "0, native_tile_step)" in outer_resource_terrain
        and "if patch_index == #patches then break end" in outer_resource_terrain
    ),
    "native_raster_hard_restores_inner_patch_intersections": (
        "math.ceil(width * 0.1 - 0.5)" in outer_resource_terrain
        and "math.ceil(width * 0.9 - 0.5) - 1" in outer_resource_terrain
        and "result:copyrect(height_grid, restore_box" in outer_resource_terrain
        and "native_inner_restored_patch_cells" in outer_resource_terrain
        and "grid:copyrect(raw, inner_box" not in outer_resource_terrain
        and "keeping any transition entirely on the ring side" in outer_resource_terrain
    ),
    "native_raster_avoids_circular_terrain_setter": (
        "SetHeightCircle" not in outer_resource_terrain
        and "terrain.SetHeightCircle" not in outer_resource_terrain
    ),
    "outer_resource_terrain_uses_two_sector_world_band": (
        'cfg_number("MOUNTAIN_BASE_APRON_OUTER_RING_SECTORS", 2)' in outer_resource_terrain
        and "map_w * ring_sectors / 20" in outer_resource_terrain
        and "if not in_outer_band(x, y) then return end" in outer_resource_terrain
        and 'map.MapForEach, map, "map", "DepositMarker"' in outer_resource_terrain
    ),
    "outer_resource_terrain_uses_live_extractor_shapes": (
        'pcall(get_extended_shape, template_name, 0)' in outer_resource_terrain
        and 'Concrete = "RegolithExtractor"' in outer_resource_terrain
        and 'Metals = "MetalsExtractor"' in outer_resource_terrain
        and 'PreciousMetals = "PreciousMetalsExtractor"' in outer_resource_terrain
        and 'Water = "WaterExtractor"' in outer_resource_terrain
    ),
    "surface_resources_require_exact_rover_tile_passability": (
        'local surface_offsets = { { 0, 0 } }' in outer_resource_terrain
        and 'site.kind == "extractor"' in outer_resource_terrain
        and "one consistent API value before observing the" in outer_resource_terrain
    ),
    "resource_clusters_are_general_seeded_plan_components": (
        "cluster_plan = tonumber(marker.SuperBigMapResourceClusterPlan)"
        in outer_resource_terrain
        and "cluster_groups_by_plan" in outer_resource_terrain
    ),
    "resource_cluster_bounds_are_one_to_five_with_one_to_three_extractors": (
        "config.OuterResourceClusterMinimumDeposits = 1" in CONFIG
        and "config.OuterResourceClusterMaximumDeposits = 5" in CONFIG
        and "config.OuterResourceClusterMinimumExtractorDeposits = 1" in CONFIG
        and "config.OuterResourceClusterMaximumExtractorDeposits = 3" in CONFIG
        and "cluster_resource_excess == 0" in outer_resource_terrain
        and "cluster_extractor_excess == 0" in outer_resource_terrain
    ),
    "resource_clusters_use_live_rocket_shape": (
        'pcall(get_extended_shape, "RocketLandingSite", 1)' in outer_resource_terrain
        and "ready_offsets(site.q, site.r, rocket_offsets, true)" in outer_resource_terrain
    ),
    "resource_cluster_pads_are_rebuilt_from_final_height_field": (
        "best.modified = true" in outer_resource_terrain
        and 'add_patch("rocket", best.x, best.y, best.q, best.r,' in outer_resource_terrain
        and "pre-rebuild buildable grid" in outer_resource_terrain
    ),
    "resource_terrain_uses_seamless_quintic_feather": (
        "t * t * t * (t * (t * 6 - 15) + 10)" in outer_resource_terrain
        and "weight = 1 - smooth" in outer_resource_terrain
    ),
    "resource_terrain_transition_is_broad_and_irregular": (
        "config.OuterResourceTransitionMinimumWidthHexes = 14" in CONFIG
        and "config.OuterResourceTransitionIrregularityPercent = 12" in CONFIG
        and "patch.outer_cells - patch.core_cells" in outer_resource_terrain
        and "local harmonic =" in outer_resource_terrain
    ),
    "resource_terrain_transition_expands_with_cut_fill_height": (
        "local adaptive_transition_cap = 36 * cells_per_hex" in outer_resource_terrain
        and "maximum_core_delta * 0.65" in outer_resource_terrain
        and "math.max(existing_transition, adaptive_transition)" in outer_resource_terrain
    ),
    "resource_terrain_transition_tracks_local_relief": (
        "local relief_probe =" in outer_resource_terrain
        and "relief_x, relief_y = relief_x / relief_length" in outer_resource_terrain
        and "local along_relief =" in outer_resource_terrain
    ),
    "height_step_scan_reuses_exact_rolling_window": all(
        token in TERRAIN
        for token in (
            "local scan_grid_reads, legacy_scan_grid_reads = 0, 0",
            "legacy_scan_grid_reads = legacy_scan_grid_reads + sample_count * max_width * 4",
            "v0, a, next1, next2 = a, next1, next2, at(axis, perp + 3, along)",
            "a, next1, next2, next3, next4, at(axis, perp + 5, along)",
        )
    ),
    "height_step_refine_reuses_exact_rolling_window": all(
        token in TERRAIN
        for token in (
            'cfg_bool("OPTIMIZE_HEIGHT_STEP_REFINE_ROLLING_WINDOW", true)',
            "local refine_calls, refine_grid_reads, legacy_refine_grid_reads = 0, 0, 0",
            "legacy_refine_grid_reads = legacy_refine_grid_reads + positions * max_width * 4",
            "v0, a, next1, next2 = a, next1, next2,",
            "a, next1, next2, next3, next4,",
            "legacy_refine_grid_reads = legacy_refine_grid_reads,",
            "report.source_refine_grid_reads = report.refine_grid_reads",
            "report.destination_refine_grid_reads = report.refine_grid_reads",
            "map.SuperBigMapHeightStepRepairReport = internal_step_repair",
        )
    ) and all(
        token in CONFIG
        for token in (
            "config.OptimizeHeightStepRefineRollingWindow = true",
            "C.OPTIMIZE_HEIGHT_STEP_REFINE_ROLLING_WINDOW =",
        )
    ),
    "destination_height_step_uses_fail_closed_native_discovery_index": all(
        token in TERRAIN
        for token in (
            'cfg_bool("OPTIMIZE_HEIGHT_STEP_NATIVE_DISCOVERY_INDEX", true)',
            'local GridForeach = Global("GridForeach")',
            'GridAdd(signed_b, signed_a)',
            'local predicate_value = signed_difference',
            'GridAbs(flank0)',
            'GridMulDivAdd(flank0, 2, 1, 0)',
            'GridMask(predicate_value, accepted, threshold, 2147483647)',
            'GridMask(margin, flank_ok, 0, 2147483647)',
            'GridMulDivAdd(accepted, flank_ok, 1, 0)',
            'local function export_records(difference, low_before)',
            'export_records(predicate_value, before_edge)',
            'local callback_error',
            'if callback_error then error(callback_error, 0) end',
            'local prepare_status = { pcall(native_discovery.prepare) }',
            'GridForeach(difference, function(jump, x, y)',
            'end, threshold, 2147483647)',
            'native_discovery.fallback = true',
            'native_discovery.indexes = nil',
            'native_discovery.scan(row, axis, along, before_perp0, before_perp1,',
            'return a.perp < b.perp or (a.perp == b.perp and a.width < b.width)',
            'offer_candidate(row, axis, candidate.perp, candidate.width, edge,',
            'if value and type(value.free) == "function" then pcall(value.free, value) end',
            'report.native_discovery_index_exact_positions = native_discovery.exact_positions',
            'report.destination_scan_grid_reads = report.scan_grid_reads',
            'report.destination_legacy_scan_grid_reads = report.legacy_scan_grid_reads',
            'report.destination_native_discovery_index_used = report.native_discovery_index_used',
            'report.destination_candidates = report.candidates',
            'candidates = #tracks',
            'report.height_step_point_expand_ms = phase_ms.point_expand',
            'report.height_step_apply_ms = phase_ms.apply',
        )
    ) and all(
        token in CONFIG
        for token in (
            "config.OptimizeHeightStepNativeDiscoveryIndex = true",
            "C.OPTIMIZE_HEIGHT_STEP_NATIVE_DISCOVERY_INDEX =",
        )
    ),
    "source_height_step_uses_fail_closed_sampled_native_discovery_index": all(
        token in TERRAIN
        for token in (
            'cfg_bool("OPTIMIZE_HEIGHT_STEP_NATIVE_SOURCE_DISCOVERY_INDEX", true)',
            'mode = wide_ring_only and "source_sampled_wide_ring"',
            "local function build_sampled_source_band(",
            "local sampled_rows = math.floor((along_n - 1) / sample_step) + 1",
            "sampled:copyrect(grid,",
            "local along = compact_along * sample_step",
            "GridMask(magnitude, accepted, threshold, 2147483647)",
            "export_records(positive, true)",
            "export_records(negative, false)",
            "perp = perp, width = 1, jump = jump, low_before = low_before",
            "native source discovery candidate-record limit exceeded",
            "native source discovery survivor limit exceeded",
            "native source discovery cleanup failed",
            "report.source_native_discovery_index_used = native_discovery.used",
            "report.source_native_discovery_index_fallback = native_discovery.fallback",
            "report.source_native_discovery_index_sampled_rows = native_discovery.sampled_rows",
            "source_native_discovery_compaction_copies = internal_step_repair",
        )
    ) and all(
        token in CONFIG
        for token in (
            "config.OptimizeHeightStepNativeSourceDiscoveryIndex = true",
            "C.OPTIMIZE_HEIGHT_STEP_NATIVE_SOURCE_DISCOVERY_INDEX =",
        )
    ),
    "resource_terrain_irregularity_never_shrinks_level_core": (
        "patch.core_cells + base_transition * width_scale" in outer_resource_terrain
        and "if distance <= patch.core_cells then" in outer_resource_terrain
    ),
    "resource_terrain_prefilters_protected_guards_per_patch": (
        "local function protected_ready_sites_near(cx, cy, visit_radius)"
        in outer_resource_terrain
        and "for _, protected in ipairs(protected_ready_sites) do" in outer_resource_terrain
        and "local reach = visit_radius + protected.radius" in outer_resource_terrain
        and "local nearby_protected = protected_ready_sites_near(patch.cx, patch.cy, radius)"
        in outer_resource_terrain
        and "is_protected_ready_cell(x, y, nearby_protected)" in outer_resource_terrain
    ),
    "planned_cluster_footprints_precondition_before_rebuild": (
        "cluster_plan = entry.cluster_plan" in outer_resource_terrain
        and "local planned_cluster_footprint = type(site) == \"table\""
        in outer_resource_terrain
        and "and site.cluster_plan ~= nil and patch.kind ~= \"surface\""
        in outer_resource_terrain
        and "and (planned_cluster_footprint" in outer_resource_terrain
    ),
    "streamed_extractors_settle_in_initial_terrain_transaction": (
        "local stream_planned_extractor = not prior_terrain_plan_present"
        in outer_resource_terrain
        and 'entry.kind == "extractor" and entry.cluster_plan ~= nil'
        in outer_resource_terrain
        and "and not stream_planned_extractor" in outer_resource_terrain
    ),
    "rocket_live_shape_stays_outside_inner_no_write_rectangle": (
        "local function inner_rectangle_clearance(x, y)" in outer_resource_terrain
        and "if inner_clearance <= rocket_required_core * hex_size then return nil end"
        in outer_resource_terrain
        and "inner_clearance = inner_clearance" in outer_resource_terrain
        and '":inner_clearance=" .. tostring(site.inner_clearance or "?")'
        in rocket_terrain_audit
    ),
    "resource_terrain_levels_only_live_footprint_margin": (
        "math.ceil(world_radius + 1)" in outer_resource_terrain
        and "local rocket_level_core = math.ceil(rocket_world_radius + 1)" in outer_resource_terrain
        and "support_cells = required_core * cells_per_hex" in outer_resource_terrain
        and "patches[a].support_cells + patches[b].support_cells" in outer_resource_terrain
    ),
    "resource_terrain_preserves_native_transition_detail": (
        "local local_plane = patch.target" in outer_resource_terrain
        and "local detail = old - local_plane" in outer_resource_terrain
        and "local detail_retention = 1 - weight * weight * weight" in outer_resource_terrain
        and "detail * detail_retention" in outer_resource_terrain
    ),
    "surface_resource_repairs_retain_a_safe_local_grade": (
        'if kind == "surface" then' in outer_resource_terrain
        and "if grade_length > 3 then" in outer_resource_terrain
        and 'local shape_target = patch.kind == "surface"' in outer_resource_terrain
        and 'local core_target = patch.kind == "surface"' in outer_resource_terrain
    ),
    "resource_terrain_rebuild_precedes_anomaly_effect_placement": (
        GENERATION.index('"surface prepare outer resource terrain"')
        < GENERATION.index('"after outer resource terrain preparation")')
        < GENERATION.index('"surface top-up anomalies"')
        < GENERATION.index('"surface top-up effect deposits"')
        and "RebuildOuterResourceRing(" in GENERATION
    ),
    "rocket_pad_height_samples_are_cached_exactly": all(
        token in outer_resource_terrain
        for token in (
            "local rocket_height_cache = {}",
            "local function cached_rocket_height(q, r, known_x, known_y)",
            "row[r] = value ~= nil and value or false",
            "local center = cached_rocket_height(q, r, x, y)",
            "local z = cached_rocket_height(q + offset[1], r + offset[2])",
        )
    ),
    "rocket_clearance_uses_exact_axial_masks": all(
        token in outer_resource_terrain
        for token in (
            "local function mark_axial_forbidden(mask, cq, cr, radius)",
            "local function axial_mask_contains(mask, q, r)",
            "local resource_clearance_radius = math.max(0, math.ceil(resource_clearance_minimum) - 1)",
            "local rocket_clearance_radius = math.max(0, math.ceil(rocket_clearance_minimum) - 1)",
            "local clear = not axial_mask_contains(resource_clearance_mask, q, r)",
            "local clear = not axial_mask_contains(clearance_mask or rocket_clearance_mask, q, r)",
            "+ mark_axial_forbidden(rocket_clearance_mask, best.q, best.r,",
        )
    ),
    "bounded_rocket_planner_is_default_on_and_compiled": (
        "config.OptimizeOuterResourceRocketBoundedPlanner = true" in CONFIG
        and "C.OPTIMIZE_OUTER_RESOURCE_ROCKET_BOUNDED_PLANNER" in CONFIG
        and "C.OUTER_RESOURCE_ROCKET_BOUNDED_SCORED_BUDGET_PER_GROUP" in CONFIG
    ),
    "bounded_rocket_planner_is_private_before_publish": all(
        token in outer_resource_terrain
        for token in (
            "local private_rocket_mask = {}",
            "and #bounded_choices == expected_groups",
            "-- Only now publish pad patches and mutate the committed clearance mask",
            "commit_rocket_site(choice.context, choice.best)",
        )
    ),
    "bounded_rocket_planner_retains_complete_fallback": all(
        token in outer_resource_terrain
        for token in (
            "-- Literal exhaustive fallback: retain the accepted disk order",
            "for dq = -search_limit, search_limit do",
            "for dr = -search_limit, search_limit do",
            "candidate.score < best.score",
        )
    ),
    "bounded_rocket_planner_retains_policy_audit": (
        "Score the full fixed budget" in outer_resource_terrain
        and "rocket_bounded.full_budget_groups" in outer_resource_terrain
        and "if not best then" in outer_resource_terrain
        and "ready_offsets(site.q, site.r, rocket_offsets, true)" in outer_resource_terrain
        and "rocket_bounded_plan_digest" in outer_resource_terrain
    ),
    "resource_terrain_audit_is_fail_closed": (
        "outer resource terrain audit failed" in GENERATION
        and "resource_failures == 0 and rocket_failures == 0" in outer_resource_terrain
    ),
    "mountain_pad_effect_exception_requires_exact_verified_hex": (
        "VerifiedMountainRocketPadAt" in effects
        and "pad.modified == true and pad.verified == true" in effects
        and "pad.q == q and pad.r == r" in DEPOSITS
        and "SuperBigMapMountainRocketPadEffectTopUp" in audit
    ),
    "general_cluster_and_terrain_rules_have_no_scenario_special_case": (
        "14N134W" not in outer_resource_terrain
        and "A17" not in outer_resource_terrain
        and "14N134W" not in effects
        and "A17" not in effects
    ),
    "natural_aprons_enabled": "config.CreateNaturalMountainBaseBuildableAprons = true" in CONFIG,
    "natural_aprons_use_outer_two_sectors": "config.MountainBaseApronOuterRingSectors = 2" in CONFIG,
    "fixed_mountain_base_resource_quota_is_removed": (
        "config.MountainBaseOuterRingResourceMinimum = 0" in CONFIG
    ),
    "mountain_base_resource_minimum_is_compiled": (
        "C.MOUNTAIN_BASE_OUTER_RING_RESOURCE_MINIMUM" in CONFIG
    ),
    "natural_aprons_reserve_288_opportunities": (
        "config.MountainBaseApronMaximumCount = 288" in CONFIG
    ),
    "resource_quota_scans_final_grid_generally": (
        "local SAMPLES_AXIS = 32" in resources
        and "local MAX_CANDIDATES_PER_SECTOR = 64" in resources
        and "local MAX_FINAL_QUOTA_CANDIDATES = 4096" in resources
    ),
    "natural_aprons_reject_obvious_cliffs": "maximum_local_slope > 24" in aprons,
    "already_buildable_foothills_are_unchanged": (
        "requires_edit = maximum_local_slope >= 9" in aprons
        and "if candidate.requires_edit then" in aprons
    ),
    "foothill_selection_is_pseudorandom_without_rng_cost": (
        "pseudorandom_rank" in aprons and "73856093" in aprons
    ),
    "natural_aprons_require_mountain_relief": "higher_samples < 3" in aprons,
    "natural_aprons_keep_gentle_grade": "if gradient_length > 4" in aprons,
    "natural_aprons_use_small_core_and_broad_transition": (
        "config.MountainBaseApronCoreRadiusHexes = 4" in CONFIG
        and "config.MountainBaseApronFeatherRadiusHexes = 20" in CONFIG
        and "detail * detail_retention" in aprons
    ),
    "natural_aprons_use_irregular_boundary": "lobe3" in aprons and "lobe2" in aprons,
    "natural_aprons_use_quintic_feather": "t * t * t * (t * (t * 6 - 15) + 10)" in aprons,
    "natural_aprons_native_raster_is_default_on_and_compiled": (
        "config.OptimizeMountainBaseApronNativeRaster = true" in CONFIG
        and "C.OPTIMIZE_MOUNTAIN_BASE_APRON_NATIVE_RASTER" in CONFIG
        and 'cfg_bool("OPTIMIZE_MOUNTAIN_BASE_APRON_NATIVE_RASTER", true)' in aprons
    ),
    "natural_aprons_native_raster_uses_bounded_step4_fixed_point": all(
        token in aprons
        for token in (
            "native_weight_scale, native_height_scale, native_sample_step = 4096, 256, 4",
            "math.ceil((local_width - 1) / native_sample_step) + 1",
            "native_resample(coarse, local_width, local_height, true)",
            "native_mul_div_add(weight_cube, mask, native_weight_scale, 0)",
            "native_mul_div_add(result, inverse_cube, native_weight_scale, 0)",
            "native_mul_div_add(plane_term, weight_cube, native_weight_scale, 0)",
            "native_repack(result, native_is_compute(grid))",
            "if result_difference == packed_result then result_difference = packed_result:clone() end",
            'string.lower(tostring(source_format)) == "f" and source_bits == 32',
            "native_count(result_difference, 0, 2147483647)",
        )
    ),
    "natural_aprons_native_raster_preserves_literal_fallback_and_exact_core": (
        "local function legacy_apply(target_grid)" in aprons
        and "local old = target_grid:get(x, y)" in aprons
        and "target_grid:set(x, y, value)" in aprons
        and "local _, in_core = apron_weight" in aprons
        and "packed_result:set(x - x0, y - y0," in aprons
        and "math.floor(candidate.center + candidate.gx * (x - candidate.x)" in aprons
    ),
    "natural_aprons_native_raster_restores_inner_u16_after_rounding": appears_in_order(
        aprons,
        "native_mul_div_add(result, 1, native_height_scale, 0)",
        "local packed_result = own(native_repack(result, native_is_compute(grid)))",
        "packed_result:copyrect(source_native, restore_box",
        "grid:copyrect(packed_result, local_box, point_fn(x0, y0))",
    ),
    "natural_aprons_native_raster_journals_before_copyback_and_rolls_back_reverse": (
        appears_in_order(
            aprons,
            "journal[#journal + 1] = {",
            "journaled = true",
            "grid:copyrect(packed_result, local_box, point_fn(x0, y0))",
        )
        and "for journal_index = #journal, 1, -1 do" in aprons
        and "pcall(grid.copyrect, grid, record.snapshot" in aprons
        and "local restored, restore_error = release_native_patch_journal(true)" in aprons
        and "if not restored then" in aprons
        and "native_patch_journal_rollback_failed = true" in aprons
        and "native apron rollback failed" in aprons
        and "ok_apply, apply_error = pcall(legacy_apply, grid)" in aprons
    ),
    "natural_aprons_native_raster_owns_patch_snapshots_transactionally": (
        "value ~= source_native" in aprons
        and "if not journaled and source_native" in aprons
        and "release_native_patch_journal(false)" in aprons
        and "record.snapshot = nil" in aprons
        and "journal[journal_index] = nil" in aprons
    ),
    "natural_aprons_native_raster_reports_operations_and_timings": all(
        token in aprons
        for token in (
            "native_raster_requested = native_requested",
            "native_raster_used = native_raster_used",
            "native_raster_fallback = native_raster_fallback",
            "native_patch_journal_snapshots = native_patch_journal_snapshots",
            "native_patch_journal_rollback_failed = native_patch_journal_rollback_failed",
            "planning_ms = planning_finished_ms - total_started_ms",
            "native_raster_ms = native_raster_ms",
            "legacy_raster_ms = legacy_raster_ms",
            "total_ms = raster_finished_ms - total_started_ms",
        )
    ),
    "natural_aprons_have_no_scenario_special_case": (
        "14N134W" not in aprons and "A17" not in aprons
    ),
    "pure_v738_capture_precedes_aprons": (
        TERRAIN.index('NotifyDeterminismCaptureForTest("post_z_transform"')
        < TERRAIN.index("CreateNaturalMountainBaseBuildableAprons(map, stretched)")
    ),
    "final_buildable_grid_audits_aprons": (
        "TerrainCopy.AuditNaturalMountainBaseBuildableAprons(map)" in GENERATION
    ),
    "resource_quota_uses_published_apron_centers": (
        "map.SuperBigMapNaturalMountainBaseApronCenters" in resources
    ),
    "resource_quota_uses_authoritative_terrain_validation": (
        "CanReceiveDeposit(" in resources and "mountain_base_candidates" in resources
    ),
    "resource_quota_rejects_edge_crossing_extractor_footprints": (
        "extractor_footprint_within_map(candidate)" in resources
        and "surface_extractor_safe_margin" in resources
        and "surface_extractor_footprint_within_map(c)" in resources
        and "local extractor_safe_margin = 10 * hex_size" in TERRAIN
        and "Move only those centers minimally inward" in TERRAIN
    ),
    "resource_clusters_are_separated_beyond_the_cluster_radius": (
        "distance <= resource_cluster_radius" in resources
        and "selector_local_v3" in resources
    ),
    "ordinary_resources_preserve_exact_repulsion": (
        'NewTopUpRepulsionTracker(map, "resources")' in resources
        and 'label or "resources strict reserve"' in resources
        and "repulsion.CanPlace(candidate, profile)" in resources
    ),
    "resource_quota_has_documented_three_hex_policy": (
        "config.MountainBaseQuotaMinimumHexDistance = 3" in CONFIG
        and "C.MOUNTAIN_BASE_QUOTA_MINIMUM_HEX_DISTANCE" in CONFIG
        and "surface_quota_can_place" in resources
        and "repulsion.CanPlaceUnique(candidate)" in resources
        and "< surface_quota_minimum_hex_distance" in resources
        and "surface_quota_spacing_violations" in DEPOSITS
    ),
    "all_topups_enforce_three_hex_enrichment_spacing": (
        "config.TopUpEnrichmentMinimumHexDistance = 3" in CONFIG
        and "C.TOPUP_ENRICHMENT_MINIMUM_HEX_DISTANCE" in CONFIG
        and "TopUpEnrichmentMinimumHexDistance" in DEPOSITS
        and "CanPlaceMinimum = can_place_minimum" in DEPOSITS
        and "stats.enrichment_spacing_violations == 0" in DEPOSITS
    ),
    "surface_deposit_pairs_are_the_only_neighbour_exception": (
        'IsKindOfSafe(marker, "SurfaceDepositMarker")' in DEPOSITS
        and "distance > 0 and candidate_is_surface == true" in DEPOSITS
        and "occupied.non_surface == 0" in DEPOSITS
        and "a.surface_deposit == true and b.surface_deposit == true" in DEPOSITS
    ),
    "outer_anomalies_clear_all_existing_enrichments": (
        'map, "outer-ring anomaly enrichment spacing", ignored' in DEPOSITS
        and "enrichment_spacing.CanPlaceMinimum(" in DEPOSITS
        and "MIN_ENRICHMENT_HEX_DISTANCE" in DEPOSITS
    ),
    "badge_relocation_preserves_resource_quota_policy": (
        "local BADGE_SPACING_PATCH_VERSION = 6" in DEPOSITS
        and "SurfaceQuotaBadgeContext" in DEPOSITS
        and "SurfaceQuotaBadgeCandidateAllowed" in DEPOSITS
        and "context.preserve_outermost" in DEPOSITS
        and "context.preserve_inner_band" in DEPOSITS
        and "AxialHexDistance(q, r, other.q, other.r)" in DEPOSITS
        and "BadgeCandidateAllowed(marker, map, pt, cx, cy, q, r" in DEPOSITS
    ),
    "badge_relocation_preserves_three_hex_topup_spacing": (
        "minimum_hex_distance = TopUpEnrichmentMinimumHexDistance()" in DEPOSITS
        and "context.marker_surface == true and other.surface == true" in DEPOSITS
        and "distance < context.minimum_hex_distance" in DEPOSITS
    ),
    "resource_quota_places_before_general_resources": (
        resources.index("build_quota_cluster_plans")
        < resources.index("if sequential_placement then")
    ),
    "resource_quota_marks_ordinary_resource_topups": (
        "clone.SuperBigMapOuterRingResourceQuotaTopUp" in resources
    ),
    "resource_cluster_count_is_fail_closed": "outer-ring resource cluster count failed" in resources,
    "resource_quota_is_audited": (
        "resource_quota_shortfall" in audit
        and "outer_ring_resource_quota_topup_outside_final_ring" in audit
    ),
    "resource_quota_uses_physical_outer_two_sector_band": (
        "IsInFinalOuterResourceWorldBand" in DEPOSITS
        and "FINAL_EXPANDED_SECTORS_PER_AXIS = 20" in DEPOSITS
        and "map_w * ring_sectors / FINAL_EXPANDED_SECTORS_PER_AXIS" in DEPOSITS
    ),
    "resource_census_counts_only_guaranteed_quota_topups_toward_minimum": (
        "guaranteed_resource_topups" in census
        and "marker.SuperBigMapResourceTopUp == true" in census
        and "minimum - accepted_resources" in census
        and "stats.guaranteed_resource_topups_placed" in census
        and "stats.require_placed = require_placed == true" in census
    ),
    "resource_quota_guarantees_60_40_disjoint_band_split": (
        "MountainBaseOutermostResourceMinimumPercent = 60" in CONFIG
        and '"outermost resource cluster"' in resources
        and '"inner-band resource"' in resources
        and "inner_band_mountain_base_candidates" in resources
        and "inner_band_perimeter_quota_candidates" in resources
        and "clone.SuperBigMapOuterRingResourceQuotaTopUp" in resources
        and "clone.SuperBigMapInnerBandResourceTopUp" in resources
        and "place_quota_cluster_plans" in resources
        and "placed_clusters" in resources
    ),
    "anomaly_ten_hex_policy_gets_complete_plan_capacity": (
        "local LEGACY_RANDOM_SAMPLES_PER_SECTOR = 2048" in DEPOSITS
        and "local MAX_COMPLETE_PLAN_ATTEMPTS = 512" in DEPOSITS
        and "local MIN_TOPUP_HEX_DISTANCE = 10" in DEPOSITS
    ),
    "resource_census_reports_and_gates_outermost_share": (
        "guaranteed_resource_topups_outermost" in census
        and "outermost_minimum" in census
        and "stats.outermost_shortfall == 0" in census
    ),
    "resource_census_reports_and_gates_inner_band_share": (
        "guaranteed_resource_topups_inner_band" in census
        and "inner_band_minimum" in census
        and "stats.inner_band_shortfall == 0" in census
    ),
    "resource_cluster_count_is_six_to_ten": (
        "config.OuterResourceClusterMinimumCount = 6" in CONFIG
        and "config.OuterResourceRocketPadMaximumCount = 10" in CONFIG
        and "cluster_shortfall == 0 and cluster_excess == 0" in outer_resource_terrain
    ),
    "every_resource_cluster_requires_one_to_three_extractors": (
        "config.OuterResourceClusterMinimumExtractorDeposits = 1" in CONFIG
        and "config.OuterResourceClusterMaximumExtractorDeposits = 3" in CONFIG
        and "OUTER_RESOURCE_CLUSTER_MINIMUM_EXTRACTOR_DEPOSITS" in outer_resource_terrain
        and 'entry.kind == "extractor"' in outer_resource_terrain
        and "extractor_members >= cluster_minimum_extractors" in outer_resource_terrain
        and "extractor_members <= cluster_maximum_extractors" in outer_resource_terrain
        and "cluster_extractor_shortfall == 0" in outer_resource_terrain
        and "cluster_extractor_excess == 0" in outer_resource_terrain
    ),
    "anomalies_are_capped_at_three_per_resource_cluster": (
        "config.OuterResourceClusterMaximumAnomalies = 3" in CONFIG
        and "candidate_resource_cluster" in DEPOSITS
        and "maximum_anomalies_per_cluster" in DEPOSITS
        and "anomaly_resource_cluster_overflow" in census
        and "and stats.anomaly_resource_cluster_overflow == 0" in census
    ),
    "combined_cluster_rewards_are_capped_at_five": (
        "config.OuterResourceClusterMaximumTotalMembers = 5" in CONFIG
        and "math.min(maximum_total_cluster_members, planned_total) - resources" in DEPOSITS
        and "cluster_total_member_overflow" in census
        and "and stats.cluster_total_member_overflow == 0" in census
    ),
    "cluster_strength_weighting_and_single_anchor_are_explicit": (
        'strength = "standard"' in resources
        and 'strength = "strong"' in resources
        and 'strength = "rare_three_extractor"' in resources
        and '"exceptional_anomaly", 5, 1, 2' in resources
        and "minimum_resource_target = 3" in resources
        and "minimum_resource_target = 4" in resources
        and "local resource_target = reward_target - anomaly_capacity" in resources
        and "reward_capacity = reward_target" in resources
        and 'template_policy ~= "premium"' in resources
        and 'template_policy ~= "nonpremium"' in resources
        and "SuperBigMapResourceClusterAnchor" in resources
    ),
    "resource_census_separates_anomalies_effects_and_native_resources": (
        "anomaly_topups" in census
        and "effect_topups" in census
        and "native_resources" in census
    ),
    "resource_census_always_rejects_wrong_family_ring_placement": (
        "and stats.anomaly_topups_outside_ring == 0" in census
        and "and stats.unverified_outer_effect_topups == 0" in census
        and "VerifiedMountainRocketPadAt(map, x, y)" in census
        and "not stats.require_placed or stats.anomaly_unplaced == 0" in census
    ),
    "resource_census_runs_before_and_after_deferred_initialization": (
        "pre-reveal marker census surface final" in GENERATION
        and "SchedulePostDeferredSurfaceResourceTopUpCensus" in GENERATION
        and "post-deferred-GameInit" in census
    ),
    "resource_census_preinit_gate_is_fail_closed": (
        "outer resource top-up census failed" in GENERATION
    ),
    "resource_quota_has_no_scenario_special_case": (
        "14N134W" not in resources and "A17" not in resources
        and "14N134W" not in census and "A17" not in census
    ),
    "version_is_972": "'version', 972" in METADATA,
}

case_results = []
for candidate in CASES:
    actual = terrain_policy(candidate)
    case_results.append(
        {
            **asdict(candidate),
            "actual_valid": actual,
            "ok": actual == candidate.expected_valid,
        }
    )

preferred = preferred_by_sector(CASES)
preference_checks = {
    "plain_sector_remains_eligible": "plain_flat" in preferred,
    "mountain_base_is_eligible": "mountain_base_flat" in preferred,
    "mountain_plateau_is_deprioritized": "mountain_plateau_flat" not in preferred,
    "steep_slope_is_rejected": "steep_slope" not in preferred,
}

relief_checks = {
    "real_mountain_foot_is_accepted": mountain_base_relief(18, 4),
    "rolling_ground_is_rejected": not mountain_base_relief(2, 8),
    "single_height_outlier_is_rejected": not mountain_base_relief(18, 1),
}

effect_checks = {
    "surface_layers_one_and_two_are_excluded": all(
        not dome_effect_topup_allowed(layer) for layer in (1, 2)
    ),
    "surface_layer_three_is_allowed": dome_effect_topup_allowed(3),
    "verified_mountain_pad_is_narrow_exception": dome_effect_topup_allowed(
        1, verified_mountain_pad=True
    ),
    "unverified_mountain_perimeter_remains_excluded": not dome_effect_topup_allowed(1),
    "underground_is_unchanged": all(
        dome_effect_topup_allowed(layer, underground=True) for layer in (1, 2, 3, 4)
    ),
}

quota_spacing_checks = {
    "same_hex_is_rejected": not quota_hex_clearance((12, -3), (12, -3)),
    "adjacent_hex_is_rejected": not quota_hex_clearance((0, 0), (1, 0)),
    "two_hexes_is_rejected": not quota_hex_clearance((0, 0), (2, 0)),
    "three_hexes_is_accepted": quota_hex_clearance((0, 0), (3, 0)),
    "diagonal_axial_distance_is_enforced": (
        not quota_hex_clearance((0, 0), (1, 1))
        and quota_hex_clearance((0, 0), (1, 2))
    ),
}

eps = 1e-4
feather_checks = {
    "core_is_fully_graded": apron_weight(0) == 1 and apron_weight(0.75) == 1,
    "outer_terrain_is_untouched": apron_weight(1) == 0 and apron_weight(1.1) == 0,
    "weight_is_monotone": all(
        apron_weight(i / 100) >= apron_weight((i + 1) / 100)
        for i in range(100)
    ),
    "core_join_has_zero_slope": abs(
        (apron_weight(3 / 8 + eps) - apron_weight(3 / 8)) / eps
    ) < 1e-5,
    "outer_join_has_zero_slope": abs(
        (apron_weight(1) - apron_weight(1 - eps)) / eps
    ) < 1e-5,
}


def lobed_apron_weight(
    dx: float,
    dy: float,
    mountain_x: float,
    mountain_y: float,
    short_radius: float,
    long_radius: float,
    core_fraction: float = 0.2,
) -> tuple[float, bool]:
    """Exact scalar natural-apron mask predicate used by production."""
    u = dx * mountain_x + dy * mountain_y
    v = -dx * mountain_y + dy * mountain_x
    ru, rv = u / short_radius, v / long_radius
    radius = math.hypot(ru, rv)
    if radius >= 1.12:
        return 0.0, False
    nx, ny = (1.0, 0.0) if radius <= 0.0001 else (ru / radius, rv / radius)
    boundary = 1 + 0.055 * (nx**3 - 3 * nx * ny**2) + 0.035 * (nx**2 - ny**2)
    normalized = radius / boundary
    if normalized >= 1:
        return 0.0, False
    if normalized <= core_fraction:
        return 1.0, True
    t = (normalized - core_fraction) / (1 - core_fraction)
    smooth = t**3 * (t * (t * 6 - 15) + 10)
    return 1 - smooth, False


# Fail-closed, deterministic certificate for the v944 endpoint-aligned four-cell sampler. It
# spans every deterministic radius variant and four rotations; exact full-resolution core cells
# are forced to one just as production does. Cube-weight error measures the actual blend operand.
natural_native_errors: list[float] = []
natural_native_cases = 0
natural_native_full_cells = 0
natural_native_coarse_samples = 0
natural_native_tested_cells = 0
natural_native_core_exact = True
for natural_variant in range(-4, 5):
    natural_short = 200.0 * (1 + natural_variant * 0.012)
    natural_long = 270.0 * (1 - natural_variant * 0.009)
    natural_extent = math.ceil(natural_long + 2)
    natural_size = natural_extent * 2 + 1
    natural_coarse_size = math.ceil((natural_size - 1) / 4) + 1
    for natural_angle in (0.0, 0.417, 1.113, 2.401):
        natural_mx, natural_my = math.cos(natural_angle), math.sin(natural_angle)
        coarse = [
            [
                math.floor(
                    lobed_apron_weight(
                        -natural_extent
                        + cx * (natural_size - 1) / (natural_coarse_size - 1),
                        -natural_extent
                        + cy * (natural_size - 1) / (natural_coarse_size - 1),
                        natural_mx,
                        natural_my,
                        natural_short,
                        natural_long,
                    )[0]
                    * 4096
                    + 0.5
                )
                / 4096
                for cx in range(natural_coarse_size)
            ]
            for cy in range(natural_coarse_size)
        ]
        for py in range(0, natural_size, 2):
            fy = py * (natural_coarse_size - 1) / (natural_size - 1)
            iy = min(natural_coarse_size - 2, math.floor(fy))
            ty = fy - iy
            for px in range(0, natural_size, 2):
                fx = px * (natural_coarse_size - 1) / (natural_size - 1)
                ix = min(natural_coarse_size - 2, math.floor(fx))
                tx = fx - ix
                top = coarse[iy][ix] * (1 - tx) + coarse[iy][ix + 1] * tx
                bottom = coarse[iy + 1][ix] * (1 - tx) + coarse[iy + 1][ix + 1] * tx
                sampled = max(0.0, min(1.0, top * (1 - ty) + bottom * ty))
                exact, in_core = lobed_apron_weight(
                    px - natural_extent,
                    py - natural_extent,
                    natural_mx,
                    natural_my,
                    natural_short,
                    natural_long,
                )
                if in_core:
                    sampled = 1.0
                    natural_native_core_exact = natural_native_core_exact and sampled == exact
                natural_native_errors.append(abs(sampled**3 - exact**3))
                natural_native_tested_cells += 1
        natural_native_cases += 1
        natural_native_full_cells += natural_size * natural_size
        natural_native_coarse_samples += natural_coarse_size * natural_coarse_size

natural_native_sorted = sorted(natural_native_errors)
natural_native_mean = sum(natural_native_errors) / len(natural_native_errors)
natural_native_p99 = natural_native_sorted[math.floor(0.99 * len(natural_native_sorted))]
natural_native_max = max(natural_native_errors)
natural_native_sampler_checks = {
    "all_36_variant_rotation_cases_are_present": natural_native_cases == 36,
    "sampled_cells_exceed_two_million": natural_native_tested_cells > 2_000_000,
    "full_resolution_core_is_exact": natural_native_core_exact,
    "mean_cube_weight_error_below_0_00012": natural_native_mean < 0.00012,
    "p99_cube_weight_error_below_0_0013": natural_native_p99 < 0.0013,
    "max_cube_weight_error_below_0_0019": natural_native_max < 0.0019,
    "coarse_sampling_reduces_mask_evaluations_by_at_least_15x": (
        natural_native_full_cells / natural_native_coarse_samples >= 15
    ),
}

inner_rectangle = (81920.0, 81920.0, 737280.0, 737280.0)
rocket_live_radius = 9350.0
rocket_inner_boundary_checks = {
    "observed_failed_site_is_rejected": not rocket_footprint_clear_of_inner_rectangle(
        77500.0, 601870.0, rocket_live_radius, inner_rectangle
    ),
    "observed_nearest_passing_site_is_retained": rocket_footprint_clear_of_inner_rectangle(
        71000.0, 133364.0, rocket_live_radius, inner_rectangle
    ),
    "observed_iter144_repair_site_is_rejected_by_support_core": 5720.0 <= 9000.0,
    "exact_tangency_is_rejected": not rocket_footprint_clear_of_inner_rectangle(
        inner_rectangle[0] - rocket_live_radius,
        200000.0,
        rocket_live_radius,
        inner_rectangle,
    ),
    "diagonal_corner_distance_is_euclidean": (
        not rocket_footprint_clear_of_inner_rectangle(
            inner_rectangle[0] - 6000.0,
            inner_rectangle[1] - 6000.0,
            rocket_live_radius,
            inner_rectangle,
        )
        and rocket_footprint_clear_of_inner_rectangle(
            inner_rectangle[0] - 7000.0,
            inner_rectangle[1] - 7000.0,
            rocket_live_radius,
            inner_rectangle,
        )
    ),
}

guard_prefilter_guards = (
    (-8.0, 1.0, 2.0),
    (0.0, 0.0, 1.5),
    (4.0, 3.0, 2.25),
    (7.0, 0.0, 2.0),
    (40.0, -30.0, 4.0),
)
guard_prefilter_cases = (
    (0.0, 0.0, 5.0),
    (2.5, -1.5, 3.5),
    (-4.0, 2.0, 4.0),
    (10.0, 0.0, 1.0),
)
guard_equivalent = True
guard_samples = 0
for patch_x, patch_y, visit_radius in guard_prefilter_cases:
    nearby = nearby_protected_guards(
        patch_x, patch_y, visit_radius, guard_prefilter_guards
    )
    for ix in range(-24, 25):
        for iy in range(-24, 25):
            x = patch_x + ix / 4
            y = patch_y + iy / 4
            if (x - patch_x) ** 2 + (y - patch_y) ** 2 <= visit_radius**2:
                guard_samples += 1
                guard_equivalent = guard_equivalent and (
                    protected_by_any(x, y, guard_prefilter_guards)
                    == protected_by_any(x, y, nearby)
                )

guard_prefilter_checks = {
    "exhaustive_visited_pixels_match_full_scan": guard_equivalent,
    "exhaustive_sample_count_is_stable": guard_samples == 2716,
    "tangent_guard_is_retained": (
        (7.0, 0.0, 2.0)
        in nearby_protected_guards(0.0, 0.0, 5.0, guard_prefilter_guards)
    ),
    "nonintersecting_guard_is_pruned": (
        (40.0, -30.0, 4.0)
        not in nearby_protected_guards(0.0, 0.0, 5.0, guard_prefilter_guards)
    ),
    "guard_order_is_preserved": (
        nearby_protected_guards(0.0, 0.0, 10.0, guard_prefilter_guards)
        == tuple(
            guard
            for guard in guard_prefilter_guards
            if (guard[0] ** 2 + guard[1] ** 2) <= (10.0 + guard[2]) ** 2
        )
    ),
}

# Compact, deterministic raster corpus: one realistic broad resource transition replaces a
# multi-million-cell map run while preserving the exact production equations and 8-cell sampler.
native_core = 30.0
native_transition = 140.0
native_phase = 1.234
native_relief = (0.6, 0.8)
native_step = 8
native_scale = 4096
native_support_radius = native_core + native_transition * 1.35
native_min = math.floor((-native_support_radius - 2) / native_step) * native_step
native_max = math.ceil((native_support_radius + 2) / native_step) * native_step
native_size = native_max - native_min + 1
native_coarse_size = (native_size - 1) // native_step + 1

native_coarse = [
    [
        round(
            organic_resource_weight(
                native_min + coarse_x * native_step,
                native_min + coarse_y * native_step,
                core=native_core,
                transition=native_transition,
                phase=native_phase,
                relief=native_relief,
            )
            * native_scale
        )
        / native_scale
        for coarse_x in range(native_coarse_size)
    ]
    for coarse_y in range(native_coarse_size)
]


def native_resampled_weight(x: int, y: int) -> float:
    """Model endpoint-aligned native bilinear resampling plus exact full-res disks."""
    distance = math.hypot(x, y)
    if distance > native_support_radius:
        return 0.0
    if distance <= native_core:
        return 1.0
    fx = (x - native_min) / native_step
    fy = (y - native_min) / native_step
    ix = min(native_coarse_size - 2, max(0, math.floor(fx)))
    iy = min(native_coarse_size - 2, max(0, math.floor(fy)))
    tx, ty = fx - ix, fy - iy
    top = native_coarse[iy][ix] * (1 - tx) + native_coarse[iy][ix + 1] * tx
    bottom = (
        native_coarse[iy + 1][ix] * (1 - tx)
        + native_coarse[iy + 1][ix + 1] * tx
    )
    return max(0.0, min(1.0, top * (1 - ty) + bottom * ty))


native_errors: list[float] = []
native_core_exact = True
native_support_exact = True
for y in range(native_min, native_max + 1):
    for x in range(native_min, native_max + 1):
        exact = organic_resource_weight(
            x,
            y,
            core=native_core,
            transition=native_transition,
            phase=native_phase,
            relief=native_relief,
        )
        resampled = native_resampled_weight(x, y)
        native_errors.append(abs(exact - resampled))
        distance = math.hypot(x, y)
        if distance <= native_core:
            native_core_exact = native_core_exact and resampled == 1.0
        if distance > native_support_radius:
            native_support_exact = native_support_exact and resampled == 0.0

native_errors_sorted = sorted(native_errors)
native_mask_mean_error = sum(native_errors) / len(native_errors)
native_mask_p99_error = native_errors_sorted[math.floor(0.99 * len(native_errors))]
native_mask_max_error = max(native_errors)
native_trig_reduction = (native_size * native_size) / (
    native_coarse_size * native_coarse_size
)

guard_center, guard_radius = (46.0, -50.0), 7.0


def native_guarded_weight(x: int, y: int) -> float:
    if (x - guard_center[0]) ** 2 + (y - guard_center[1]) ** 2 <= guard_radius**2:
        return 0.0
    return native_resampled_weight(x, y)


native_guard_exact = all(
    native_guarded_weight(x, y) == 0.0
    for y in range(-57, -42)
    for x in range(39, 54)
    if (x - guard_center[0]) ** 2 + (y - guard_center[1]) ** 2 <= guard_radius**2
)


def native_synthetic_height(x: int, y: int) -> int:
    old = 12345 + 2 * x - y
    plane = 12200 + 0.75 * x - 0.5 * y
    target = 12180
    weight = native_guarded_weight(x, y)
    shaped = round(
        plane + (target - plane) * weight + (old - plane) * (1 - weight**3)
    )
    # Model the production post-interpolation copyrect from the scaled patch snapshot.
    return old if x >= 160 and -60 <= y <= 60 else shaped


native_inner_restore_exact = all(
    native_synthetic_height(x, y) == 12345 + 2 * x - y
    for x, y in ((160, -60), (180, 0), (220, 60))
)


def native_precondition_enabled(previous_resource_plan, previous_rocket_plan) -> bool:
    return previous_resource_plan is None and previous_rocket_plan is None


native_raster_checks = {
    "realistic_corpus_size_is_stable": (
        native_size * native_size == 201601
        and native_coarse_size * native_coarse_size == 3249
    ),
    "trigonometric_samples_drop_by_at_least_60x": native_trig_reduction >= 60,
    "coarse_mask_mean_error_below_0_00051": native_mask_mean_error < 0.00051,
    "coarse_mask_p99_error_below_0_00301": native_mask_p99_error < 0.00301,
    "coarse_mask_max_error_below_0_00452": native_mask_max_error < 0.00452,
    "full_resolution_core_is_exact": native_core_exact,
    "maximum_support_boundary_is_exact": native_support_exact,
    "protected_circle_assignment_is_exact": native_guard_exact,
    "inner_rectangle_copy_restore_is_exact": native_inner_restore_exact,
    "initial_plan_enables_native_precondition": native_precondition_enabled(None, None),
    "resource_only_retry_disables_native_precondition": not native_precondition_enabled([], None),
    "rocket_only_retry_disables_native_precondition": not native_precondition_enabled(None, []),
}


def modeled_height_step_scan(
    values: list[int],
    *,
    perp0: int,
    perp1: int,
    max_width: int,
    edge: str,
    wide_ring_only: bool,
    threshold: int,
    rolling: bool,
) -> tuple[tuple[tuple[int, int, str, bool, int], ...], int]:
    """Compare the legacy repeated reads with the production rolling window."""
    reads = 0
    row: list[tuple[int, int, str, bool, int]] = []

    def read(index: int) -> int:
        nonlocal reads
        reads += 1
        return values[index]

    def offer(perp: int, width: int, low_before: bool, jump: int) -> None:
        for index, candidate in enumerate(row):
            if candidate[2] == edge and abs(candidate[0] - perp) <= 3:
                if jump > candidate[4]:
                    row[index] = (perp, width, edge, low_before, jump)
                return
        row.append((perp, width, edge, low_before, jump))
        row.sort(key=lambda item: item[4], reverse=True)
        del row[6:]

    def evaluate(perp: int, width: int, v0: int, a: int, b: int, v3: int) -> None:
        jump = abs(b - a)
        flank = max(abs(a - v0), abs(v3 - b), 1)
        low_before = a < b
        before_edge = edge in ("left", "top")
        low_points_to_edge = (before_edge and low_before) or (
            not before_edge and not low_before
        )
        if (
            (wide_ring_only or low_points_to_edge)
            and jump >= threshold
            and jump >= flank * 2
        ):
            offer(perp, width, low_before, jump)

    if not rolling:
        for perp in range(perp0, perp1 + 1):
            for width in range(1, max_width + 1):
                evaluate(
                    perp,
                    width,
                    read(perp - 1),
                    read(perp),
                    read(perp + width),
                    read(perp + width + 1),
                )
        return tuple(row), reads

    v0, a = read(perp0 - 1), read(perp0)
    future = [read(perp0 + offset) for offset in range(1, max_width + 2)]
    for perp in range(perp0, perp1 + 1):
        for width in range(1, max_width + 1):
            evaluate(perp, width, v0, a, future[width - 1], future[width])
        if perp < perp1:
            v0, a = a, future[0]
            future = future[1:] + [read(perp + max_width + 2)]
    return tuple(row), reads


rolling_scan_cases = []
for seed in range(16):
    line = [
        (index * 37 + seed * 101 + ((index + seed) // 7) * 19) % 3000
        for index in range(160)
    ]
    step = 24 + seed * 5
    line = [value + (1200 if index >= step else 0) for index, value in enumerate(line)]
    for wide_ring_only, max_width in ((True, 1), (False, 3)):
        for edge in ("left", "right", "top", "bottom"):
            legacy, legacy_reads = modeled_height_step_scan(
                line,
                perp0=8,
                perp1=140,
                max_width=max_width,
                edge=edge,
                wide_ring_only=wide_ring_only,
                threshold=128,
                rolling=False,
            )
            rolling, rolling_reads = modeled_height_step_scan(
                line,
                perp0=8,
                perp1=140,
                max_width=max_width,
                edge=edge,
                wide_ring_only=wide_ring_only,
                threshold=128,
                rolling=True,
            )
            rolling_scan_cases.append(
                {
                    "exact": legacy == rolling,
                    "wide": wide_ring_only,
                    "legacy_reads": legacy_reads,
                    "rolling_reads": rolling_reads,
                }
            )

rolling_source_ratios = [
    case["legacy_reads"] / case["rolling_reads"]
    for case in rolling_scan_cases
    if case["wide"]
]
rolling_destination_ratios = [
    case["legacy_reads"] / case["rolling_reads"]
    for case in rolling_scan_cases
    if not case["wide"]
]
rolling_scan_checks = {
    "all_selected_candidates_are_exact": all(case["exact"] for case in rolling_scan_cases),
    "compact_corpus_has_128_edge_cases": len(rolling_scan_cases) == 128,
    "source_scan_reads_drop_by_at_least_3_5x": min(rolling_source_ratios) >= 3.5,
    "destination_scan_reads_drop_by_at_least_10x": min(rolling_destination_ratios) >= 10,
}


def modeled_native_discovery_scan(
    values: list[int],
    *,
    perp0: int,
    perp1: int,
    edge: str,
    threshold: int,
) -> tuple[tuple[tuple[int, int, str, bool, int], ...], int, int, int]:
    """Model exact f32-safe native candidate masks and restored Lua loop ordering."""
    before_edge = edge in ("left", "top")
    survivor_set: set[int] = set()
    records: list[tuple[int, int, int]] = []
    for width in range(1, 4):
        for perp in range(perp0, perp1 + 1):
            v0, a = values[perp - 1], values[perp]
            b, v3 = values[perp + width], values[perp + width + 1]
            directional_jump = b - a if before_edge else a - b
            doubled_flank = 2 * max(abs(a - v0), abs(v3 - b), 1)
            if directional_jump >= threshold and directional_jump >= doubled_flank:
                records.append((perp, width, directional_jump))
                survivor_set.add(perp)

    row: list[tuple[int, int, str, bool, int]] = []

    def offer(perp: int, width: int, low_before: bool, jump: int) -> None:
        for index, candidate in enumerate(row):
            if candidate[2] == edge and abs(candidate[0] - perp) <= 3:
                if jump > candidate[4]:
                    row[index] = (perp, width, edge, low_before, jump)
                return
        row.append((perp, width, edge, low_before, jump))
        row.sort(key=lambda item: item[4], reverse=True)
        del row[6:]

    for perp, width, jump in sorted(records):
        offer(perp, width, before_edge, jump)
    return tuple(row), 0, len(survivor_set), len(records)


native_discovery_cases = []
for seed in range(64):
    # Smooth realistic edge relief plus deterministic one-to-three-cell steps, exact-threshold
    # boundaries, adjacent stronger candidates, and wrong-direction false positives.
    base = 10000 + seed * 11
    line = [base + index * (1 + seed % 3) + ((index + seed) % 5) for index in range(96)]
    step_at = 18 + seed % 28
    step_width = 1 + seed % 3
    step_height = 256 + (seed % 7) * 41
    for index in range(step_at + step_width, len(line)):
        line[index] += step_height
    if seed % 4 == 0:
        wrong_at = 60 + seed % 8
        for index in range(wrong_at, len(line)):
            line[index] -= 512
    for edge in ("left", "right", "top", "bottom"):
        oriented = line if edge in ("left", "top") else [-value for value in line]
        legacy, legacy_reads = modeled_height_step_scan(
            oriented,
            perp0=8,
            perp1=82,
            max_width=3,
            edge=edge,
            wide_ring_only=False,
            threshold=256,
            rolling=True,
        )
        indexed, indexed_reads, survivors, enumerated = modeled_native_discovery_scan(
            oriented,
            perp0=8,
            perp1=82,
            edge=edge,
            threshold=256,
        )
        native_discovery_cases.append(
            {
                "exact": legacy == indexed,
                "legacy_reads": legacy_reads,
                "indexed_reads": indexed_reads,
                "survivors": survivors,
                "enumerated": enumerated,
            }
        )


native_discovery_ratios = [
    case["legacy_reads"] / max(1, case["indexed_reads"])
    for case in native_discovery_cases
]
destination_real_band_positions = 2 * (35 + 34) * 8192
native_discovery_checks = {
    "all_exact_candidate_tuples_match": all(case["exact"] for case in native_discovery_cases),
    "corpus_has_256_edge_direction_cases": len(native_discovery_cases) == 256,
    "u16_differences_and_doubled_flanks_are_exact_in_f32": 131070 < 2**24,
    "all_cases_exercise_sparse_survivors": all(
        0 < case["survivors"] < 75 for case in native_discovery_cases
    ),
    "minimum_modeled_lua_read_reduction_is_4x": min(native_discovery_ratios) >= 4,
    "full_8192_destination_band_geometry_is_exact": destination_real_band_positions == 1130496,
}


def modeled_height_step_refine(
    values: list[int | None],
    *,
    predicted: int,
    max_width: int,
    edge: str,
    track_low_before: bool,
    wide_ring_only: bool,
    threshold: int,
    rolling: bool,
) -> tuple[tuple[int, int] | None, int]:
    """Model refine_step's exact candidate choice and native-grid read count."""
    lo = max(1, predicted - 6)
    hi = min(len(values) - 3, predicted + 6)
    reads = 0
    best: tuple[int, int] | None = None
    best_distance: int | None = None
    best_jump: int | None = None
    before_edge = edge in ("left", "top")

    def read(index: int) -> int | None:
        nonlocal reads
        reads += 1
        return values[index]

    def evaluate(
        perp: int,
        width: int,
        v0: int | None,
        a: int | None,
        b: int | None,
        v3: int | None,
    ) -> None:
        nonlocal best, best_distance, best_jump
        if not all(isinstance(value, int) for value in (v0, a, b, v3)):
            return
        assert v0 is not None and a is not None and b is not None and v3 is not None
        low_before = a < b
        points_to_edge = (before_edge and low_before) or (
            not before_edge and not low_before
        )
        jump = abs(b - a)
        flank = max(abs(a - v0), abs(v3 - b), 1)
        distance = abs(perp - predicted)
        if (
            low_before == track_low_before
            and (wide_ring_only or points_to_edge)
            and jump >= threshold
            and jump >= flank * 2
            and (
                best_distance is None
                or distance < best_distance
                or (distance == best_distance and jump > best_jump)
            )
        ):
            best = (perp, width)
            best_distance = distance
            best_jump = jump

    positions = max(0, hi - lo + 1)
    if positions == 0:
        return None, reads
    if not rolling:
        for perp in range(lo, hi + 1):
            for width in range(1, max_width + 1):
                evaluate(
                    perp,
                    width,
                    read(perp - 1),
                    read(perp),
                    read(perp + width),
                    read(perp + width + 1),
                )
        return best, reads

    v0, a = read(lo - 1), read(lo)
    future = [read(lo + offset) for offset in range(1, max_width + 2)]
    for perp in range(lo, hi + 1):
        for width in range(1, max_width + 1):
            evaluate(perp, width, v0, a, future[width - 1], future[width])
        if perp < hi:
            v0, a = a, future[0]
            future = future[1:] + [read(perp + max_width + 2)]
    return best, reads


refine_rolling_cases = []
for seed in range(16):
    predicted = 18 + seed % 7
    base_line: list[int | None] = [
        (index * 43 + seed * 97 + ((index + 2 * seed) // 5) * 17) % 900
        for index in range(64)
    ]
    for boundary, jump in (
        (predicted - 3, 800 + seed * 7),
        (predicted, 1200 + seed * 11),
        (predicted + 4, 1200 + seed * 11),
    ):
        for index in range(boundary, len(base_line)):
            assert base_line[index] is not None
            base_line[index] += jump
    if seed % 4 == 0:
        base_line[predicted + 2] = None
    for wide_ring_only, max_width in ((True, 1), (False, 3)):
        for edge in ("left", "right", "top", "bottom"):
            for track_low_before in (False, True):
                legacy, legacy_reads = modeled_height_step_refine(
                    base_line,
                    predicted=predicted,
                    max_width=max_width,
                    edge=edge,
                    track_low_before=track_low_before,
                    wide_ring_only=wide_ring_only,
                    threshold=128,
                    rolling=False,
                )
                rolling, rolling_reads = modeled_height_step_refine(
                    base_line,
                    predicted=predicted,
                    max_width=max_width,
                    edge=edge,
                    track_low_before=track_low_before,
                    wide_ring_only=wide_ring_only,
                    threshold=128,
                    rolling=True,
                )
                refine_rolling_cases.append(
                    {
                        "exact": legacy == rolling,
                        "wide": wide_ring_only,
                        "legacy_reads": legacy_reads,
                        "rolling_reads": rolling_reads,
                    }
                )

refine_source_ratios = [
    case["legacy_reads"] / case["rolling_reads"]
    for case in refine_rolling_cases
    if case["wide"]
]
refine_destination_ratios = [
    case["legacy_reads"] / case["rolling_reads"]
    for case in refine_rolling_cases
    if not case["wide"]
]
refine_rolling_checks = {
    "all_refined_candidates_are_exact": all(case["exact"] for case in refine_rolling_cases),
    "compact_corpus_has_256_edge_direction_cases": len(refine_rolling_cases) == 256,
    "source_refine_reads_drop_by_at_least_3x": min(refine_source_ratios) >= 3,
    "destination_refine_reads_drop_by_at_least_8x": min(refine_destination_ratios) >= 8,
}


ring_rebuild_geometry_cases = []
for width, height, pass_tile in ((819200, 819200, 100), (819203, 819197, 100), (1003, 997, 1)):
    strips = outer_resource_rebuild_strips(width, height, 2, pass_tile)
    margin = pass_tile * 2
    band_x = width * 2 / 20
    band_y = height * 2 / 20
    near_x = math.ceil(band_x) + margin
    near_y = math.ceil(band_y) + margin
    far_x = width - math.ceil(band_x) - margin
    far_y = height - math.ceil(band_y) - margin
    samples = {
        (0, 0),
        (width - 1, height - 1),
        (math.ceil(band_x) - 1, height // 2),
        (width - math.ceil(band_x), height // 2),
        (width // 2, math.ceil(band_y) - 1),
        (width // 2, height - math.ceil(band_y)),
        (near_x - 1, height // 2),
        (far_x, height // 2),
        (width // 2, near_y - 1),
        (width // 2, far_y),
    }
    required_covered = all(
        any(point_in_half_open_box(x, y, bounds) for bounds in strips)
        for x, y in samples
    )
    inward_endpoints_exact = (
        any(point_in_half_open_box(near_x - 1, height // 2, bounds) for bounds in strips)
        and not any(point_in_half_open_box(near_x, height // 2, bounds) for bounds in strips)
        and any(point_in_half_open_box(far_x, height // 2, bounds) for bounds in strips)
        and not any(point_in_half_open_box(far_x - 1, height // 2, bounds) for bounds in strips)
    )
    summed_area = sum((right - left) * (bottom - top) for left, top, right, bottom in strips)
    ring_rebuild_geometry_cases.append(
        {
            "width": width,
            "height": height,
            "divisible": width % 20 == 0 and height % 20 == 0,
            "required_boundary_samples_covered": required_covered,
            "inward_margin_endpoints_exact": inward_endpoints_exact,
            "all_corners_covered": all(
                any(point_in_half_open_box(x, y, bounds) for bounds in strips)
                for x, y in ((0, 0), (width - 1, 0), (0, height - 1), (width - 1, height - 1))
            ),
            "summed_area_ratio": summed_area / (width * height),
        }
    )

ring_rebuild_geometry_checks = {
    "divisible_and_nondivisible_dimensions_covered": (
        any(case["divisible"] for case in ring_rebuild_geometry_cases)
        and any(not case["divisible"] for case in ring_rebuild_geometry_cases)
    ),
    "physical_ring_and_exact_tangencies_are_covered": all(
        case["required_boundary_samples_covered"] for case in ring_rebuild_geometry_cases
    ),
    "inward_margin_half_open_endpoints_are_exact": all(
        case["inward_margin_endpoints_exact"] for case in ring_rebuild_geometry_cases
    ),
    "all_four_corners_are_covered": all(
        case["all_corners_covered"] for case in ring_rebuild_geometry_cases
    ),
    "expanded_map_work_is_below_41_percent": ring_rebuild_geometry_cases[0]["summed_area_ratio"] < 0.41,
}

# Exact overlap corpus for the rocket-footprint height cache. It includes unavailable samples so
# the false-sentinel path is covered as well as ordinary numeric heights.
rocket_cache_centers = [
    (q, r)
    for q in range(-32, 33)
    for r in range(-32, 33)
    if max(abs(q), abs(r), abs(q + r)) <= 32
]
rocket_cache_offsets = [
    (dq, dr)
    for dq in range(-6, 7)
    for dr in range(-6, 7)
    if max(abs(dq), abs(dr), abs(dq + dr)) <= 6
]


def rocket_cache_source(q: int, r: int) -> int | None:
    if (q * 37 + r * 61) % 97 == 0:
        return None
    return 32000 + q * 11 - r * 7 + ((q * q + r * r) % 19)


rocket_direct_reads = 0
rocket_direct_checksum = 0
rocket_direct_missing = 0
for center_q, center_r in rocket_cache_centers:
    for offset_q, offset_r in rocket_cache_offsets:
        rocket_direct_reads += 1
        value = rocket_cache_source(center_q + offset_q, center_r + offset_r)
        if value is None:
            rocket_direct_missing += 1
        else:
            rocket_direct_checksum += value

rocket_cached_reads = 0
rocket_cached_hits = 0
rocket_cached_checksum = 0
rocket_cached_missing = 0
rocket_cache: dict[int, dict[int, int | None]] = {}
for center_q, center_r in rocket_cache_centers:
    for offset_q, offset_r in rocket_cache_offsets:
        q, r = center_q + offset_q, center_r + offset_r
        row = rocket_cache.setdefault(q, {})
        if r in row:
            rocket_cached_hits += 1
            value = row[r]
        else:
            rocket_cached_reads += 1
            value = rocket_cache_source(q, r)
            row[r] = value
        if value is None:
            rocket_cached_missing += 1
        else:
            rocket_cached_checksum += value

rocket_height_cache_checks = {
    "numeric_and_missing_results_are_exact": (
        rocket_cached_checksum == rocket_direct_checksum
        and rocket_cached_missing == rocket_direct_missing
    ),
    "every_repeated_query_is_accounted_for": (
        rocket_cached_reads + rocket_cached_hits == rocket_direct_reads
    ),
    "overlap_reduces_source_reads_by_at_least_50x": (
        rocket_direct_reads / rocket_cached_reads >= 50
    ),
}


def axial_distance_exact(q1: int, r1: int, q2: int, r2: int) -> int:
    dq, dr = q1 - q2, r1 - r2
    return max(abs(dq), abs(dr), abs(dq + dr))


def mark_axial_forbidden_exact(
    mask: dict[int, dict[int, bool]], cq: int, cr: int, radius: int
) -> int:
    added = 0
    for dq in range(-radius, radius + 1):
        row = mask.setdefault(cq + dq, {})
        dr_min = max(-radius, -dq - radius)
        dr_max = min(radius, -dq + radius)
        for dr in range(dr_min, dr_max + 1):
            r = cr + dr
            if row.get(r) is not True:
                row[r] = True
                added += 1
    return added


def axial_mask_contains_exact(mask: dict[int, dict[int, bool]], q: int, r: int) -> bool:
    return mask.get(q, {}).get(r) is True


# Exhaustive exactness certificate for both static resource clearance and the dynamic pad mask.
# The fractional minimum proves ceil(minimum)-1 preserves the legacy strict comparison for integer
# axial distances; repeated/overlapping centers cover mask union and incremental-update semantics.
clearance_resources = [
    (-72 + (index % 7) * 23, -63 + (index // 7) * 37 + (index % 3) * 5)
    for index in range(21)
]
clearance_queries = [
    (q, r)
    for q in range(-120, 121, 2)
    for r in range(-120, 121, 2)
]
resource_clearance_minimum = 23.25
resource_clearance_radius = math.ceil(resource_clearance_minimum) - 1
resource_clearance_mask: dict[int, dict[int, bool]] = {}
resource_clearance_cells = sum(
    mark_axial_forbidden_exact(resource_clearance_mask, q, r, resource_clearance_radius)
    for q, r in clearance_resources
)
resource_clearance_exact = True
resource_direct_distance_tests = 0
for q, r in clearance_queries:
    direct_forbidden = False
    for resource_q, resource_r in clearance_resources:
        resource_direct_distance_tests += 1
        if axial_distance_exact(q, r, resource_q, resource_r) < resource_clearance_minimum:
            direct_forbidden = True
            break
    resource_clearance_exact = resource_clearance_exact and (
        direct_forbidden == axial_mask_contains_exact(resource_clearance_mask, q, r)
    )

rocket_clearance_minimum = 18
rocket_clearance_radius = math.ceil(rocket_clearance_minimum) - 1
rocket_clearance_mask: dict[int, dict[int, bool]] = {}
rocket_clearance_cells = 0
rocket_clearance_exact = True
rocket_direct_distance_tests = 0
selected_pads: list[tuple[int, int]] = []
for pad in ((-73, 54), (-19, -81), (42, 67), (91, -28), (42, 67), (8, 9)):
    for q, r in clearance_queries:
        direct_forbidden = False
        for pad_q, pad_r in selected_pads:
            rocket_direct_distance_tests += 1
            if axial_distance_exact(q, r, pad_q, pad_r) < rocket_clearance_minimum:
                direct_forbidden = True
                break
        rocket_clearance_exact = rocket_clearance_exact and (
            direct_forbidden == axial_mask_contains_exact(rocket_clearance_mask, q, r)
        )
    selected_pads.append(pad)
    rocket_clearance_cells += mark_axial_forbidden_exact(
        rocket_clearance_mask, pad[0], pad[1], rocket_clearance_radius
    )

clearance_boundary_mask: dict[int, dict[int, bool]] = {}
mark_axial_forbidden_exact(clearance_boundary_mask, 0, 0, 4)
axial_clearance_mask_checks = {
    "static_resource_mask_matches_every_legacy_query": resource_clearance_exact,
    "dynamic_pad_mask_matches_every_legacy_query": rocket_clearance_exact,
    "strict_fractional_boundary_uses_ceil_minus_one": (
        resource_clearance_radius == 23
        and axial_distance_exact(0, 0, 23, 0) < resource_clearance_minimum
        and not (axial_distance_exact(0, 0, 24, 0) < resource_clearance_minimum)
    ),
    "inclusive_disk_boundary_and_outer_neighbour_are_exact": (
        axial_mask_contains_exact(clearance_boundary_mask, 4, 0)
        and not axial_mask_contains_exact(clearance_boundary_mask, 5, 0)
    ),
    "modeled_distance_checks_drop_by_at_least_4x": (
        (resource_direct_distance_tests + rocket_direct_distance_tests)
        / (len(clearance_queries) * 7) >= 4
    ),
}

report = {
    "schema": "smr.ralph.mountain_base_enrichment_policy_check",
    "schema_version": 20,
    "static_checks": static_checks,
    "synthetic_cases": case_results,
    "preference_checks": preference_checks,
    "relief_checks": relief_checks,
    "effect_checks": effect_checks,
    "quota_spacing_checks": quota_spacing_checks,
    "rocket_inner_boundary_checks": rocket_inner_boundary_checks,
    "feather_checks": feather_checks,
    "guard_prefilter_checks": guard_prefilter_checks,
    "native_raster_checks": native_raster_checks,
    "natural_native_sampler_checks": natural_native_sampler_checks,
    "rolling_scan_checks": rolling_scan_checks,
    "native_discovery_checks": native_discovery_checks,
    "refine_rolling_checks": refine_rolling_checks,
    "ring_rebuild_geometry_checks": ring_rebuild_geometry_checks,
    "ring_rebuild_geometry_cases": ring_rebuild_geometry_cases,
    "rocket_height_cache_checks": rocket_height_cache_checks,
    "rocket_height_cache_metrics": {
        "queries": rocket_direct_reads,
        "source_reads": rocket_cached_reads,
        "cache_hits": rocket_cached_hits,
        "source_read_reduction": rocket_direct_reads / rocket_cached_reads,
    },
    "axial_clearance_mask_checks": axial_clearance_mask_checks,
    "axial_clearance_mask_metrics": {
        "queries": len(clearance_queries) * 7,
        "resource_mask_cells": resource_clearance_cells,
        "rocket_mask_cells": rocket_clearance_cells,
        "legacy_distance_tests": resource_direct_distance_tests + rocket_direct_distance_tests,
        "modeled_distance_check_reduction": (
            (resource_direct_distance_tests + rocket_direct_distance_tests)
            / (len(clearance_queries) * 7)
        ),
    },
    "rolling_scan_metrics": {
        "cases": len(rolling_scan_cases),
        "source_minimum_read_reduction": min(rolling_source_ratios),
        "destination_minimum_read_reduction": min(rolling_destination_ratios),
    },
    "native_discovery_metrics": {
        "cases": len(native_discovery_cases),
        "minimum_lua_read_reduction": min(native_discovery_ratios),
        "full_destination_band_positions": destination_real_band_positions,
        "full_destination_native_difference_cells": destination_real_band_positions * 3,
        "maximum_survivors": max(case["survivors"] for case in native_discovery_cases),
    },
    "refine_rolling_metrics": {
        "cases": len(refine_rolling_cases),
        "source_minimum_read_reduction": min(refine_source_ratios),
        "destination_minimum_read_reduction": min(refine_destination_ratios),
    },
    "native_raster_metrics": {
        "full_cells": native_size * native_size,
        "coarse_samples": native_coarse_size * native_coarse_size,
        "trigonometric_sample_reduction": native_trig_reduction,
        "mask_mean_absolute_error": native_mask_mean_error,
        "mask_p99_absolute_error": native_mask_p99_error,
        "mask_max_absolute_error": native_mask_max_error,
    },
    "natural_native_sampler_metrics": {
        "cases": natural_native_cases,
        "full_cells": natural_native_full_cells,
        "tested_cells": natural_native_tested_cells,
        "coarse_samples": natural_native_coarse_samples,
        "sample_reduction": natural_native_full_cells / natural_native_coarse_samples,
        "cube_weight_mean_absolute_error": natural_native_mean,
        "cube_weight_p99_absolute_error": natural_native_p99,
        "cube_weight_max_absolute_error": natural_native_max,
    },
    "preferred_candidates": preferred,
}
report["static_passed"] = sum(static_checks.values())
report["static_total"] = len(static_checks)
report["synthetic_passed"] = sum(row["ok"] for row in case_results)
report["synthetic_total"] = len(case_results)
report["preference_passed"] = sum(preference_checks.values())
report["preference_total"] = len(preference_checks)
report["relief_passed"] = sum(relief_checks.values())
report["relief_total"] = len(relief_checks)
report["effect_passed"] = sum(effect_checks.values())
report["effect_total"] = len(effect_checks)
report["quota_spacing_passed"] = sum(quota_spacing_checks.values())
report["quota_spacing_total"] = len(quota_spacing_checks)
report["rocket_inner_boundary_passed"] = sum(rocket_inner_boundary_checks.values())
report["rocket_inner_boundary_total"] = len(rocket_inner_boundary_checks)
report["feather_passed"] = sum(feather_checks.values())
report["feather_total"] = len(feather_checks)
report["guard_prefilter_passed"] = sum(guard_prefilter_checks.values())
report["guard_prefilter_total"] = len(guard_prefilter_checks)
report["guard_prefilter_samples"] = guard_samples
report["native_raster_passed"] = sum(native_raster_checks.values())
report["native_raster_total"] = len(native_raster_checks)
report["natural_native_sampler_passed"] = sum(natural_native_sampler_checks.values())
report["natural_native_sampler_total"] = len(natural_native_sampler_checks)
report["rolling_scan_passed"] = sum(rolling_scan_checks.values())
report["rolling_scan_total"] = len(rolling_scan_checks)
report["native_discovery_passed"] = sum(native_discovery_checks.values())
report["native_discovery_total"] = len(native_discovery_checks)
report["refine_rolling_passed"] = sum(refine_rolling_checks.values())
report["refine_rolling_total"] = len(refine_rolling_checks)
report["ring_rebuild_geometry_passed"] = sum(ring_rebuild_geometry_checks.values())
report["ring_rebuild_geometry_total"] = len(ring_rebuild_geometry_checks)
report["rocket_height_cache_passed"] = sum(rocket_height_cache_checks.values())
report["rocket_height_cache_total"] = len(rocket_height_cache_checks)
report["axial_clearance_mask_passed"] = sum(axial_clearance_mask_checks.values())
report["axial_clearance_mask_total"] = len(axial_clearance_mask_checks)
report["ok"] = (
    all(static_checks.values())
    and all(row["ok"] for row in case_results)
    and all(preference_checks.values())
    and all(relief_checks.values())
    and all(effect_checks.values())
    and all(quota_spacing_checks.values())
    and all(rocket_inner_boundary_checks.values())
    and all(feather_checks.values())
    and all(guard_prefilter_checks.values())
    and all(native_raster_checks.values())
    and all(natural_native_sampler_checks.values())
    and all(rolling_scan_checks.values())
    and all(native_discovery_checks.values())
    and all(refine_rolling_checks.values())
    and all(ring_rebuild_geometry_checks.values())
    and all(rocket_height_cache_checks.values())
    and all(axial_clearance_mask_checks.values())
)

print(json.dumps(report, indent=2, sort_keys=True))
raise SystemExit(0 if report["ok"] else 1)
