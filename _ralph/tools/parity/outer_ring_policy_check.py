#!/usr/bin/env python3
"""Offline discriminator for the surface top-up outer-ring policy."""

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
    family: str
    surface: bool = True
    in_ring: bool = False
    edge_anomaly: bool = False
    inner_fallback: bool = False
    reachable: bool = True
    flat: bool = True
    buildable_footprint: bool = True
    unobstructed_footprint: bool = True
    anomaly_overlap: bool = False
    expected: bool = True


def policy(candidate: Candidate) -> bool:
    """Minimal executable model of the final hard surface-placement audit."""
    terrain_valid = (
        candidate.reachable
        and candidate.flat
        and candidate.buildable_footprint
        and candidate.unobstructed_footprint
    )
    if not terrain_valid:
        return False
    if not candidate.surface:
        return True
    if candidate.family == "anomaly":
        if candidate.inner_fallback and candidate.in_ring:
            return False
        if candidate.edge_anomaly and not candidate.in_ring:
            return False
        if candidate.anomaly_overlap:
            return False
    return True


CASES = (
    Candidate("resource_ring_valid", "resource", in_ring=True),
    Candidate("effect_ring_valid", "effect", in_ring=True),
    Candidate("resource_inner_valid", "resource"),
    Candidate("effect_inner_valid", "effect"),
    Candidate("edge_anomaly_ring_valid", "anomaly", in_ring=True, edge_anomaly=True),
    Candidate("edge_anomaly_outside_rejected", "anomaly", edge_anomaly=True, expected=False),
    Candidate(
        "fallback_anomaly_ring_rejected",
        "anomaly",
        in_ring=True,
        inner_fallback=True,
        expected=False,
    ),
    Candidate(
        "resource_ring_unbuildable_footprint_rejected",
        "resource",
        in_ring=True,
        buildable_footprint=False,
        expected=False,
    ),
    Candidate(
        "effect_ring_obstructed_footprint_rejected",
        "effect",
        in_ring=True,
        unobstructed_footprint=False,
        expected=False,
    ),
    Candidate(
        "resource_ring_unreachable_rejected",
        "resource",
        in_ring=True,
        reachable=False,
        expected=False,
    ),
    Candidate(
        "underground_resource_unchanged",
        "resource",
        surface=False,
        in_ring=True,
    ),
)


badge = section(
    DEPOSITS,
    "local function BadgeCandidateAllowed",
    "local function FindNearestFreeBadgePosition",
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
audit = section(
    DEPOSITS,
    "function DepositRules.AuditSurfaceTopUpPlacement",
    "function DepositRules.PrepareUndergroundReachability",
)

static_checks = {
    "badge_keeps_edge_anomaly_route": "SuperBigMapEdgeTopUp and not in_ring" in badge,
    "badge_has_no_resource_ring_veto": "SuperBigMapResourceTopUp" not in badge,
    "badge_has_no_effect_ring_veto": "SuperBigMapEffectTopUp" not in badge,
    "resource_selection_has_no_ring_filter": "IsInFinalOuterSectorRing" not in resources,
    "effect_selection_has_no_ring_filter": "IsInFinalOuterSectorRing" not in effects,
    "audit_uses_complete_buildable_footprint": "IsBuildableAt(map, pt, true" in audit,
    "audit_uses_complete_obstruction_footprint": "IsUnobstructedAt(map, pt, true" in audit,
    "audit_reports_resource_ring_occupancy": "resource_inside_ring" in audit,
    "audit_reports_effect_ring_occupancy": "effect_inside_ring" in audit,
    "audit_has_no_non_anomaly_ring_failure": "non_anomaly_inside_ring" not in audit,
    "generation_enforces_new_audit": "AuditSurfaceTopUpPlacement" in GENERATION,
    "config_documents_shared_ring": "top-ups may use valid terrain in this ring" in CONFIG,
    "version_is_820": "'version', 820" in METADATA,
}

case_results = []
for candidate in CASES:
    actual = policy(candidate)
    case_results.append(
        {
            **asdict(candidate),
            "actual": actual,
            "ok": actual == candidate.expected,
        }
    )

report = {
    "schema": "smr.ralph.outer_ring_policy_check",
    "schema_version": 1,
    "static_checks": static_checks,
    "synthetic_cases": case_results,
}
report["static_passed"] = sum(static_checks.values())
report["static_total"] = len(static_checks)
report["synthetic_passed"] = sum(row["ok"] for row in case_results)
report["synthetic_total"] = len(case_results)
report["ok"] = all(static_checks.values()) and all(row["ok"] for row in case_results)

print(json.dumps(report, indent=2, sort_keys=True))
raise SystemExit(0 if report["ok"] else 1)
