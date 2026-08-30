#!/usr/bin/env python3
"""Fail-closed static contract for the v997 first-load enrichment stream."""
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
DEP = (ROOT / "Code/sbm_deposits.lua").read_text(encoding="utf-8")
GEN = (ROOT / "Code/sbm_map_generation.lua").read_text(encoding="utf-8")
VER = (ROOT / "Code/sbm_version.lua").read_text(encoding="utf-8")
META = (ROOT / "metadata.lua").read_text(encoding="utf-8")

checks = {
    "metadata_v997": "'version', 997" in META,
    "generator_patch_303": "SuperBigMap.GENERATOR_PATCH_VERSION = 303" in VER,
    "absolute_budget_lt_240s": "duration_ms = 180000" in GEN,
    "phase_budget_60s": "phase_duration_ms = 60000" in GEN and "phase_duration > 60000" in DEP,
    "candidate_cap_256": "maximum_candidates = 256" in GEN and "maximum_candidates > 256" in DEP,
    "validation_cap_2048": "maximum_validations = 2048" in GEN,
    "expensive_cap_64_per_deficit": (
        "maximum_expensive_validations_per_deficit = 64" in GEN
        and "expensive_validation_by_deficit[deficit]" in DEP
    ),
    "progress_batch_16": "progress_batch = 16" in GEN and '"candidate-batch"' in DEP,
    "progress_has_counters": all(token in DEP for token in (
        "last_candidate_x", "last_candidate_y", "rejection_histogram",
        "expensive_calls", "commits = budget.commits",
    )),
    "largest_remainder_targets": (
        "BoundDeferredUndergroundDeficits" in DEP
        and "local scaled = bounded_total * deficit" in DEP
        and "remainder = scaled % raw_total" in DEP
        and "a.remainder > b.remainder" in DEP
    ),
    "bounded_family_additions": all(token in DEP for token in (
        "target_by_type, 64", "target_by_kind, 32", "target_by_type, 16",
    )),
    "cheap_obstruction_snapshot": (
        "cheap_center_snapshot" in DEP
        and "type(obstructions) ~= \"table\"" in DEP
        and "force_exact_obstruction" in DEP
    ),
    "shortlist_exact_commit": (
        'CheckUndergroundEnrichmentBudget(map, "expensive", deficit)' in DEP
        and "IsReachableFromUndergroundEntrance(map, pt, q, r) == true" in DEP
        and "RevalidateBoundedUndergroundCandidateAtCommit" in DEP
    ),
    "commit_spatial_index": "repulsion.Commit(c, profile, clone)" in DEP,
    "final_audits_retained": all(token in GEN for token in (
        "RelocateUnreachableUndergroundEnrichments", "AuditTopUpVanillaRepulsion",
        "final density/repulsion audit failed", "post-rebuild density/repulsion revalidation failed",
    )),
    "private_rng": "budget.rng_state = (budget.rng_state * 48271) % 2147483647" in DEP,
}

commit_start = DEP.index("local function RevalidateBoundedUndergroundCandidateAtCommit")
commit_end = DEP.index("local function PublishUndergroundTopUpCandidate", commit_start)
commit = DEP[commit_start:commit_end]
checks["expensive_cap_consumed_before_native_commit_validation"] = (
    commit.index('CheckUndergroundEnrichmentBudget(map, "expensive", deficit)')
    < commit.index("CanReceiveDeposit(map, pt, context, true, true)")
    < commit.index("IsReachableFromUndergroundEntrance(map, pt, q, r) == true")
)

sample_start = DEP.index("local function SampleUndergroundTopUpPosition")
sample_end = DEP.index("local function RevalidateBoundedUndergroundCandidateAtCommit", sample_start)
sample = DEP[sample_start:sample_end]
direct = sample.index("active_underground_enrichment_budget.map == map")
full_scan = sample.index("BuildUndergroundTopUpSectorCache(map)")
checks["one_coordinate_before_any_region_scan"] = direct < full_scan
checks["bounded_path_no_region_helper"] = (
    "return x, y, nil, nil" in sample[direct:full_scan]
    and "BuildTopUpEdgeContext" not in sample[direct:full_scan]
    and "MapForEach" not in sample[direct:full_scan]
)
checks["no_shared_rng_in_bounded_core"] = "AsyncRand" not in DEP[DEP.index("local function RandInt"):sample_end]

failed = [name for name, ok in checks.items() if not ok]
if failed:
    raise SystemExit("v997 bounded enrichment static failure: " + ",".join(failed))
for name in sorted(checks):
    print(f"{name}=ok")
print("v997 bounded enrichment static checker: ok")
