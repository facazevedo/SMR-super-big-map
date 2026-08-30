#!/usr/bin/env python3
"""Static/order contract for v988's scoped explicit-level passage-pad preparation."""

from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]


def require(text: str, token: str, label: str) -> None:
    if token not in text:
        raise SystemExit(f"missing {label}: {token}")


def ordered(text: str, tokens: list[str], label: str) -> None:
    positions: list[int] = []
    cursor = 0
    for token in tokens:
        position = text.find(token, cursor)
        positions.append(position)
        if position >= 0:
            cursor = position + len(token)
    if min(positions) < 0:
        raise SystemExit(f"order drifted for {label}: {positions}")


def main() -> None:
    terrain = (ROOT / "Code/sbm_terrain_copy.lua").read_text(encoding="utf-8")
    rocket = (ROOT / "Code/sbm_rocket_rules.lua").read_text(encoding="utf-8")
    metadata = (ROOT / "metadata.lua").read_text(encoding="utf-8")
    version = (ROOT / "Code/sbm_version.lua").read_text(encoding="utf-8")

    require(metadata, "'version', 995", "metadata version")
    require(version, "GENERATOR_PATCH_VERSION = 301", "generator identity")
    require(rocket, "LANDING_FLATTEN_PATCH_VERSION = 3", "flatten wrapper identity")
    require(rocket, 'local native = Global("FlattenTerrainInShape")', "official native overload")
    require(rocket, "map.buildable.z_grid, map.object_hex_grid, inner, outer, -1, explicit_z",
            "explicit-level signature")
    require(rocket, "passage_trace.anchor == obj and passage_trace.map == map",
            "object/map owner binding")
    require(rocket, 'error("invalid scoped passage-pad explicit-level capability")',
            "invalid capability rejection")
    require(terrain, "underground_preparation_z, source_level_reason, source_q, source_r =",
            "ordinary pre-move source level fallback")
    require(terrain, 'or "source-level-captured"', "ordinary source debug")
    require(terrain, '"target-level-certified"', "lazy committed-target debug")
    require(terrain, 'stage = "native-explicit-level"', "native debug")
    require(terrain, 'stage = "before"', "before footprint debug")
    require(terrain, 'stage = "after"', "after footprint debug")
    require(terrain, 'stage = "transaction-final"', "final footprint debug")
    require(terrain, "maximum_pairs = 2, maximum_records = 24", "bounded diagnostics")
    require(terrain, 'error = "linked passage transaction-final terrain validation failed"',
            "later mutation rejection")
    ordered(terrain, [
        "certified_lazy_underground_target_level(surface_anchor, underground_map,",
        "clear_passage_obstructions(underground_anchor,",
        "move_object(underground_anchor, underground_map, expected_ux, expected_uy)",
        "prepare_passage_pad(underground_anchor, underground_map,",
        "for i = 1, #final_prepared_validations do",
    ], "capture>clear>move>explicit flatten>final validation")
    ordered(terrain, [
        "state.passage_pad_preparation_depth = previous_depth + 1",
        "flatten_build_shape, elevator_shape, anchor, \"flatten unbuildable\"",
        "state.passage_pad_preparation_depth = previous_depth > 0 and previous_depth or nil",
        "scoped explicit-level passage-pad preparation was not certified",
        "move_object(anchor, map, x, y)",
    ], "capability>native>cleanup>certificate>resnap")

    print("ok=true")
    print("version=995")
    print("native_signature=shape,obj,z_grid,object_grid,inner,outer,-1,explicit_z")
    print("validation_order=immediate>transaction-final")
    print("diagnostic_bound=pairs2,records24")


if __name__ == "__main__":
    main()
