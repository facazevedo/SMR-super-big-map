#!/usr/bin/env python3
"""Offline discriminator for whole-map, mountain-base surface anomaly top-ups.

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

static_checks = {
    "legacy_outer_ring_disabled": "config.TopUpAnomalyOuterRingSectors = 0" in CONFIG,
    "compiled_outer_ring_forced_off": "C.TOPUP_ANOMALY_OUTER_RING_SECTORS = 0" in CONFIG,
    "anomaly_path_forces_whole_map": "local ring_sectors = 0" in anomalies,
    "surface_uses_sector_balancing": "whole_map_sector_balanced" in anomalies,
    "surface_scores_mountain_bases": "valley_score = ValleyScore(map, pt)" in anomalies,
    "preference_is_per_sector": "base_by_sector[key]" in anomalies,
    "preference_keeps_plain_sectors": "base_by_sector[key] ~= true or" in anomalies,
    "base_quota_is_configured": "TOPUP_ANOMALY_MOUNTAIN_BASE_MINIMUM_PERCENT" in anomalies,
    "base_quota_selector_exists": "surface anomaly mountain-base quota" in anomalies,
    "steepness_never_relaxed": "only relaxes the nearby-higher-terrain preference" in anomalies,
    "topups_clear_edge_marker": "clone.SuperBigMapEdgeTopUp = nil" in anomalies,
    "topups_record_base_marker": "clone.SuperBigMapMountainBaseTopUp" in anomalies,
    "badge_has_no_active_ring_without_config": "ring_sectors > 0" in badge,
    "audit_runs_with_ring_disabled": "if ring_sectors <= 0 then return true end" not in audit,
    "audit_requires_flat_buildable": "flatness >= validation_context.flatness_minimum" in audit,
    "audit_requires_unobstructed": "IsUnobstructedAt(map, pt, true" in audit,
    "generation_enforces_surface_audit": "AuditSurfaceTopUpPlacement" in GENERATION,
    "version_is_851": "'version', 851" in METADATA,
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

report = {
    "schema": "smr.ralph.whole_map_mountain_base_policy_check",
    "schema_version": 2,
    "static_checks": static_checks,
    "synthetic_cases": case_results,
    "preference_checks": preference_checks,
    "preferred_candidates": preferred,
}
report["static_passed"] = sum(static_checks.values())
report["static_total"] = len(static_checks)
report["synthetic_passed"] = sum(row["ok"] for row in case_results)
report["synthetic_total"] = len(case_results)
report["preference_passed"] = sum(preference_checks.values())
report["preference_total"] = len(preference_checks)
report["ok"] = (
    all(static_checks.values())
    and all(row["ok"] for row in case_results)
    and all(preference_checks.values())
)

print(json.dumps(report, indent=2, sort_keys=True))
raise SystemExit(0 if report["ok"] else 1)
