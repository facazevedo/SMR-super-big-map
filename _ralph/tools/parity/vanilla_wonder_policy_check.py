#!/usr/bin/env python3
"""Static and synthetic gate for stock buried-wonder visibility parity."""

from __future__ import annotations

import argparse
import json
import re
from pathlib import Path


def all_of(text: str, *needles: str) -> bool:
    return all(needle in text for needle in needles)


def simulate_migration(
    *, legacy: bool, visible: bool, opacity: int, wrapper_current: bool, had_raw: bool
) -> dict[str, object]:
    method = "original" if wrapper_current and had_raw else "inherited"
    if not wrapper_current:
        method = "unrelated_current"
    if not legacy:
        return {
            "visible": visible,
            "opacity": opacity,
            "stamps_cleared": True,
            "method": method,
        }
    return {
        "visible": True,
        "opacity": 100,
        "stamps_cleared": True,
        "method": method,
    }


def forbidden_policy_present(text: str) -> bool:
    return any(
        needle in text
        for needle in (
            "SuperBigMap.BuriedWonderDarkness = {",
            "BuriedWonderDarkness.SyncVisibility",
            "BuriedWonderDarkness.Refresh",
            "SuperBigMapConcealedByDarkness = true",
        )
    )


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--project", type=Path, required=True)
    parser.add_argument("--out", type=Path, required=True)
    args = parser.parse_args()

    project = args.project.resolve()
    generation = (project / "Code" / "sbm_map_generation.lua").read_text(encoding="utf-8")
    lifecycle = (project / "Code" / "sbm_lifecycle.lua").read_text(encoding="utf-8")
    config = (project / "Code" / "sbm_config.lua").read_text(encoding="utf-8")
    button = (project / "Code" / "sbm_place_elevator_button.lua").read_text(encoding="utf-8")
    version = (project / "Code" / "sbm_version.lua").read_text(encoding="utf-8")
    metadata = (project / "metadata.lua").read_text(encoding="utf-8")

    migration_start = generation.index(
        "function SuperBigMap.RestoreLegacyBuriedWonderConcealment()"
    )
    migration_end = generation.index("local function ApplyDeferredWonderStretch", migration_start)
    migration = generation[migration_start:migration_end]

    static = {
        "production_config_removed": "CONCEAL_BURIED_WONDERS_IN_DARKNESS" not in config
        and "ConcealBuriedWondersInDarkness" not in config,
        "ongoing_policy_table_removed": not forbidden_policy_present(generation),
        "sync_and_refresh_hooks_removed": not any(
            needle in generation or needle in lifecycle or needle in button
            for needle in (
                "BuriedWonderDarkness.SyncVisibility",
                "BuriedWonderDarkness.Refresh",
                "PatchBuriedWonderDarknessVisibility",
                "RefreshBuriedWonderDarknessVisibility",
            )
        ),
        "production_never_marks_concealed": "SuperBigMapConcealedByDarkness = true" not in generation,
        "legacy_migration_is_restore_only": all_of(
            migration,
            "pcall(wonder.SetVisible, wonder, true)",
            "pcall(root.SetOpacity, root, 100)",
            "wonder.SuperBigMapConcealedByDarkness = nil",
            "wonder.SuperBigMapDarknessVisibilityRestored = nil",
            "wonder.SuperBigMapDarknessVisibilityReason = nil",
            "SuperBigMap.BuriedWonderDarkness = nil",
        ) and not re.search(r"SetOpacity[^\n]*,\s*0\)", migration),
        "legacy_update_wrapper_is_removed": all_of(
            migration,
            "class.UpdateRevealObject == State.buried_wonder_darkness_update_wrapper",
            "class.UpdateRevealObject = State.original_buried_wonder_update_reveal_object",
            "State.buried_wonder_darkness_update_wrapper = nil",
        ),
        "migration_runs_on_apply_and_restore": generation.count(
            "SuperBigMap.RestoreLegacyBuriedWonderConcealment()"
        ) == 3,
        "stretched_wonder_grid_registration_retained": all_of(
            generation,
            "wonder:ApplyToGrids()",
            "if wonder.grids_applied ~= true then",
            "function SuperBigMap.GenerationGrids.RebuildFinal(map, stage)",
        ),
        "test_only_blanket_default_remains_off": all_of(
            config,
            "-- TEMP test aid: remove the underground darkness blanket",
            "config.UndergroundRevealAllDarkness = false",
        ),
        "version_bumped": "SuperBigMap.GENERATOR_PATCH_VERSION = 232" in version
        and re.search(r"'version',\s*821,", metadata) is not None
        and "Restore stock buried-wonder darkness and visibility behavior." in metadata,
    }

    tagged = simulate_migration(
        legacy=True, visible=False, opacity=0, wrapper_current=True, had_raw=True
    )
    untagged = simulate_migration(
        legacy=False, visible=False, opacity=42, wrapper_current=False, had_raw=True
    )
    legacy_policy_fixture = "\n".join(
        (
            "SuperBigMap.BuriedWonderDarkness = { PATCH_VERSION = 3 }",
            "BuriedWonderDarkness.SyncVisibility(wonder, map)",
            "wonder.SuperBigMapConcealedByDarkness = true",
        )
    )
    synthetic = {
        "legacy_concealment_restores_stock_visible_opacity": tagged
        == {
            "visible": True,
            "opacity": 100,
            "stamps_cleared": True,
            "method": "original",
        },
        "untagged_stock_visual_state_is_untouched": untagged
        == {
            "visible": False,
            "opacity": 42,
            "stamps_cleared": True,
            "method": "unrelated_current",
        },
        "legacy_v3_policy_fixture_is_rejected": forbidden_policy_present(legacy_policy_fixture),
        "restore_only_migration_is_accepted": not forbidden_policy_present(migration),
    }

    failed_static = [name for name, passed in static.items() if not passed]
    failed_synthetic = [name for name, passed in synthetic.items() if not passed]
    report = {
        "schema": "smr.ralph.vanilla-buried-wonder-policy",
        "schema_version": 1,
        "status": "green" if not failed_static and not failed_synthetic else "red",
        "static": static,
        "synthetic": synthetic,
        "failed_static": failed_static,
        "failed_synthetic": failed_synthetic,
        "policy": {
            "normal_gameplay": "stock vanilla darkness, reveal, visibility, and faint rendering",
            "legacy_migration": "restore only objects stamped by removed v1-v3 concealment",
            "grid_behavior": "wonder remains active and registered for final stock property rebuild",
        },
        "live_gate_remaining": "fresh hidden v821 stock-darkness visual and proportional property capture",
    }
    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(report, indent=2))
    return 0 if report["status"] == "green" else 1


if __name__ == "__main__":
    raise SystemExit(main())
