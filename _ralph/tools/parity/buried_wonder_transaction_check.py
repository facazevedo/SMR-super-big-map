#!/usr/bin/env python3
"""Static and synthetic discriminator for transactional wonder concealment.

This does not claim the engine message order works at runtime.  It proves that the
candidate is materially different from the already-refuted steady-state flag
tests and records the exact live discriminator still required.
"""

from __future__ import annotations

import argparse
import json
from pathlib import Path


def contains(text: str, *needles: str) -> bool:
    return all(needle in text for needle in needles)


def simulate(*, concealed: bool, map_enabled: bool, rebuilding: bool) -> dict[str, bool]:
    """Model only the proposed state policy, not engine rasterization."""
    idle_visible = not (concealed and map_enabled)
    during_visible = True if concealed and map_enabled and rebuilding else idle_visible
    after_visible = idle_visible
    return {
        "idle_visible": idle_visible,
        "during_visible": during_visible,
        "after_visible": after_visible,
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--project", type=Path, required=True)
    parser.add_argument("--game-src", type=Path, required=True)
    parser.add_argument("--out", type=Path, required=True)
    args = parser.parse_args()

    project = args.project.resolve()
    game = args.game_src.resolve()
    mod_generation_path = project / "Code" / "sbm_map_generation.lua"
    cobject_path = game / "CommonLua" / "Classes" / "_cobject.lua"
    marker_path = game / "CommonLua" / "Classes" / "marker.lua"
    entity_path = game / "CommonLua" / "_EntityData.generated.lua"
    shapeshifter_path = game / "CommonLua" / "Classes" / "Shapeshifter.lua"

    mod_generation = mod_generation_path.read_text(encoding="utf-8")
    cobject = cobject_path.read_text(encoding="utf-8")
    marker = marker_path.read_text(encoding="utf-8")
    entity = entity_path.read_text(encoding="utf-8")
    shapeshifter = shapeshifter_path.read_text(encoding="utf-8")

    static = {
        "current_concealment_keeps_visible": contains(
            mod_generation,
            "local function SetWonderConcealed(wonder, concealed)",
            "pcall(wonder.SetVisible, wonder, true)",
            "concealed and 0 or 100",
        ),
        "current_final_path_calls_stock_rebuild": contains(
            mod_generation,
            "function SuperBigMap.GenerationGrids.RebuildFinal(map, stage)",
            "terrain_api.RebuildPassability(map, final_pass_box)",
        ),
        "set_visible_is_only_enum_flag_write": contains(
            cobject,
            "function CObject:SetVisible(value)",
            "self:SetEnumFlags( efVisible )",
            "self:ClearEnumFlags( efVisible )",
        ) and "InvalidateSurfaces" not in cobject[
            cobject.index("function CObject:SetVisible(value)") :
            cobject.index("function CObject:SetVisible(value)") + 240
        ],
        "engine_has_pre_rebuild_message": contains(
            marker,
            "function OnMsg.OnPassabilityRebuilding(map, clip)",
            "terrain.ClearPassabilityBox(map, bx)",
        ),
        "engine_has_post_rebuild_message_consumers": "function OnMsg.OnPassabilityChanged" in (
            game / "CommonLua" / "Classes" / "Flight.lua"
        ).read_text(encoding="utf-8"),
        "invisible_entity_has_no_declared_surfaces": contains(
            entity,
            'EntityData["InvisibleObject"] = {',
            "fade_category = \"Never\"",
        ) and "collision_meshes" not in entity[
            entity.index('EntityData["InvisibleObject"] = {') :
            entity.index('EntityData["InvisibleObject"] = {') + 120
        ],
        "shapeshifter_can_reuse_real_entity": contains(
            shapeshifter,
            "DefineClass.Shapeshifter",
            "variable_entity = true",
            "self:ChangeEntity(entity)",
        ),
    }

    synthetic_cases = {
        "concealed_idle_hidden": not simulate(
            concealed=True, map_enabled=True, rebuilding=False
        )["idle_visible"],
        "concealed_rebuild_visible": simulate(
            concealed=True, map_enabled=True, rebuilding=True
        )["during_visible"],
        "concealed_after_hidden": not simulate(
            concealed=True, map_enabled=True, rebuilding=True
        )["after_visible"],
        "revealed_always_visible": all(
            simulate(concealed=False, map_enabled=True, rebuilding=True).values()
        ),
        "disabled_map_always_visible": all(
            simulate(concealed=True, map_enabled=False, rebuilding=True).values()
        ),
    }

    failed_static = [name for name, passed in static.items() if not passed]
    failed_synthetic = [name for name, passed in synthetic_cases.items() if not passed]
    report = {
        "schema": "smr.ralph.buried-wonder-transaction-hypothesis",
        "schema_version": 1,
        "candidate": "temporarily set efVisible during stock passability rebuild, then clear it after",
        "status": "ready_for_live_discriminator" if not failed_static and not failed_synthetic else "static_red",
        "static": static,
        "synthetic": synthetic_cases,
        "failed_static": failed_static,
        "failed_synthetic": failed_synthetic,
        "proven": [
            "InvisibleObject is not a direct exact-footprint surrogate.",
            "The proposed policy is hidden at idle but visible during the stock rebuild.",
            "CObject:SetVisible does not itself call InvalidateSurfaces in the exposed Lua implementation.",
            "The engine exposes pre- and post-rebuild message families used by stock Lua.",
        ],
        "not_proven": [
            "OnPassabilityChanged fires synchronously after object rasterization for every rebuild form.",
            "Clearing efVisible after the rebuild preserves the newly rasterized grid until the next rebuild.",
            "The candidate reaches both the zero-pixel concealment and unchanged-imprint live thresholds.",
        ],
        "required_live_discriminator": {
            "states": [
                "drawn control",
                "steady hidden control",
                "steady opacity-zero control",
                "transactional visible-during-rebuild then hidden",
                "transactional repeat",
                "drawn restore",
            ],
            "assertions": [
                "node dump proves efVisible true inside OnPassabilityRebuilding",
                "node dump proves efVisible false before each screenshot",
                "passability imprint hash/count equals the drawn or opacity-zero control",
                "pixel frame equals the steady hidden control within the established noise floor",
                "repeat and restore controls are stable",
            ],
        },
        "sources": {
            "mod_generation": str(mod_generation_path),
            "cobject": str(cobject_path),
            "marker": str(marker_path),
            "entity_data": str(entity_path),
            "shapeshifter": str(shapeshifter_path),
        },
    }
    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(report, indent=2))
    return 0 if report["status"] == "ready_for_live_discriminator" else 1


if __name__ == "__main__":
    raise SystemExit(main())
