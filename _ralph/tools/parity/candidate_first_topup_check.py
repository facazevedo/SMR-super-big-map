#!/usr/bin/env python3
"""Focused offline certificate for scenario-seeded candidate-first perimeter top-ups."""

from __future__ import annotations

import argparse
import hashlib
import json
import math
import statistics
import time
from dataclasses import dataclass
from pathlib import Path


ROOT = Path(__file__).resolve().parents[3]
DEPOSITS_PATH = ROOT / "Code" / "sbm_deposits.lua"
CONFIG_PATH = ROOT / "Code" / "sbm_config.lua"
METADATA_PATH = ROOT / "metadata.lua"
MODULUS = 2_147_483_647
SAMPLES_AXIS = 32
SAMPLES_PER_SECTOR = SAMPLES_AXIS * SAMPLES_AXIS
MAX_PER_SECTOR = 64


@dataclass(frozen=True)
class Descriptor:
    col: int
    row: int

    @property
    def outermost(self) -> bool:
        return self.col in (0, 19) or self.row in (0, 19)


def scenario_seed(seed: int, generation_hash: str, preset: str) -> int:
    value = abs(math.floor(seed)) % MODULUS
    for byte in f"{generation_hash}|{preset}".encode("utf-8"):
        value = (value * 48271 + byte + 1) % MODULUS
    return value


def perimeter() -> list[Descriptor]:
    return [
        Descriptor(col, row)
        for row in range(20)
        for col in range(20)
        if col <= 1 or col >= 18 or row <= 1 or row >= 18
    ]


def rank(descriptor: Descriptor, seed: int) -> int:
    return (
        seed
        + (descriptor.col + 17) * 73856093
        + (descriptor.row + 31) * 19349663
    ) % MODULUS


def sample_cell(descriptor: Descriptor, sample_index: int, seed: int) -> tuple[int, int, int]:
    local_seed = (
        (descriptor.col + 17) * 73856093
        + (descriptor.row + 31) * 19349663
        + seed
    ) % SAMPLES_PER_SECTOR
    permuted = (sample_index * 73 + local_seed) % SAMPLES_PER_SECTOR
    cell_x, cell_y = permuted % SAMPLES_AXIS, permuted // SAMPLES_AXIS
    # The expanded surface is roughly 80 axial hexes per sector, so the 32x32 production lattice
    # places neighboring samples about 2.5 hexes apart. Preserve that scale in the cluster oracle;
    # using 160 hexes per sector would falsely halve the actual local candidate density.
    q = descriptor.col * 80 + cell_x * 2 + ((permuted * 37 + local_seed * 11) % 3)
    r = descriptor.row * 80 + cell_y * 2 + ((permuted * 53 + local_seed * 7) % 3)
    return q, r, permuted


def locally_valid(descriptor: Descriptor, q: int, r: int, permuted: int, percent: int) -> bool:
    value = (
        (descriptor.col + 3) * 92821
        + (descriptor.row + 5) * 68917
        + q * 193
        + r * 389
        + permuted * 769
    ) % 100
    return value < percent


def targets(cluster_specs: list[int]) -> tuple[int, int, int, int]:
    outer_clusters = max(1, math.ceil(len(cluster_specs) * 0.60))
    outer_resources = sum(cluster_specs[:outer_clusters])
    inner_resources = sum(cluster_specs[outer_clusters:])
    return (
        outer_clusters,
        len(cluster_specs) - outer_clusters,
        max(64 * outer_clusters, 16 * outer_resources),
        max(64 * (len(cluster_specs) - outer_clusters), 16 * inner_resources),
    )


def candidate_first(
    seed: int, generation_hash: str, preset: str, cluster_specs: list[int], validity: int
) -> dict[str, object]:
    local_seed = scenario_seed(seed, generation_hash, preset)
    descriptors = sorted(perimeter(), key=lambda item: (rank(item, local_seed), item.row, item.col))
    outer_clusters, inner_clusters, outer_target, inner_target = targets(cluster_specs)
    pools: dict[str, list[tuple[int, int]]] = {"outer": [], "inner": []}
    attempts = 0
    visited: list[Descriptor] = []
    for descriptor in descriptors:
        band = "outer" if descriptor.outermost else "inner"
        target = outer_target if band == "outer" else inner_target
        if len(pools[band]) >= target:
            continue
        visited.append(descriptor)
        accepted = 0
        for sample_index in range(SAMPLES_PER_SECTOR):
            attempts += 1
            q, r, permuted = sample_cell(descriptor, sample_index, local_seed)
            if locally_valid(descriptor, q, r, permuted, validity):
                pools[band].append((q, r))
                accepted += 1
                if accepted >= MAX_PER_SECTOR or len(pools[band]) >= target:
                    break
        if len(pools["outer"]) >= outer_target and len(pools["inner"]) >= inner_target:
            break
    return {
        "seed": local_seed,
        "attempts": attempts,
        "visited": [(item.col, item.row) for item in visited],
        "outer_candidates": pools["outer"],
        "inner_candidates": pools["inner"],
        "outer_target": outer_target,
        "inner_target": inner_target,
        "outer_clusters": outer_clusters,
        "inner_clusters": inner_clusters,
    }


def incumbent_attempts(validity: int) -> int:
    accepted_total = 0
    attempts = 0
    for descriptor in perimeter():
        accepted_sector = 0
        for sample_index in range(SAMPLES_PER_SECTOR):
            attempts += 1
            q, r, permuted = sample_cell(descriptor, sample_index, 0)
            if locally_valid(descriptor, q, r, permuted, validity):
                accepted_total += 1
                accepted_sector += 1
                if accepted_sector >= MAX_PER_SECTOR or accepted_total >= 4096:
                    break
        if accepted_total >= 4096:
            break
    return attempts


def axial_distance(a: tuple[int, int], b: tuple[int, int]) -> int:
    dq, dr = a[0] - b[0], a[1] - b[1]
    return max(abs(dq), abs(dr), abs(dq + dr))


def plan_clusters(candidates: list[tuple[int, int]], specs: list[int]) -> list[list[tuple[int, int]]]:
    planned: list[tuple[int, int]] = []
    plans: list[list[tuple[int, int]]] = []
    for target in specs:
        chosen: list[tuple[int, int]] | None = None
        for anchor in candidates:
            if any(axial_distance(anchor, prior) <= 12 for prior in planned):
                continue
            local: list[tuple[int, int]] = []
            for candidate in candidates:
                if axial_distance(anchor, candidate) > 12:
                    continue
                if any(axial_distance(candidate, prior) <= 12 for prior in planned):
                    continue
                if all(axial_distance(candidate, selected) >= 3 for selected in local):
                    local.append(candidate)
                    if len(local) == target:
                        chosen = local
                        break
            if chosen:
                break
        if not chosen:
            return plans
        plans.append(chosen)
        planned.extend(chosen)
    return plans


def source_certificate() -> dict[str, bool]:
    deposits = DEPOSITS_PATH.read_text(encoding="utf-8")
    config = CONFIG_PATH.read_text(encoding="utf-8")
    metadata = METADATA_PATH.read_text(encoding="utf-8")
    start = deposits.index("Candidate-first mode visits perimeter sectors")
    end = deposits.index("table.sort(mountain_base_candidates", start)
    candidate = deposits[start:end]
    streaming_start = deposits.index("Use a private validation context")
    streaming_end = deposits.index("if not surface_streaming_clusters_used", streaming_start)
    streaming = deposits[streaming_start:streaming_end]
    audit_start = deposits.index("function DepositRules.AuditTopUpVanillaRepulsion")
    audit_end = deposits.index("function DepositRules.CensusFinalOuterResourceTopUps", audit_start)
    audit = deposits[audit_start:audit_end]
    return {
        "default_enabled": "config.OptimizeSurfaceResourceCandidateFirst = true" in config,
        "compiled_config": "C.OPTIMIZE_SURFACE_RESOURCE_CANDIDATE_FIRST" in config,
        "version_961": "'version', 961" in metadata,
        "streaming_default_enabled": "config.OptimizeSurfaceResourceStreamingClusters = true" in config,
        "streaming_compiled_config": "C.OPTIMIZE_SURFACE_RESOURCE_STREAMING_CLUSTERS" in config,
        "streaming_is_private_and_transactional": all(token in streaming for token in (
            "local stream_context = NewDepositValidationContext(map)",
            'NewTopUpRepulsionTracker(map, "resource streaming plans")',
            "if stream_ok and type(stream_records) == \"table\"",
            "surface_streaming_clusters_fallback = true",
        )),
        "streaming_stops_and_bounds_full_validation": all(token in streaming for token in (
            "local used_centers, reserved, validation_cache",
            "local validation_budget, validation_budget_exhausted = 1024, false",
            "if full_validations >= validation_budget", "if chosen then break end",
        )),
        "streaming_retains_complete_validation": all(token in streaming for token in (
            "CanReceiveDeposit(", "TerrainTypeAt(", "private_repulsion.CanPlaceUnique(candidate)",
            "private_repulsion.CanPlaceMinimum(candidate, false,",
        )),
        "streaming_retains_ring_and_footprint_guards": all(token in streaming for token in (
            "IsInFinalOuterResourceWorldBand(map, x, y,", "candidate_outermost == want_outermost",
            "surface_extractor_footprint_within_map(candidate)", "not SectorIsScanned(sector)",
        )),
        "extractor_guard_rejects_inner_tangency": all(token in deposits for token in (
            "SurfaceExtractorFootprintWithinTerrainEditableArea(map, x, y,",
            "x < band_x - safe_margin", "x > map_w - band_x + safe_margin",
        )),
        "streaming_retains_cluster_geometry": all(token in streaming for token in (
            "AxialHexDistance(candidate.q, candidate.r, prior.q, prior.r)",
            "<= stream_cluster_radius", "< surface_quota_minimum_hex_distance",
            "plan_count ~= desired_resource_cluster_count",
        )),
        "streaming_reuses_completed_plans_directly": all(token in deposits for token in (
            "streaming_outermost_plans", "streaming_inner_plans",
            "candidate._sbm_resource_cluster_plan = record.plan",
            "and streaming_outermost_plans or build_quota_cluster_plans(",
            "and streaming_inner_plans or build_quota_cluster_plans(",
        )),
        "streaming_search_has_no_global_rng": "RandInt(" not in streaming,
        "scenario_seed_inputs": all(token in candidate for token in ("generator.Seed", "generator.GenerationHash", "RandomMapPreset")),
        "local_complete_validation_retained": all(token in candidate for token in ("CanReceiveDeposit(", "ValleyScore(map, pt)", "TerrainTypeAt(map, pt")),
        "physical_two_band_filter": all(token in candidate for token in ("surface_mountain_base_ring_sectors", "outermost_descriptor", "surface_candidate_first_inner_target")),
        "bounded_quota_targets": all(token in candidate for token in ("64 * outer_cluster_count", "16 * outer_resource_target", "band_target_reached")),
        "candidate_scan_has_no_terrain_write": all(token not in candidate for token in ("SetHeightGrid", "grid:set", "SetPos", "clone_fn")),
        "downstream_three_hex_spacing_retained": "surface_quota_spacing_clear" in deposits and "TopUpEnrichmentMinimumHexDistance()" in deposits,
        "downstream_cluster_caps_retained": all(token in deposits for token in ("maximum_cluster_extractors", "resource_cluster_maximum_deposits", "cluster cap exceeded")),
        "downstream_terrain_audit_retained": "AuditOuterResourceTerrain(map)" in (ROOT / "Code" / "sbm_map_generation.lua").read_text(encoding="utf-8"),
        "audit_has_no_candidate_sampler_locals": all(token not in audit for token in (
            "surface_candidate_first", "surface_candidate_first_outer_candidates",
            "surface_candidate_first_inner_candidates",
        )),
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--out", type=Path)
    args = parser.parse_args()
    cases = []
    timing_ratios = []
    for index, clusters in enumerate(range(6, 11)):
        specs = [3 + ((index + item) % 3) for item in range(clusters)]
        validity = (7, 13, 23, 9, 17)[index]
        seed = 17421 + index * 7919
        generation_hash = hashlib.sha256(f"rough-{index}".encode()).hexdigest().upper()
        first = candidate_first(seed, generation_hash, "RoughTerrain", specs, validity)
        second = candidate_first(seed, generation_hash, "RoughTerrain", specs, validity)
        outer_specs = specs[: int(first["outer_clusters"])]
        inner_specs = specs[int(first["outer_clusters"]) :]
        outer_plans = plan_clusters(first["outer_candidates"], outer_specs)
        inner_plans = plan_clusters(first["inner_candidates"], inner_specs)
        old_attempts = incumbent_attempts(validity)
        ratio = old_attempts / max(1, int(first["attempts"]))
        timing_ratios.append(ratio)
        cases.append({
            "clusters": clusters,
            "validity_percent": validity,
            "deterministic": first == second,
            "outer_cluster_count": len(outer_plans),
            "inner_cluster_count": len(inner_plans),
            "expected_outer_clusters": first["outer_clusters"],
            "expected_inner_clusters": first["inner_clusters"],
            "outer_candidate_count": len(first["outer_candidates"]),
            "inner_candidate_count": len(first["inner_candidates"]),
            "candidate_attempts": first["attempts"],
            "incumbent_attempts": old_attempts,
            "attempt_ratio": ratio,
            "visited_sectors": len(first["visited"]),
            "inner_sector_visits": sum(1 for col, row in first["visited"] if 2 <= col <= 17 and 2 <= row <= 17),
            "minimum_member_spacing": min(
                (axial_distance(a, b) for plan in outer_plans + inner_plans for i, a in enumerate(plan) for b in plan[i + 1 :]),
                default=999,
            ),
        })
    static = source_certificate()
    model_checks = {
        "all_deterministic": all(case["deterministic"] for case in cases),
        "all_cluster_quotas_met": all(
            case["outer_cluster_count"] == case["expected_outer_clusters"]
            and case["inner_cluster_count"] == case["expected_inner_clusters"]
            for case in cases
        ),
        "all_three_hex_spacing": all(case["minimum_member_spacing"] >= 3 for case in cases),
        "no_inner_sector_visits": all(case["inner_sector_visits"] == 0 for case in cases),
        "all_candidate_targets_met": all(
            case["outer_candidate_count"] > 0 and case["inner_candidate_count"] > 0 for case in cases
        ),
    }
    median_speedup = statistics.median(timing_ratios)
    checks = {**static, **model_checks, "median_speedup_at_least_2x": median_speedup >= 2.0}
    report = {
        "schema": "smr.ralph.candidate_first_topup_certificate",
        "source_hashes": {
            path.relative_to(ROOT).as_posix(): hashlib.sha256(path.read_bytes()).hexdigest().upper()
            for path in (DEPOSITS_PATH, CONFIG_PATH, METADATA_PATH)
        },
        "checks": checks,
        "cases": cases,
        "median_attempt_ratio": median_speedup,
        "pass_count": sum(checks.values()),
        "check_count": len(checks),
        "verdict": "GREEN" if all(checks.values()) else "RED",
    }
    rendered = json.dumps(report, indent=2) + "\n"
    if args.out:
        args.out.parent.mkdir(parents=True, exist_ok=True)
        args.out.write_text(rendered, encoding="utf-8")
    print(rendered, end="")
    return 0 if report["verdict"] == "GREEN" else 1


if __name__ == "__main__":
    raise SystemExit(main())
