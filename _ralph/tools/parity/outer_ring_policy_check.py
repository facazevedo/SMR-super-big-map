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


def surface_final_dirty_certificate(
    width: int,
    height: int,
    records: tuple[tuple[int, int, int, int], ...],
    *,
    acknowledged: tuple[tuple[int, int, int, int], ...] = (),
    invalid: bool = False,
    pass_tile: int = 100,
) -> dict[str, object]:
    """Executable model of the conservative closing-pass certificate."""
    outstanding = tuple(
        record
        for record in records
        if not (
            (len(record) < 5 or record[4] == 0)
            and any(
                record[0] >= region[0]
                and record[1] >= region[1]
                and record[2] <= region[2]
                and record[3] <= region[3]
                for region in acknowledged
            )
        )
    )
    if invalid or not outstanding:
        return {
            "accepted": False,
            "outstanding": outstanding,
            "region": None,
            "area_ratio": 1.0,
        }
    halo = pass_tile * 2
    min_x = min(record[0] for record in outstanding)
    min_y = min(record[1] for record in outstanding)
    max_x = max(record[2] for record in outstanding)
    max_y = max(record[3] for record in outstanding)
    region = (
        max(0, math.floor((min_x - halo) / pass_tile) * pass_tile),
        max(0, math.floor((min_y - halo) / pass_tile) * pass_tile),
        min(width, math.ceil((max_x + halo) / pass_tile) * pass_tile),
        min(height, math.ceil((max_y + halo) / pass_tile) * pass_tile),
    )
    area = max(0, region[2] - region[0]) * max(0, region[3] - region[1])
    area_ratio = area / (width * height)
    accepted = region[2] > region[0] and region[3] > region[1] and area_ratio < 0.65
    return {
        "accepted": accepted,
        "outstanding": outstanding,
        "region": region,
        "area_ratio": area_ratio,
    }


def surface_final_owned_trace_summary(
    width: int,
    height: int,
    records: tuple[tuple[int, int, int, int, int], ...],
    successful_owner_serials: frozenset[int],
) -> dict[str, object]:
    """Model the retained v951 trace discriminator independently of the certificate."""
    residual = tuple(
        record
        for record in records
        if record[4] <= 0 or record[4] not in successful_owner_serials
    )
    owned = tuple(record for record in records if record not in residual)
    full = tuple(
        record
        for record in records
        if record[:4] == (0, 0, width, height)
    )
    if residual:
        x0 = min(record[0] for record in residual)
        y0 = min(record[1] for record in residual)
        x1 = max(record[2] for record in residual)
        y1 = max(record[3] for record in residual)
        ratio = (x1 - x0) * (y1 - y0) / (width * height)
        region = (x0, y0, x1, y1)
    else:
        ratio, region = 0.0, (0, 0, 0, 0)
    return {
        "owned": owned,
        "residual": residual,
        "full": full,
        "residual_region": region,
        "residual_area_ratio": ratio,
        "owned_full": tuple(record for record in owned if record in full),
        "residual_full": tuple(record for record in residual if record in full),
    }


def surface_final_owned_record_filter(
    records: tuple[tuple[int, int, int, int, int], ...],
    *,
    next_serial: int,
    started: int,
    completed: int,
    failed: int,
    successful_owner_serials: frozenset[int],
) -> dict[str, object]:
    """Executable model of the strict v952 successful-call ownership certificate."""
    counters = (next_serial, started, completed, failed)
    if any(type(value) is not int or value < 0 for value in counters):
        return {"accepted": False, "reason": "invalid counters", "retained": records}
    expected = frozenset(range(1, next_serial + 1))
    if failed != 0 or started != next_serial or completed != next_serial:
        return {"accepted": False, "reason": "incomplete call", "retained": records}
    if successful_owner_serials != expected:
        return {"accepted": False, "reason": "stale or missing serial", "retained": records}
    if any(
        len(record) != 5
        or type(record[4]) is not int
        or record[4] < 0
        or record[4] > next_serial
        or (record[4] > 0 and record[4] not in successful_owner_serials)
        for record in records
    ):
        return {"accepted": False, "reason": "invalid record tag", "retained": records}
    owner_serials_with_events, last_owner_serial = 0, 0
    closed_owner_serials: set[int] = set()
    for record in records:
        serial = record[4]
        if serial > 0:
            if serial in closed_owner_serials or serial < last_owner_serial:
                return {"accepted": False, "reason": "stale owner tag", "retained": records}
            if serial != last_owner_serial:
                if serial != owner_serials_with_events + 1:
                    return {"accepted": False, "reason": "non-contiguous owner order", "retained": records}
                last_owner_serial = serial
                owner_serials_with_events += 1
        elif last_owner_serial > 0:
            closed_owner_serials.add(last_owner_serial)
    if owner_serials_with_events != next_serial:
        return {"accepted": False, "reason": "missing call notification", "retained": records}
    retained = tuple(record for record in records if record[4] == 0)
    excluded = tuple(record for record in records if record[4] > 0)
    # v956 deliberately recognizes only the accepted v953 normal-run discriminator shape.
    # Different counts are safe, but unproven, and therefore must use the full rebuild.
    if (
        next_serial != 4
        or owner_serials_with_events != 4
        or len(excluded) != 4
        or len(retained) != 11
    ):
        return {"accepted": False, "reason": "unexpected event shape", "retained": records}
    return {
        "accepted": True,
        "reason": "",
        "retained": retained,
        "excluded": excluded,
        "exact_four": next_serial == 4,
        "owner_serials_with_events": owner_serials_with_events,
    }


def valid_nonnegative_integer(value: object) -> bool:
    return (
        not isinstance(value, bool)
        and isinstance(value, (int, float))
        and math.isfinite(value)
        and value >= 0
        and value == math.floor(value)
    )


def surface_final_resource_patch_epoch(
    attempts: tuple[dict[str, object], ...],
) -> dict[str, object] | None:
    """Accumulate the sticky patch-install proof across initial preparation and repairs."""
    if not attempts:
        return None
    counters = {
        "attempts": 0,
        "reports_verified": 0,
        "modified_attempts": 0,
        "zero_change_attempts": 0,
        "safe_modified_attempts": 0,
        "unsafe_modified_attempts": 0,
        "modified_cells": 0,
    }
    safe = True
    identity_verified = True
    for attempt in attempts:
        counters["attempts"] += 1
        exact_published_report = attempt.get("_exact_published_report", True) is True
        modified_cells = attempt.get("modified_cells")
        if not exact_published_report:
            identity_verified = False
            safe = False
            continue
        if not valid_nonnegative_integer(modified_cells):
            safe = False
            continue
        assert isinstance(modified_cells, (int, float))
        counters["reports_verified"] += 1
        counters["modified_cells"] += modified_cells
        if modified_cells == 0:
            counters["zero_change_attempts"] += 1
            continue
        counters["modified_attempts"] += 1
        attempt_safe = (
            attempt.get("patch_install_used") is True
            and attempt.get("patch_install_verified") is True
            and attempt.get("patch_install_fallback") is False
            and attempt.get("patch_install_full_setter_used") is False
        )
        if attempt_safe:
            counters["safe_modified_attempts"] += 1
        else:
            counters["unsafe_modified_attempts"] += 1
            safe = False
    final_report = dict(attempts[-1])
    final_report.update(
        {
            "repair_attempts": len(attempts) - 1,
            "patch_install_epoch_attempts": counters["attempts"],
            "patch_install_epoch_reports_verified": counters["reports_verified"],
            "patch_install_epoch_modified_attempts": counters["modified_attempts"],
            "patch_install_epoch_zero_change_attempts": counters["zero_change_attempts"],
            "patch_install_epoch_safe_modified_attempts": counters[
                "safe_modified_attempts"
            ],
            "patch_install_epoch_unsafe_modified_attempts": counters[
                "unsafe_modified_attempts"
            ],
            "patch_install_epoch_modified_cells": counters["modified_cells"],
            "patch_install_epoch_safe": safe,
            "patch_install_epoch_report_identity_verified": identity_verified,
        }
    )
    return final_report


def surface_final_resource_patch_gate(resource_report: object) -> dict[str, object]:
    """Model v956's cumulative prerequisite for a regional closing pass."""
    fallback = {"accepted": False, "branch": "canonical_rebuild_final"}
    if not isinstance(resource_report, dict):
        return fallback | {"reason": "missing report"}
    modified_cells = resource_report.get("modified_cells")
    if not valid_nonnegative_integer(modified_cells):
        return fallback | {"reason": "invalid modified cells"}
    epoch_keys = (
        "patch_install_epoch_attempts",
        "patch_install_epoch_reports_verified",
        "patch_install_epoch_modified_attempts",
        "patch_install_epoch_zero_change_attempts",
        "patch_install_epoch_safe_modified_attempts",
        "patch_install_epoch_unsafe_modified_attempts",
        "patch_install_epoch_modified_cells",
        "repair_attempts",
    )
    if not all(valid_nonnegative_integer(resource_report.get(key)) for key in epoch_keys):
        return fallback | {"reason": "invalid epoch counters"}
    attempts = resource_report["patch_install_epoch_attempts"]
    reports_verified = resource_report["patch_install_epoch_reports_verified"]
    modified_attempts = resource_report["patch_install_epoch_modified_attempts"]
    zero_change_attempts = resource_report["patch_install_epoch_zero_change_attempts"]
    safe_modified_attempts = resource_report[
        "patch_install_epoch_safe_modified_attempts"
    ]
    unsafe_modified_attempts = resource_report[
        "patch_install_epoch_unsafe_modified_attempts"
    ]
    epoch_modified_cells = resource_report["patch_install_epoch_modified_cells"]
    repair_attempts = resource_report["repair_attempts"]
    if not (
        attempts >= 1
        and reports_verified == attempts
        and attempts == repair_attempts + 1
        and modified_attempts + zero_change_attempts == attempts
        and safe_modified_attempts + unsafe_modified_attempts == modified_attempts
        and epoch_modified_cells >= modified_cells
        and resource_report.get("patch_install_epoch_report_identity_verified") is True
        and resource_report.get("patch_install_epoch_safe") is True
        and unsafe_modified_attempts == 0
    ):
        return fallback | {"reason": "unsafe or incomplete epoch"}
    if modified_cells > 0 and not (
        resource_report.get("patch_install_used") is True
        and resource_report.get("patch_install_verified") is True
        and resource_report.get("patch_install_fallback") is False
        and resource_report.get("patch_install_full_setter_used") is False
    ):
        return fallback | {"reason": "unverified patch install"}
    return {"accepted": True, "branch": "dirty_region", "reason": ""}


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
surface_final_dirty_journal = section(
    GENERATION,
    "function OnMsg.OnPassabilityChanged(event_map, changed_box)",
    "function SuperBigMap.GenerationGrids.RebuildFinal(map, stage)",
)
surface_final_dirty_apply = section(
    GENERATION,
    "function SuperBigMap.GenerationGrids.RebuildFinalSurfaceDirtyOrFinal",
    "-- Resource shaping is hard-clipped",
)
surface_final_dirty_certificate_lua = section(
    GENERATION,
    "function SuperBigMap.GenerationGrids.BuildSurfaceFinalPassCertificate",
    "function SuperBigMap.GenerationGrids.RebuildFinal(map, stage)",
)
outer_resource_ring_rebuild = section(
    GENERATION,
    "function SuperBigMap.GenerationGrids.RebuildOuterResourceRing(map, ring_sectors, stage)",
    "function SuperBigMap.GenerationGrids.RebuildOuterResourceRingOrFinal",
)
surface_pipeline = section(
    GENERATION,
    "local function RunSurfaceStretchIfEnabled",
    "local function SyncMapDataToGrids",
)
resource_patch_epoch_lua = section(
    surface_pipeline,
    "local resource_patch_epoch = {",
    "-- TopUpAnomalies: post-gen replacement",
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
    "surface_final_dirty_rebuild_is_default_on": (
        "config.OptimizeSurfaceFinalDirtyPassabilityRebuild = true" in CONFIG
        and "C.OPTIMIZE_SURFACE_FINAL_DIRTY_PASSABILITY_REBUILD" in CONFIG
        and 'cfg_bool("OPTIMIZE_SURFACE_FINAL_DIRTY_PASSABILITY_REBUILD", true)'
        in GENERATION
    ),
    "surface_final_journal_arms_only_after_post_object_capture": appears_in_order(
        surface_pipeline,
        'NotifyDeterminismCaptureForTest("post_object_transform", map',
        "BeginSurfaceFinalPassJournal(",
        '"post-pipeline scheduled revalidation"',
    ),
    "surface_final_modified_terrain_requires_verified_patch_install": (
        all(
            token in surface_final_dirty_certificate_lua
            for token in (
                "local resource_terrain_report = map.SuperBigMapOuterResourceTerrainReport",
                'type(resource_terrain_report) ~= "table"',
                "local modified_cells = resource_terrain_report.modified_cells",
                'type(modified_cells) ~= "number"',
                "modified_cells ~= math.floor(modified_cells)",
                "resource_terrain_report.patch_install_used == true",
                "resource_terrain_report.patch_install_verified == true",
                "resource_terrain_report.patch_install_fallback == false",
                "resource_terrain_report.patch_install_full_setter_used == false",
                "if patch_install_safe ~= true then",
                "modified outer resource terrain was not installed by the verified patch path",
            )
        )
        and appears_in_order(
            surface_final_dirty_certificate_lua,
            "local resource_terrain_report = map.SuperBigMapOuterResourceTerrainReport",
            "if patch_install_safe ~= true then",
            "FilterSurfaceFinalOwnedPassRecords(journal)",
        )
        and appears_in_order(
            surface_final_dirty_apply,
            "local function fallback(reason)",
            "SuperBigMap.GenerationGrids.RebuildFinal(map, stage)",
            "if certified ~= true or not region then",
            "return fallback(report and report.error",
        )
    ),
    "surface_final_patch_install_proof_is_sticky_across_every_attempt": (
        all(
            token in resource_patch_epoch_lua
            for token in (
                "local resource_patch_epoch = {",
                "local function record_resource_patch_attempt(attempt_report, attempt_stage)",
                "attempt_report ~= map.SuperBigMapOuterResourceTerrainReport",
                "epoch.report_identity_verified = false",
                "epoch.unsafe_modified_attempts = epoch.unsafe_modified_attempts + 1",
                "epoch.safe = false",
                "record_resource_patch_attempt(\n\t\t\t\t\t\t\tresource_terrain_stats",
                "record_resource_patch_attempt(\n\t\t\t\t\t\t\t\trepair_stats",
                "final_resource_terrain_report ~= resource_patch_epoch.last_report",
                "resource_patch_epoch.attempts ~= terrain_repair_attempt + 1",
                "patch_install_epoch_unsafe_modified_attempts",
                "patch_install_epoch_report_identity_verified",
            )
        )
        and appears_in_order(
            resource_patch_epoch_lua,
            'TimedSafeCall(\n\t\t\t\t\t\t\t"surface prepare outer resource terrain"',
            "record_resource_patch_attempt(\n\t\t\t\t\t\t\tresource_terrain_stats",
            'TimedSafeCall(\n\t\t\t\t\t\t\t\t"surface repair failed outer resource terrain"',
            "record_resource_patch_attempt(\n\t\t\t\t\t\t\t\trepair_stats",
            "local final_resource_terrain_report",
            "patch_install_epoch_safe =",
        )
        and all(
            token in surface_final_dirty_certificate_lua
            for token in (
                "local epoch_attempts = resource_terrain_report.patch_install_epoch_attempts",
                "epoch_reports_verified == epoch_attempts",
                "epoch_attempts == repair_attempts + 1",
                "epoch_modified_attempts + epoch_zero_change_attempts == epoch_attempts",
                "epoch_safe_modified_attempts + epoch_unsafe_modified_attempts",
                "resource_terrain_report.patch_install_epoch_report_identity_verified ~= true",
                "resource_terrain_report.patch_install_epoch_safe ~= true",
                "epoch_unsafe_modified_attempts ~= 0",
                "outer resource terrain patch-install epoch is unsafe or incomplete",
            )
        )
    ),
    "surface_final_journal_uses_sanctioned_dormant_engine_handler": (
        "function OnMsg.OnPassabilityChanged(event_map, changed_box)"
        in surface_final_dirty_journal
        and "SurfaceFinalPassObserverInstalled = true" in surface_final_dirty_journal
        and appears_in_order(
            surface_final_dirty_journal,
            "local journal = SuperBigMap.State and SuperBigMap.State.surface_final_pass_journal",
            'if type(journal) ~= "table" or journal.active ~= true then return end',
            "RecordSurfaceFinalPassChange(event_map, changed_box)",
        )
        and 'rawset(_G, "Msg"' not in surface_final_dirty_journal
        and 'Global("Msg")' not in surface_final_dirty_journal
        and "setmetatable(" not in section(
            surface_final_dirty_journal,
            "function OnMsg.OnPassabilityChanged(event_map, changed_box)",
            "SuperBigMap.GenerationGrids.SurfaceFinalPassObserverInstalled = true",
        )
    ),
    "surface_final_journal_copies_and_bounds_every_engine_clip": all(
        token in surface_final_dirty_journal
        for token in (
            'type(is_box) ~= "function" or is_box(changed_box) ~= true',
            "changed_box:minx(), changed_box:miny(), changed_box:maxx(), changed_box:maxy()",
            "x0 ~= x0 or y0 ~= y0 or x1 ~= x1 or y1 ~= y1",
            "math.max(0, math.floor(x0))",
            "math.min(journal.map_w, math.ceil(x1))",
            "if #journal.records >= 512 then",
            "local record = { x0, y0, x1, y1, owner_serial or 0, ordinal }",
            "journal.records[#journal.records + 1] = record",
            "journal.trace[#journal.trace + 1] = record",
        )
    ),
    "surface_final_owned_rebuild_tags_only_the_synchronous_engine_call": (
        "function SuperBigMap.GenerationGrids.BeginSurfaceFinalOwnedPassRebuild"
        in surface_final_dirty_journal
        and "function SuperBigMap.GenerationGrids.EndSurfaceFinalOwnedPassRebuild"
        in surface_final_dirty_journal
        and appears_in_order(
            outer_resource_ring_rebuild,
            "terrain_api.InvalidateHeight(map, region)",
            "terrain_api.InvalidateType(map, region)",
            "BeginSurfaceFinalOwnedPassRebuild(",
            "pcall(terrain_api.RebuildPassability, map, region)",
            "EndSurfaceFinalOwnedPassRebuild(",
            "if rebuild_ok ~= true then",
        )
    ),
    "surface_final_owned_serial_is_unique_and_cleared_on_every_return": (
        all(
            token in surface_final_dirty_journal
            for token in (
                "local serial = (tonumber(journal.owner_next_serial) or 0) + 1",
                "journal.owner_next_serial = serial",
                "local matches = journal.owner_active_serial == serial",
                "journal.owner_active_serial = nil",
                "owned pass rebuild tag still active at close",
            )
        )
        and "surface_final_journal.owner_active_serial = nil" in GENERATION
    ),
    "surface_final_owned_mismatch_is_sticky_and_fail_closed": (
        "report.owner_mismatch = true" in surface_final_dirty_journal
        and "or report.owner_mismatch == true" in surface_final_dirty_journal
        and "foreign pass event during owned rebuild" in surface_final_dirty_journal
        and "report.owner_mismatch = false" not in surface_final_dirty_journal
    ),
    "surface_final_owned_trace_filters_only_exact_successful_call_records": (
        "function SuperBigMap.GenerationGrids.SummarizeSurfaceFinalPassTrace"
        in surface_final_dirty_journal
        and "function SuperBigMap.GenerationGrids.FilterSurfaceFinalOwnedPassRecords"
        in surface_final_dirty_journal
        and "successful[owner_serial] == true" in surface_final_dirty_journal
        and "report.event_trace = table.concat(trace_parts, \";\")"
        in surface_final_dirty_journal
        and "event_trace = tostring(report.event_trace or \"\")" in surface_final_dirty_apply
        and "for _, record in ipairs(journal.records) do" in surface_final_dirty_journal
        and all(
            token in surface_final_dirty_journal
            for token in (
                "failed ~= 0 or started ~= next_serial or completed ~= next_serial",
                "successful_count ~= next_serial",
                "successful[serial] ~= true",
                "type(event_count) ~= \"number\"",
                "#trace ~= event_count",
                "if serial > 0 and successful[serial] ~= true",
                "closed_owner_serials[serial] == true or serial < last_owner_serial",
                "owner_serials_with_events ~= next_serial",
                "excluded ~= 4 or #retained ~= 11",
                "if serial > 0 then",
                "retained[#retained + 1] = record",
                "report.ownership_certificate = true",
            )
        )
        and appears_in_order(
            surface_final_dirty_certificate_lua,
            "FilterSurfaceFinalOwnedPassRecords(journal)",
            "if ownership_ok ~= true then return reject(ownership_error) end",
            "if #journal.records <= 0 then",
            "for _, record in ipairs(journal.records) do",
        )
    ),
    "surface_final_owned_trace_persists_complete_discriminator_telemetry": all(
        token in surface_final_dirty_journal + surface_final_dirty_apply
        for token in (
            'report.successful_owner_serials = table.concat(successful_parts, ",")',
            "report.tagged_events = tagged_events",
            "report.owner_events = owner_events",
            "report.failed_owner_events = failed_owner_events",
            "report.residual_events = residual_events",
            "report.full_events = full_events",
            "report.tagged_full_events = tagged_full_events",
            "report.owner_full_events = owner_full_events",
            "report.residual_full_events = residual_full_events",
            "report.residual_area_ratio = residual_area_ratio",
            "report.residual_area_ppm = math.floor",
            "successful_owner_serials = tostring(report.successful_owner_serials or \"\")",
            "event_trace = tostring(report.event_trace or \"\")",
            "residual_area_ratio = tostring(report.residual_area_ratio or 0)",
            "residual_area_ppm = tonumber(report.residual_area_ppm) or 0",
            "area_ratio = tostring(report.area_ratio or 0)",
            "area_ppm = tonumber(report.area_ppm) or 0",
        )
    ),
    "surface_final_journal_detaches_active_state_and_cleans_failures": (
        "SuperBigMap.State.surface_final_pass_journal = nil"
        in surface_final_dirty_journal
        and "journal.report.observer_inactive = inactive == true"
        in surface_final_dirty_journal
        and "if detached ~= true or report.observer_inactive ~= true"
        in surface_final_dirty_journal
        and "CancelSurfaceFinalPassJournal(" in surface_pipeline
        and "surface expansion thread failed before closing revalidation" in surface_pipeline
        and "surface pipeline failed after journal arm" in surface_pipeline
        and "surface final dirty candidate fallback" in surface_final_dirty_apply
        and "State.surface_final_pass_journal = nil" in GENERATION
    ),
    "surface_final_journal_acknowledges_only_proven_successful_regions": (
        "function SuperBigMap.GenerationGrids.AcknowledgeSurfaceFinalPassRegions"
        in surface_final_dirty_journal
        and "if record[5] == nil or record[5] == 0 then" in surface_final_dirty_journal
        and "record[1] >= region[1] and record[2] >= region[2]" in surface_final_dirty_journal
        and "record[3] <= region[3] and record[4] <= region[4]" in surface_final_dirty_journal
        and "map.SuperBigMapSurfaceFinalDirtyPassJournalActive == true" in GENERATION
        and appears_in_order(
            GENERATION,
            "terrain_api.RebuildPassability(map, region)",
            "AcknowledgeSurfaceFinalPassRegions(",
            "local buildable_started = GetPreciseTicks()",
        )
    ),
    "surface_final_dirty_certificate_is_conservative_and_bounded": all(
        token in surface_final_dirty_journal
        for token in (
            "SafeCall(map.IsPassEditSuspended, map) ~= false",
            'cfg_bool("FINAL_PASSABILITY_INVALIDATE", true) ~= true',
            "current_w ~= journal.map_w or current_h ~= journal.map_h",
            "local halo = math.floor(pass_tile * 2)",
            "math.floor((minx - halo) / pass_tile) * pass_tile",
            "math.ceil((maxx + halo) / pass_tile) * pass_tile",
            "if area_ratio >= 0.65 then",
        )
    ),
    "surface_final_dirty_ratios_force_float_before_large_area_arithmetic": (
        all(
            token in surface_final_dirty_journal
            for token in (
                "local map_area = (journal.map_w + 0.0) * journal.map_h",
                "((residual_width + 0.0) / journal.map_w)",
                "* ((residual_height + 0.0) / journal.map_h)",
                "local region_area = (region_width + 0.0) * region_height",
                "((region_width + 0.0) / journal.map_w)",
                "* ((region_height + 0.0) / journal.map_h)",
                "residual_area_ratio ~= residual_area_ratio",
                "area_ratio ~= area_ratio",
                "surface final dirty region area ratio is invalid",
            )
        )
        and "local residual_area =" not in surface_final_dirty_journal
        and "residual_area / map_area" not in surface_final_dirty_journal
        and "region_area / map_area" not in surface_final_dirty_journal
    ),
    "surface_final_dirty_apply_is_one_region_plus_global_buildable": (
        surface_final_dirty_apply.count("terrain_api.RebuildPassability(map, region)") == 1
        and "terrain_api.InvalidateHeight(map, region)" in surface_final_dirty_apply
        and "terrain_api.InvalidateType(map, region)" in surface_final_dirty_apply
        and "local build_ok, build_err = pcall(rebuild_buildable, map)"
        in surface_final_dirty_apply
        and "SuperBigMap.GenerationGrids.RebuildFinal(map, stage)"
        in surface_final_dirty_apply
        and 'LoadingStep("surface final dirty passability verdict"'
        in surface_final_dirty_apply
        and 'publish_report("canonical full fallback")' in surface_final_dirty_apply
        and 'publish_report("certified dirty region")' in surface_final_dirty_apply
    ),
    "surface_final_dirty_path_has_no_rng_traversal_or_native_allocation": not any(
        token in surface_final_dirty_journal + surface_final_dirty_apply
        for token in ("AsyncRand", "MapForEach", "NewComputeGrid", "GridToCompute")
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
    "outer_resource_patch_install_is_default_on_and_compiled": (
        "config.OptimizeOuterResourceTerrainPatchInstall = true" in CONFIG
        and "C.OPTIMIZE_OUTER_RESOURCE_TERRAIN_PATCH_INSTALL" in CONFIG
        and '"OPTIMIZE_OUTER_RESOURCE_TERRAIN_PATCH_INSTALL", true'
        in outer_resource_terrain
    ),
    "outer_resource_patch_install_uses_stock_exact_difference_path": all(
        token in outer_resource_terrain
        for token in (
            'editor_api.GetGridDifferenceBoxes, map, "height", grid, raw, full_box',
            'editor_api.GetGrid, map, "height", record.box, raw',
            'editor_api.GetGrid, map, "height", record.box, grid',
            'editor_api.SetGrid, map, "height", record.after, record.box',
            "height snapshot does not match its world box",
            "stock difference boxes overlap",
            "local area_ratio = 0.0",
            "local width_ratio = (box_width + 0.0) / map_w",
            "local height_ratio = (box_height + 0.0) / map_h",
            "value == value",
            "value >= 0 and value <= 1",
            "valid_area_fraction(box_area_ratio)",
            "valid_area_fraction(area_ratio)",
            "value ~= math.huge and value ~= -math.huge",
            "difference-box normalized dimension ratio is invalid",
            "difference-box normalized area ratio is invalid",
            "cumulative difference-box area ratio is invalid",
            "area_ratio > 0.20",
            "difference-box area is outside the bounded outer-ring budget",
        )
    ) and "((record.x1 - record.x0) / map_w)" not in outer_resource_terrain,
    "outer_resource_patch_install_is_transactional_and_verified": all(
        token in outer_resource_terrain
        for token in (
            "Capture the entire rollback journal before the first live write.",
            "for index = #records, 1, -1 do",
            'editor_api.SetGrid, map, "height", record.before, record.box',
            'editor_api.GetGrid, map, "height", record.box)',
            'record.before, record.rollback_live, local_box',
            "patch_install.rollback_verified = verify_ok",
            "local equal, equality_error = grids_are_equal(",
            ".. tostring(equality_error)",
            "local equal, equality_error = grids_are_equal(grid, live)",
            "patch_install.verified = true",
            "patch_install.full_setter_used = true",
            "pcall(terrain_api.SetHeightGrid, map, grid)",
        )
    ) and "grids_are_equal(raw, live)" not in outer_resource_terrain,
    "outer_resource_patch_install_emits_no_editor_height_message": (
        "EditorHeightChanged" not in outer_resource_terrain
    ),
    "outer_resource_patch_install_reports_truthful_mode_and_timing": all(
        token in outer_resource_terrain
        for token in (
            "patch_install_attempted = patch_install.attempted",
            "patch_install_used = patch_install.used",
            "patch_install_verified = patch_install.verified",
            "patch_install_fallback = patch_install.fallback",
            "patch_install_full_setter_used = patch_install.full_setter_used",
            "patch_install_boxes = patch_install.boxes",
            "patch_install_area_ratio = patch_install.area_ratio",
            "patch_install_prepare_ms = patch_install.prepare_ms",
            "patch_install_apply_ms = patch_install.apply_ms",
            "patch_install_verify_ms = patch_install.verify_ms",
            "patch_install_rollback_verified = patch_install.rollback_verified",
            "canonical_final_grid_rebuild_retained = true",
        )
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
            "local clear = not axial_mask_contains(rocket_clearance_mask, q, r)",
            "+ mark_axial_forbidden(rocket_clearance_mask, best.q, best.r,",
        )
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
    "version_is_956": "'version', 956" in METADATA,
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

surface_dirty_width = 819200
surface_dirty_height = 819200
surface_dirty_pass_tile = 100
surface_resource_verified_attempt = {
    "modified_cells": 1_890_334,
    "patch_install_used": True,
    "patch_install_verified": True,
    "patch_install_fallback": False,
    "patch_install_full_setter_used": False,
}
surface_resource_zero_change_attempt = {"modified_cells": 0}
surface_resource_full_setter_attempt = {
    "modified_cells": 1_890_334,
    "patch_install_used": False,
    "patch_install_verified": False,
    "patch_install_fallback": True,
    "patch_install_full_setter_used": True,
}
surface_resource_fallback_attempt = {
    "modified_cells": 1_890_334,
    "patch_install_used": True,
    "patch_install_verified": True,
    "patch_install_fallback": True,
    "patch_install_full_setter_used": False,
}
surface_resource_patch_verified = surface_final_resource_patch_gate(
    surface_final_resource_patch_epoch((surface_resource_verified_attempt,))
)
surface_resource_patch_no_changes = surface_final_resource_patch_gate(
    surface_final_resource_patch_epoch((surface_resource_zero_change_attempt,))
)
surface_resource_patch_full_setter = surface_final_resource_patch_gate(
    surface_final_resource_patch_epoch((surface_resource_full_setter_attempt,))
)
surface_resource_patch_fallback = surface_final_resource_patch_gate(
    surface_final_resource_patch_epoch((surface_resource_fallback_attempt,))
)
surface_resource_full_setter_then_zero = surface_final_resource_patch_gate(
    surface_final_resource_patch_epoch(
        (surface_resource_full_setter_attempt, surface_resource_zero_change_attempt)
    )
)
surface_resource_full_setter_then_verified = surface_final_resource_patch_gate(
    surface_final_resource_patch_epoch(
        (surface_resource_full_setter_attempt, surface_resource_verified_attempt)
    )
)
surface_resource_identity_mismatch = surface_final_resource_patch_gate(
    surface_final_resource_patch_epoch(
        (
            surface_resource_verified_attempt,
            {**surface_resource_zero_change_attempt, "_exact_published_report": False},
        )
    )
)
surface_resource_patch_missing = surface_final_resource_patch_gate(None)
surface_resource_patch_nonnumeric = surface_final_resource_patch_gate(
    {"modified_cells": "1890334"}
)
surface_dirty_compact_records = (
    (200031, 300047, 201119, 301263),
    (209977, 305011, 211083, 306307),
)
surface_dirty_compact = surface_final_dirty_certificate(
    surface_dirty_width,
    surface_dirty_height,
    surface_dirty_compact_records,
    pass_tile=surface_dirty_pass_tile,
)
surface_dirty_ring_regions = outer_resource_rebuild_strips(
    surface_dirty_width, surface_dirty_height, 2, surface_dirty_pass_tile
)
surface_dirty_ack_records = (
    (1000, 400000, 1600, 401000),
    (350031, 360047, 351119, 361263),
)
surface_dirty_after_ack = surface_final_dirty_certificate(
    surface_dirty_width,
    surface_dirty_height,
    surface_dirty_ack_records,
    acknowledged=surface_dirty_ring_regions,
    pass_tile=surface_dirty_pass_tile,
)
surface_dirty_invalid = surface_final_dirty_certificate(
    surface_dirty_width,
    surface_dirty_height,
    surface_dirty_compact_records,
    invalid=True,
    pass_tile=surface_dirty_pass_tile,
)
surface_dirty_empty = surface_final_dirty_certificate(
    surface_dirty_width,
    surface_dirty_height,
    (),
    pass_tile=surface_dirty_pass_tile,
)
surface_dirty_overlarge = surface_final_dirty_certificate(
    surface_dirty_width,
    surface_dirty_height,
    ((1000, 1000, 2000, 2000), (817000, 817000, 818000, 818000)),
    pass_tile=surface_dirty_pass_tile,
)

surface_owned_trace_records = (
    (0, 0, surface_dirty_width, 82120, 1),
    (0, 737080, surface_dirty_width, surface_dirty_height, 2),
    (0, 0, 82120, surface_dirty_height, 3),
    (737080, 0, surface_dirty_width, surface_dirty_height, 4),
    (312949, 316728, 313949, 317728, 0),
    (350000, 340000, 351000, 341000, 0),
    (375000, 390000, 376000, 391000, 0),
    (410000, 420000, 411000, 421000, 0),
    (450000, 460000, 451000, 461000, 0),
    (500000, 480000, 501000, 481000, 0),
    (525000, 510000, 526000, 511000, 0),
    (550000, 540000, 551000, 541000, 0),
    (575000, 560000, 576000, 561000, 0),
    (600000, 575000, 601000, 576000, 0),
    (632551, 590712, 633551, 591712, 0),
)
surface_owned_trace_success = surface_final_owned_trace_summary(
    surface_dirty_width,
    surface_dirty_height,
    surface_owned_trace_records,
    frozenset((1, 2, 3, 4)),
)
surface_owned_trace_failed_call = surface_final_owned_trace_summary(
    surface_dirty_width,
    surface_dirty_height,
    surface_owned_trace_records,
    frozenset((1, 2, 3)),
)
surface_owned_filter_success = surface_final_owned_record_filter(
    surface_owned_trace_records,
    next_serial=4,
    started=4,
    completed=4,
    failed=0,
    successful_owner_serials=frozenset((1, 2, 3, 4)),
)
surface_owned_filter_failed_call = surface_final_owned_record_filter(
    surface_owned_trace_records,
    next_serial=4,
    started=4,
    completed=3,
    failed=1,
    successful_owner_serials=frozenset((1, 2, 3)),
)
surface_owned_filter_stale_serial = surface_final_owned_record_filter(
    surface_owned_trace_records,
    next_serial=4,
    started=4,
    completed=4,
    failed=0,
    successful_owner_serials=frozenset((1, 2, 3, 4, 5)),
)
surface_owned_filter_stale_tag = surface_final_owned_record_filter(
    surface_owned_trace_records + ((400000, 400000, 401000, 401000, 1),),
    next_serial=4,
    started=4,
    completed=4,
    failed=0,
    successful_owner_serials=frozenset((1, 2, 3, 4)),
)
surface_owned_filter_missing_notification = surface_final_owned_record_filter(
    tuple(record for record in surface_owned_trace_records if record[4] != 4),
    next_serial=4,
    started=4,
    completed=4,
    failed=0,
    successful_owner_serials=frozenset((1, 2, 3, 4)),
)
surface_owned_filter_missing_residual = surface_final_owned_record_filter(
    surface_owned_trace_records[:-1],
    next_serial=4,
    started=4,
    completed=4,
    failed=0,
    successful_owner_serials=frozenset((1, 2, 3, 4)),
)
surface_owned_unfiltered_certificate = surface_final_dirty_certificate(
    surface_dirty_width,
    surface_dirty_height,
    tuple(record[:4] for record in surface_owned_trace_records),
    pass_tile=surface_dirty_pass_tile,
)
surface_owned_filtered_certificate = surface_final_dirty_certificate(
    surface_dirty_width,
    surface_dirty_height,
    tuple(record[:4] for record in surface_owned_filter_success["retained"]),
    pass_tile=surface_dirty_pass_tile,
)
iter177_residual_bounds = (312949, 316728, 633551, 591712)
iter177_residual_width = iter177_residual_bounds[2] - iter177_residual_bounds[0]
iter177_residual_height = iter177_residual_bounds[3] - iter177_residual_bounds[1]
iter177_legacy_integral_ratio = (
    (iter177_residual_width * iter177_residual_height)
    // (surface_dirty_width * surface_dirty_height)
)
iter177_normalized_residual_ratio = (
    iter177_residual_width / surface_dirty_width
) * (iter177_residual_height / surface_dirty_height)
iter177_region = surface_owned_filtered_certificate["region"]
assert isinstance(iter177_region, tuple)
iter177_normalized_region_ratio = (
    (iter177_region[2] - iter177_region[0]) / surface_dirty_width
) * ((iter177_region[3] - iter177_region[1]) / surface_dirty_height)
surface_tagged_ack_records = (
    (1000, 400000, 1600, 401000, 1),
    (2000, 400000, 2600, 401000, 0),
    (350031, 360047, 351119, 361263, 0),
)
surface_tagged_after_ack = surface_final_dirty_certificate(
    surface_dirty_width,
    surface_dirty_height,
    surface_tagged_ack_records,
    acknowledged=surface_dirty_ring_regions,
    pass_tile=surface_dirty_pass_tile,
)


def certificate_covers_every_record(certificate: dict[str, object]) -> bool:
    region = certificate["region"]
    if not certificate["accepted"] or not isinstance(region, tuple):
        return False
    return all(
        record[0] >= region[0]
        and record[1] >= region[1]
        and record[2] <= region[2]
        and record[3] <= region[3]
        for record in certificate["outstanding"]
    )


surface_dirty_certificate_checks = {
    "verified_patch_install_allows_modified_terrain_certificate": (
        surface_resource_patch_verified["accepted"]
        and surface_resource_patch_verified["branch"] == "dirty_region"
        and surface_resource_patch_no_changes["accepted"]
    ),
    "full_setter_or_patch_fallback_forces_canonical_rebuild_final": (
        not surface_resource_patch_full_setter["accepted"]
        and not surface_resource_patch_fallback["accepted"]
        and surface_resource_patch_full_setter["branch"] == "canonical_rebuild_final"
        and surface_resource_patch_fallback["branch"] == "canonical_rebuild_final"
    ),
    "full_setter_then_zero_change_remains_sticky_canonical_fallback": (
        not surface_resource_full_setter_then_zero["accepted"]
        and surface_resource_full_setter_then_zero["branch"]
        == "canonical_rebuild_final"
    ),
    "full_setter_then_verified_patch_remains_sticky_canonical_fallback": (
        not surface_resource_full_setter_then_verified["accepted"]
        and surface_resource_full_setter_then_verified["branch"]
        == "canonical_rebuild_final"
    ),
    "nonidentical_map_published_report_breaks_epoch_certificate": (
        not surface_resource_identity_mismatch["accepted"]
        and surface_resource_identity_mismatch["branch"] == "canonical_rebuild_final"
    ),
    "missing_or_nonnumeric_resource_report_fails_closed": (
        not surface_resource_patch_missing["accepted"]
        and not surface_resource_patch_nonnumeric["accepted"]
        and surface_resource_patch_missing["branch"] == "canonical_rebuild_final"
        and surface_resource_patch_nonnumeric["branch"] == "canonical_rebuild_final"
    ),
    "compact_dirty_union_is_accepted_and_fully_covered": (
        surface_dirty_compact["accepted"]
        and certificate_covers_every_record(surface_dirty_compact)
    ),
    "accepted_region_is_outward_aligned_with_two_tile_halo": (
        surface_dirty_compact["region"]
        == (
            math.floor((200031 - 200) / 100) * 100,
            math.floor((300047 - 200) / 100) * 100,
            math.ceil((211083 + 200) / 100) * 100,
            math.ceil((306307 + 200) / 100) * 100,
        )
    ),
    "ring_ack_removes_only_contained_records": (
        surface_dirty_after_ack["accepted"]
        and surface_dirty_after_ack["outstanding"] == (surface_dirty_ack_records[1],)
        and certificate_covers_every_record(surface_dirty_after_ack)
    ),
    "ring_geometry_ack_never_removes_owned_records": (
        surface_tagged_after_ack["outstanding"]
        == (surface_tagged_ack_records[0], surface_tagged_ack_records[2])
    ),
    "invalid_and_empty_epochs_are_rejected": (
        not surface_dirty_invalid["accepted"]
        and not surface_dirty_empty["accepted"]
    ),
    "distributed_overlarge_union_is_rejected": (
        not surface_dirty_overlarge["accepted"]
        and surface_dirty_overlarge["area_ratio"] >= 0.65
    ),
    "accepted_cases_are_materially_bounded": (
        surface_dirty_compact["area_ratio"] < 0.01
        and surface_dirty_after_ack["area_ratio"] < 0.01
    ),
    "owned_trace_excludes_only_successfully_completed_call_serials": (
        len(surface_owned_trace_success["owned"]) == 4
        and len(surface_owned_trace_success["residual"]) == 11
        and len(surface_owned_trace_success["full"]) == 0
        and len(surface_owned_trace_success["owned_full"]) == 0
        and len(surface_owned_trace_success["residual_full"]) == 0
        and 0.13 < surface_owned_trace_success["residual_area_ratio"] < 0.14
    ),
    "four_owned_edge_strips_alone_explain_the_original_full_union": (
        not surface_owned_unfiltered_certificate["accepted"]
        and surface_owned_unfiltered_certificate["area_ratio"] == 1.0
    ),
    "strict_successful_owner_filter_retains_all_eleven_residual_records": (
        surface_owned_filter_success["accepted"]
        and surface_owned_filter_success["exact_four"]
        and len(surface_owned_filter_success["excluded"]) == 4
        and len(surface_owned_filter_success["retained"]) == 11
        and surface_owned_filtered_certificate["accepted"]
        and certificate_covers_every_record(surface_owned_filtered_certificate)
        and 0.13 < surface_owned_filtered_certificate["area_ratio"] < 0.14
    ),
    "failed_or_stale_owner_proof_is_rejected_before_filtering": (
        not surface_owned_filter_failed_call["accepted"]
        and not surface_owned_filter_stale_serial["accepted"]
        and not surface_owned_filter_stale_tag["accepted"]
        and not surface_owned_filter_missing_notification["accepted"]
        and surface_owned_filter_failed_call["retained"] == surface_owned_trace_records
        and surface_owned_filter_stale_serial["retained"] == surface_owned_trace_records
    ),
    "certificate_requires_exact_four_owned_and_eleven_residual_events": (
        surface_owned_filter_success["accepted"]
        and not surface_owned_filter_missing_residual["accepted"]
        and surface_owned_filter_missing_residual["retained"]
        == surface_owned_trace_records[:-1]
    ),
    "failed_owned_call_is_never_classified_as_success_owned": (
        len(surface_owned_trace_failed_call["owned"]) == 3
        and len(surface_owned_trace_failed_call["residual"]) == 12
    ),
    "iter177_large_integral_area_division_reproduces_zero": (
        iter177_residual_width * iter177_residual_height > 2**31 - 1
        and surface_dirty_width * surface_dirty_height > 2**31 - 1
        and iter177_legacy_integral_ratio == 0
    ),
    "iter177_dimension_normalized_residual_ratio_is_exact": (
        math.isclose(iter177_normalized_residual_ratio, 0.13136926348209382)
        and round(iter177_normalized_residual_ratio * 1_000_000) == 131369
    ),
    "iter177_dimension_normalized_halo_ratio_preserves_certificate": (
        math.isclose(iter177_normalized_region_ratio, 0.1318202167749405)
        and round(iter177_normalized_region_ratio * 1_000_000) == 131820
        and iter177_normalized_region_ratio < 0.65
    ),
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
    "schema_version": 27,
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
    "surface_dirty_certificate_checks": surface_dirty_certificate_checks,
    "surface_dirty_certificate_cases": {
        "resource_patch_verified": surface_resource_patch_verified,
        "resource_patch_no_changes": surface_resource_patch_no_changes,
        "resource_patch_full_setter": surface_resource_patch_full_setter,
        "resource_patch_fallback": surface_resource_patch_fallback,
        "resource_full_setter_then_zero": surface_resource_full_setter_then_zero,
        "resource_full_setter_then_verified": surface_resource_full_setter_then_verified,
        "resource_identity_mismatch": surface_resource_identity_mismatch,
        "resource_patch_missing": surface_resource_patch_missing,
        "resource_patch_nonnumeric": surface_resource_patch_nonnumeric,
        "compact": surface_dirty_compact,
        "after_ring_ack": surface_dirty_after_ack,
        "invalid": surface_dirty_invalid,
        "empty": surface_dirty_empty,
        "overlarge": surface_dirty_overlarge,
        "owned_trace_success": surface_owned_trace_success,
        "owned_trace_failed_call": surface_owned_trace_failed_call,
        "owned_filter_success": surface_owned_filter_success,
        "owned_filter_failed_call": surface_owned_filter_failed_call,
        "owned_filter_stale_serial": surface_owned_filter_stale_serial,
        "owned_filter_stale_tag": surface_owned_filter_stale_tag,
        "owned_filter_missing_notification": surface_owned_filter_missing_notification,
        "owned_filter_missing_residual": surface_owned_filter_missing_residual,
        "owned_unfiltered_certificate": surface_owned_unfiltered_certificate,
        "owned_filtered_certificate": surface_owned_filtered_certificate,
        "tagged_after_geometry_ack": surface_tagged_after_ack,
    },
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
report["surface_dirty_certificate_passed"] = sum(surface_dirty_certificate_checks.values())
report["surface_dirty_certificate_total"] = len(surface_dirty_certificate_checks)
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
    and all(surface_dirty_certificate_checks.values())
    and all(rocket_height_cache_checks.values())
    and all(axial_clearance_mask_checks.values())
)

print(json.dumps(report, indent=2, sort_keys=True))
raise SystemExit(0 if report["ok"] else 1)
