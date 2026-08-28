#!/usr/bin/env python3
"""Static and state-machine gate for the v964 deferred underground completion fix."""

from __future__ import annotations

import hashlib
import json
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
GENERATION_PATH = ROOT / "Code" / "sbm_map_generation.lua"
VERSION_PATH = ROOT / "Code" / "sbm_version.lua"
METADATA_PATH = ROOT / "metadata.lua"


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def model_revoke(state: dict) -> bool:
    if not (
        state.get("prepared") is True
        and state.get("bootstrap") is True
        and state.get("surface_final") is True
    ):
        return False
    pairs = state.get("pairs", [])
    if not isinstance(state.get("expected"), int) or state["expected"] <= 0:
        return False
    if len(pairs) != state["expected"]:
        return False
    for pair in pairs:
        if not (pair.get("reciprocal") and pair.get("locked")):
            return False
        source = pair.get("source")
        final = pair.get("final")
        if not (
            pair.get("underground_live") == source
            and pair.get("surface_live") == final
            and pair.get("surface_stamp") == final
            and source != final
        ):
            return False
    state["prepared"] = False
    state["done"] = False
    state["pending"] = False
    return True


def deferred_pair(source: tuple[int, int], final: tuple[int, int]) -> dict:
    return {
        "reciprocal": True,
        "locked": True,
        "source": source,
        "final": final,
        "underground_live": source,
        "surface_live": final,
        "surface_stamp": final,
    }


def semantic_cases() -> dict[str, bool]:
    fresh = {
        "expanded": True,
        "prepared": False,
        "done": False,
        "bootstrap": True,
        "surface_final": True,
        "expected": 2,
        "pairs": [
            deferred_pair((430500, 243346), (226000, 245944)),
            deferred_pair((240000, 348132), (324500, 458114)),
        ],
    }
    stale = dict(fresh, prepared=True, done=True)
    stale["pairs"] = [dict(pair) for pair in fresh["pairs"]]
    completed = dict(stale)
    completed["pairs"] = [dict(pair) for pair in stale["pairs"]]
    for pair in completed["pairs"]:
        pair["underground_live"] = pair["final"]
    mixed = dict(stale)
    mixed["pairs"] = [dict(pair) for pair in stale["pairs"]]
    mixed["pairs"][1]["underground_live"] = mixed["pairs"][1]["final"]
    legacy = {"expanded": True, "prepared": True, "done": True}

    fresh_revoked = model_revoke(fresh)
    stale_revoked = model_revoke(stale)
    completed_revoked = model_revoke(completed)
    mixed_revoked = model_revoke(mixed)
    legacy_revoked = model_revoke(legacy)

    reused = {
        "environment": "Underground",
        "expanded": True,
        "prepared": True,
        "done": True,
        "pending": True,
        "running": True,
        "failed": "old failure",
        "preparation_failed": True,
        "deferred_geometry": {"old": True},
        "surface_final": True,
    }
    if reused["environment"] == "Underground":
        reused.update(
            expanded=False,
            prepared=False,
            done=False,
            pending=False,
            running=False,
            failed=None,
            preparation_failed=False,
            deferred_geometry=False,
            surface_final=None,
        )
    return {
        "expanded_alone_never_becomes_prepared": not fresh_revoked and fresh["prepared"] is False,
        "exact_v963_false_positive_is_revoked": stale_revoked
        and stale["prepared"] is False
        and stale["done"] is False,
        "completed_shared_live_pairs_are_not_revoked": not completed_revoked
        and completed["prepared"] is True,
        "mixed_state_is_not_destructively_repaired": not mixed_revoked and mixed["prepared"] is True,
        "legacy_prepared_without_current_protocol_is_untouched": not legacy_revoked
        and legacy["prepared"] is True,
        "reused_underground_instance_starts_unprepared": reused
        == {
            "environment": "Underground",
            "expanded": False,
            "prepared": False,
            "done": False,
            "pending": False,
            "running": False,
            "failed": None,
            "preparation_failed": False,
            "deferred_geometry": False,
            "surface_final": None,
        },
    }


def main() -> int:
    generation = GENERATION_PATH.read_text(encoding="utf-8")
    version = VERSION_PATH.read_text(encoding="utf-8")
    metadata = METADATA_PATH.read_text(encoding="utf-8")
    fresh_start = generation.index(
        "function SuperBigMap.GenerationReadiness.InitializeFreshUndergroundExpansionState"
    )
    fresh_end = generation.index("local function ClearPreparedMapInstance", fresh_start)
    fresh = generation[fresh_start:fresh_end]
    attach_start = generation.index("local function AttachPendingMapState")
    attach_end = generation.index("local function IsEligibleMapData", attach_start)
    attach = generation[attach_start:attach_end]
    prepare_start = generation.index("local function PrepareMapDataForExpansion")
    prepare_end = generation.index("local CaptureGeneratedNativeEnrichments", prepare_start)
    prepare = generation[prepare_start:prepare_end]
    generate_start = generation.index("local generate_wrapper = function")
    generate_end = generation.index("generator_class.Generate = generate_wrapper", generate_start)
    generate = generation[generate_start:generate_end]
    legacy_start = generation.index("function SuperBigMap.GenerationReadiness.LegacyUndergroundEvidence")
    legacy_end = generation.index("function SuperBigMap.GenerationReadiness.RecoverPersistedUnderground", legacy_start)
    legacy_evidence = generation[legacy_start:legacy_end]
    helper_start = generation.index(
        "function SuperBigMap.GenerationReadiness.RevokeDeferredUndergroundFalseCompletion"
    )
    helper_end = generation.index("local function RunUndergroundStretchIfEnabled", helper_start)
    helper = generation[helper_start:helper_end]
    run_start = helper_end
    run_end = generation.index("local function NeedsDeferredUndergroundPreparation", run_start)
    run_path = generation[run_start:run_end]
    needs_start = run_end
    needs_end = generation.index("-- Unit:UseElevator", needs_start)
    needs_path = generation[needs_start:needs_end]

    obsolete_shortcut = (
        "if map.SuperBigMapExpanded == true and map.SuperBigMapExpansionPending ~= true then\n"
        "\t\tmap.SuperBigMapUndergroundPrepared = true"
    )
    checks = {
        "metadata_v964": "'version', 964," in metadata,
        "hot_reload_patch_identity_v273": "SuperBigMap.GENERATOR_PATCH_VERSION = 273" in version,
        "expanded_completion_shortcut_removed": obsolete_shortcut not in generation,
        "fresh_underground_initializer_is_environment_scoped": (
            'map.mapdata.Environment ~= "Underground"' in fresh
            and all(
                token in fresh
                for token in (
                    "map.SuperBigMapExpanded = false",
                    "map.SuperBigMapUndergroundPrepared = false",
                    "map.SuperBigMapUndergroundStretchDone = false",
                    "map.SuperBigMapUndergroundStretchPending = false",
                    "map.SuperBigMapUndergroundStretchRunning = false",
                    "map.SuperBigMapUndergroundStretchFailed = nil",
                    "map.SuperBigMapUndergroundPreparationFailed = false",
                    "map.SuperBigMapUndergroundDeferredGeometry = false",
                    "map.SuperBigMapPassageSurfaceFinalCommitted = nil",
                )
            )
        ),
        "fresh_initializer_runs_at_plan_and_safe_attachment": (
            "SuperBigMap.GenerationReadiness.InitializeFreshUndergroundExpansionState(map_instance)"
            in prepare
            and "SuperBigMap.GenerationReadiness.InitializeFreshUndergroundExpansionState(map)"
            in attach
            and "map.SuperBigMapNativeGenerationComplete ~= true" in attach
            and "map.SuperBigMapPassageBootstrapComplete ~= true" in attach
        ),
        "fresh_false_bits_are_transported_into_new_map": all(
            token in generate
            for token in (
                '"SuperBigMapExpanded", "SuperBigMapUndergroundPrepared"',
                '"SuperBigMapUndergroundStretchDone", "SuperBigMapUndergroundStretchPending"',
                '"SuperBigMapUndergroundPreparationFailed", "SuperBigMapUndergroundDeferredGeometry"',
                '"SuperBigMapPassageSurfaceFinalCommitted"',
                "params[field] = instance[field]",
            )
        ),
        "legacy_readiness_never_treats_expanded_as_completion": (
            "if map.SuperBigMapUndergroundPrepared == true then" in legacy_evidence
            and "map.SuperBigMapExpanded == true" not in legacy_evidence
        ),
        "repair_requires_current_committed_surface_final": all(
            token in helper
            for token in (
                "map.SuperBigMapUndergroundPrepared ~= true",
                "map.SuperBigMapPassageBootstrapComplete ~= true",
                "map.SuperBigMapPassageSurfaceFinalCommitted ~= true",
                "map.SuperBigMapPassageBootstrapCount",
            )
        ),
        "repair_requires_exact_reciprocal_locked_pairs": all(
            token in helper
            for token in (
                "surface_anchor.other ~= underground_anchor",
                "underground_anchor.SuperBigMapCommittedPassageLocked ~= true",
                "surface_anchor.SuperBigMapCommittedPassageLocked ~= true",
                'ArtefactMapGet(map, "ElevatorPassage")',
                "#passages ~= expected",
            )
        ),
        "repair_requires_source_live_and_surface_final": all(
            token in helper
            for token in (
                "SuperBigMapCommittedPassageSourceX",
                "SuperBigMapCommittedPassageSourceY",
                "source_x == ux and source_y == uy",
                "final_x == sx and final_y == sy",
                "surface_final_x == final_x and surface_final_y == final_y",
                "source_x ~= final_x or source_y ~= final_y",
            )
        ),
        "repair_clears_only_completion_and_failure_state": all(
            token in helper
            for token in (
                "map.SuperBigMapUndergroundPrepared = false",
                "map.SuperBigMapUndergroundStretchDone = false",
                "map.SuperBigMapUndergroundStretchPending = false",
                "map.SuperBigMapUndergroundStretchFailed = nil",
                "map.SuperBigMapUndergroundPreparationFailed = false",
            )
        ) and "map.SuperBigMapExpanded = false" not in helper,
        "run_repairs_before_prepared_return": run_path.index(
            "SuperBigMap.GenerationReadiness.RevokeDeferredUndergroundFalseCompletion(map)"
        ) < run_path.index("if map.SuperBigMapUndergroundPrepared == true then"),
        "access_decision_repairs_before_prepared_test": needs_path.index(
            "SuperBigMap.GenerationReadiness.RevokeDeferredUndergroundFalseCompletion(map)"
        ) < needs_path.index(
            "if map.SuperBigMapUndergroundPrepared == true or map.SuperBigMapUndergroundStretchDone == true"
        ),
        "successful_pipeline_remains_sole_true_writer": generation.count(
            "map.SuperBigMapUndergroundPrepared = true"
        ) == 1,
        "successful_pipeline_still_aligns_before_publish": generation.index(
            "local pair_ok, pair_stats = AlignPassagePairsToSharedHex(map)"
        ) < generation.index("map.SuperBigMapUndergroundPrepared = true"),
    }
    checks.update(semantic_cases())
    failed = sorted(key for key, value in checks.items() if value is not True)
    report = {
        "schema": "smr.ralph.v964.deferred-underground-completion-gate.v1",
        "ok": not failed,
        "checks": checks,
        "failed": failed,
        "hashes": {
            str(path.relative_to(ROOT)).replace("\\", "/"): sha256(path)
            for path in (GENERATION_PATH, VERSION_PATH, METADATA_PATH)
        },
    }
    print(json.dumps(report, indent=2, sort_keys=True))
    return 0 if not failed else 1


if __name__ == "__main__":
    raise SystemExit(main())
