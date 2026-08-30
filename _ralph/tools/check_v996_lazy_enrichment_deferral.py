#!/usr/bin/env python3
from pathlib import Path
import re
import sys

ROOT = Path(__file__).resolve().parents[2]
GEN = (ROOT / "Code" / "sbm_map_generation.lua").read_text(encoding="utf-8")
DEP = (ROOT / "Code" / "sbm_deposits.lua").read_text(encoding="utf-8")
VER = (ROOT / "Code" / "sbm_version.lua").read_text(encoding="utf-8")
META = (ROOT / "metadata.lua").read_text(encoding="utf-8")
ORACLE = ROOT / "_ralph" / "tools" / "v996_lazy_enrichment_state_oracle.lua"
MICROBENCH = ROOT / "_ralph" / "tools" / "v996_bounded_topup_microbenchmark.py"

checks = {
    "metadata_v996": "'version', 996" in META,
    "generator_patch_302": "SuperBigMap.GENERATOR_PATCH_VERSION = 302" in VER,
    "descriptor_schema_bumped": "SCHEMA = 2" in GEN,
    "primitive_pending_plan": all(token in GEN for token in (
        'enrichment_state = "not-materialized"',
        'descriptor.enrichment_state = enrichment_required and "pending" or "complete"',
        "descriptor.enrichment_plan_id = enrichment_plan_id",
        "descriptor.enrichment_private_seed = enrichment_seed",
    )),
    "weak_process_owner": 'LIVE_ENRICHMENT_TRANSACTIONS = setmetatable({}, { __mode = "k" })' in GEN,
    "no_persisted_running_state": 'descriptor.enrichment_state = "running"' not in GEN,
    "central_trigger": "function Lazy.EnsureUndergroundFirstLoadReady" in GEN,
    "private_runner_capability": all(token in GEN for token in (
        "smr.sbm.lazy-underground-enrichment-capability.v1",
        "capability.authorize", "owner.capability ~= capability",
    )),
    "three_authorized_routes": all(f'trigger_kind == "{v}"' in GEN for v in (
        "view-switch", "elevator-transfer", "authorized-map-load")),
    "external_wrapper_gate": "lazy.EnsureUndergroundFirstLoadReady(" in GEN
        and "State.deferred_elevator_hidden_roundtrip_active" in GEN,
    "construction_route_gate": '"authorized-map-load", surface, underground' in GEN,
    "core_skips_density": "if deposits and capability_context == nil" in GEN
        and 'map.SuperBigMapUndergroundEnrichmentState = "pending"' in GEN,
	"wonder_lifecycle_deferred_only_with_plan": all(token in GEN for token in (
		'if capability_context == nil\n\t\t\t\tor not cfg_bool(',
		'map.SuperBigMapUndergroundWonderGameInitDeferredForEnrichment = true',
		'underground.SuperBigMapUndergroundWonderGameInitDeferredForEnrichment == true',
	)),
    "core_keeps_physical_pipeline": all(token in GEN for token in (
        'HeartbeatPhase("underground-StretchSourceToFull")',
        'HeartbeatPhase("underground-align-passage-pairs")',
        'HeartbeatPhase("underground-closing-canonical-grid-rebuild")',
    )),
    "private_rng": all(token in DEP for token in (
        "local SharedRandInt = Engine.RandInt",
        "budget.rng_state = (budget.rng_state * 48271) % 2147483647",
        "function DepositRules.BeginBoundedUndergroundEnrichment",
    )),
    "bounded_candidate_validation": all(token in DEP for token in (
        'CheckUndergroundEnrichmentBudget(map, "candidate")',
        'CheckUndergroundEnrichmentBudget(map, "validation")',
        "maximum_candidates > 16384", "maximum_validations > 65536",
    )),
    "spatial_repulsion_retained": "local function NewTopUpRepulsionTracker" in DEP
        and "OPTIMIZE_TOPUP_HARD_SPACING_SPATIAL_INDEX" in DEP,
    "commit_revalidation": DEP.count(
        "RevalidateBoundedUndergroundCandidateAtCommit(") == 4
        and "CanReceiveDeposit(" in DEP and "UndergroundCandidateReachable(" in DEP,
    "final_fail_closed_audits": all(token in GEN for token in (
        "final density/repulsion audit failed",
        "post-rebuild enrichment reachability revalidation failed",
        "final_audit_ok = true",
    )),
    "save_load_one_resume": "attempts > 2" in GEN
        and "owned-deferred-enrichment" in GEN,
    "sticky_failure": 'descriptor.enrichment_state = "failed"' in GEN
        and "Lazy.MarkBlocked(surface" in GEN,
    "oracle_present": ORACLE.is_file(),
    "iter239_microbenchmark_present": MICROBENCH.is_file()
        and "e95e30d7008d08f655294cb6a3911d180eb3fe4ddfc8bcdca86c97f904ed5596"
        in MICROBENCH.read_text(encoding="utf-8"),
}

failed = [name for name, ok in checks.items() if not ok]
for name, ok in checks.items():
    print(f"{name}={'ok' if ok else 'FAIL'}")
if failed:
    print("failed=" + ",".join(failed), file=sys.stderr)
    raise SystemExit(1)
print("v996 lazy enrichment deferral static checker: ok")
