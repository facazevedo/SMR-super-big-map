#!/usr/bin/env python3
"""Offline discriminator for enrichment perimeter policy and natural foothill aprons.

The historical filename is retained so existing harness commands keep working.
"""

from __future__ import annotations

import json
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


def dome_effect_topup_allowed(edge_layer: int, underground: bool = False) -> bool:
    """Only added surface dome effects exclude the final three-sector perimeter."""
    return underground or edge_layer > 3


def apron_weight(normalized_radius: float, core_fraction: float = 3 / 8) -> float:
    """Production C2 core-to-original feather."""
    if normalized_radius <= core_fraction:
        return 1.0
    if normalized_radius >= 1.0:
        return 0.0
    t = (normalized_radius - core_fraction) / (1 - core_fraction)
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

static_checks = {
    "legacy_outer_ring_disabled": "config.TopUpAnomalyOuterRingSectors = 0" in CONFIG,
    "compiled_outer_ring_forced_off": "C.TOPUP_ANOMALY_OUTER_RING_SECTORS = 0" in CONFIG,
    "anomaly_path_forces_whole_map": "local ring_sectors = 0" in anomalies,
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
    "dome_effect_exclusion_is_three_sectors": (
        "config.TopUpDomeEffectOuterRingExclusionSectors = 3" in CONFIG
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
    "natural_aprons_enabled": "config.CreateNaturalMountainBaseBuildableAprons = true" in CONFIG,
    "natural_aprons_use_outer_three_sectors": "config.MountainBaseApronOuterRingSectors = 3" in CONFIG,
    "mountain_base_resource_minimum_is_32": (
        "config.MountainBaseOuterRingResourceMinimum = 32" in CONFIG
    ),
    "mountain_base_resource_minimum_is_compiled": (
        "C.MOUNTAIN_BASE_OUTER_RING_RESOURCE_MINIMUM" in CONFIG
    ),
    "natural_aprons_reserve_72_opportunities": (
        "config.MountainBaseApronMaximumCount = 72" in CONFIG
    ),
    "resource_quota_scans_final_grid_generally": (
        "local SAMPLES_AXIS = 32" in resources
        and "local MAX_CANDIDATES_PER_SECTOR = 16" in resources
        and "local MAX_FINAL_BASE_CANDIDATES = 1024" in resources
    ),
    "natural_aprons_reject_obvious_cliffs": "maximum_local_slope > 36" in aprons,
    "already_buildable_foothills_are_unchanged": (
        "requires_edit = maximum_local_slope >= 9" in aprons
        and "if candidate.requires_edit then" in aprons
    ),
    "foothill_selection_is_pseudorandom_without_rng_cost": (
        "pseudorandom_rank" in aprons and "73856093" in aprons
    ),
    "natural_aprons_require_mountain_relief": "higher_samples < 3" in aprons,
    "natural_aprons_keep_gentle_grade": "if gradient_length > 4" in aprons,
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
    "resource_quota_preserves_exact_repulsion": (
        'NewTopUpRepulsionTracker(map, "resources")' in resources
        and "repulsion.CanPlace(candidate, profile)" in resources
    ),
    "resource_quota_places_before_general_resources": (
        resources.index('"mountain-base resource quota"')
        < resources.index("if sequential_placement then")
    ),
    "resource_quota_marks_ordinary_resource_topups": (
        "clone.SuperBigMapMountainBaseResourceTopUp" in resources
    ),
    "resource_quota_is_fail_closed": "mountain-base resource quota failed" in resources,
    "resource_quota_is_audited": (
        "resource_mountain_base_quota_shortfall" in audit
        and "mountain_base_resource_topup_outside_final_ring" in audit
    ),
    "resource_quota_has_no_scenario_special_case": (
        "14N134W" not in resources and "A17" not in resources
    ),
    "version_is_854": "'version', 854" in METADATA,
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
    "surface_layers_one_to_three_are_excluded": all(
        not dome_effect_topup_allowed(layer) for layer in (1, 2, 3)
    ),
    "surface_layer_four_is_allowed": dome_effect_topup_allowed(4),
    "underground_is_unchanged": all(
        dome_effect_topup_allowed(layer, underground=True) for layer in (1, 2, 3, 4)
    ),
}

eps = 1e-4
feather_checks = {
    "core_is_fully_graded": apron_weight(0) == 1 and apron_weight(3 / 8) == 1,
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

report = {
    "schema": "smr.ralph.mountain_base_enrichment_policy_check",
    "schema_version": 5,
    "static_checks": static_checks,
    "synthetic_cases": case_results,
    "preference_checks": preference_checks,
    "relief_checks": relief_checks,
    "effect_checks": effect_checks,
    "feather_checks": feather_checks,
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
report["feather_passed"] = sum(feather_checks.values())
report["feather_total"] = len(feather_checks)
report["ok"] = (
    all(static_checks.values())
    and all(row["ok"] for row in case_results)
    and all(preference_checks.values())
    and all(relief_checks.values())
    and all(effect_checks.values())
    and all(feather_checks.values())
)

print(json.dumps(report, indent=2, sort_keys=True))
raise SystemExit(0 if report["ok"] else 1)
