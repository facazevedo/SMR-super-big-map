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
    "native_outer_resource_precondition_is_enabled": (
        "config.OptimizeOuterResourceTerrainNativePrecondition = true" in CONFIG
        and "C.OPTIMIZE_OUTER_RESOURCE_TERRAIN_NATIVE_PRECONDITION" in CONFIG
        and 'cfg_bool("OPTIMIZE_OUTER_RESOURCE_TERRAIN_NATIVE_PRECONDITION", true)'
        in outer_resource_terrain
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
            "local native_sample_step = 4",
            "native_resample(coarse, local_width, local_height, true)",
            "native_mul_div_add(weight_cube, mask, native_weight_scale, 0)",
            "native_mul_div_add(result, inverse_cube, native_weight_scale, 0)",
            "native_mul_div_add(plane_term, weight_cube, native_weight_scale, 0)",
            "native_mul_div_add(target_delta, mask, native_weight_scale, 0)",
        )
    ),
    "native_raster_preconditions_at_risk_components": (
        'if patch.kind ~= "surface" and patch.maximum_core_delta >= precondition_minimum_delta then'
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
    "rocket_live_shape_stays_outside_inner_no_write_rectangle": (
        "local function inner_rectangle_clearance(x, y)" in outer_resource_terrain
        and "if inner_clearance <= rocket_world_radius * hex_size then return nil end"
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
        < GENERATION.index('"surface top-up anomalies"')
        < GENERATION.index('"surface top-up effect deposits"')
        and 'RebuildFinal(\n\t\t\t\t\t\t\t\tmap, "after outer resource terrain preparation")'
        in GENERATION
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
    "version_is_926": "'version', 926" in METADATA,
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

inner_rectangle = (81920.0, 81920.0, 737280.0, 737280.0)
rocket_live_radius = 9350.0
rocket_inner_boundary_checks = {
    "observed_failed_site_is_rejected": not rocket_footprint_clear_of_inner_rectangle(
        77500.0, 601870.0, rocket_live_radius, inner_rectangle
    ),
    "observed_nearest_passing_site_is_retained": rocket_footprint_clear_of_inner_rectangle(
        71000.0, 133364.0, rocket_live_radius, inner_rectangle
    ),
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
# multi-million-cell map run while preserving the exact production equations and 4-cell sampler.
native_core = 30.0
native_transition = 140.0
native_phase = 1.234
native_relief = (0.6, 0.8)
native_step = 4
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
        and native_coarse_size * native_coarse_size == 12769
    ),
    "trigonometric_samples_drop_by_at_least_15x": native_trig_reduction >= 15,
    "coarse_mask_mean_error_below_0_00015": native_mask_mean_error < 0.00015,
    "coarse_mask_p99_error_below_0_0008": native_mask_p99_error < 0.0008,
    "coarse_mask_max_error_below_0_0013": native_mask_max_error < 0.0013,
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

report = {
    "schema": "smr.ralph.mountain_base_enrichment_policy_check",
    "schema_version": 17,
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
    "rolling_scan_checks": rolling_scan_checks,
    "rolling_scan_metrics": {
        "cases": len(rolling_scan_cases),
        "source_minimum_read_reduction": min(rolling_source_ratios),
        "destination_minimum_read_reduction": min(rolling_destination_ratios),
    },
    "native_raster_metrics": {
        "full_cells": native_size * native_size,
        "coarse_samples": native_coarse_size * native_coarse_size,
        "trigonometric_sample_reduction": native_trig_reduction,
        "mask_mean_absolute_error": native_mask_mean_error,
        "mask_p99_absolute_error": native_mask_p99_error,
        "mask_max_absolute_error": native_mask_max_error,
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
report["rolling_scan_passed"] = sum(rolling_scan_checks.values())
report["rolling_scan_total"] = len(rolling_scan_checks)
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
    and all(rolling_scan_checks.values())
)

print(json.dumps(report, indent=2, sort_keys=True))
raise SystemExit(0 if report["ok"] else 1)
