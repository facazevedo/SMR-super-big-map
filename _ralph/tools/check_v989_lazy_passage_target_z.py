#!/usr/bin/env python3
"""Static/executable v989 lazy passage target-Z provenance regression."""
from __future__ import annotations

import pathlib
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parents[2]
TERRAIN = (ROOT / "Code" / "sbm_terrain_copy.lua").read_text(encoding="utf-8")
GENERATION = (ROOT / "Code" / "sbm_map_generation.lua").read_text(encoding="utf-8")
VERSION = (ROOT / "Code" / "sbm_version.lua").read_text(encoding="utf-8")
METADATA = (ROOT / "metadata.lua").read_text(encoding="utf-8")
LUA = ROOT / "_ralph" / "tmp" / ".tmp_surface_loading_rough_iter109_lua53" / "lua-5.3.6" / "src" / "lua.exe"
ORACLE = ROOT / "_ralph" / "tools" / "v989_lazy_passage_target_z_oracle.lua"

required_terrain = (
    "certified_lazy_underground_target_level",
    'phase == "materialization-deferred-pipeline"',
    "pcall(authorize, materialization_capability, map)",
    "validation_digest ~= descriptor.validation_z_digest",
    'stage = lazy_capsule_index and "target-level-certified"',
    "terrain_api.GetHeight, map, point_fn(x, y)",
    "capsule.underground_preparation_z = certificate.target_z",
    "descriptor.materialization_passage_pad_z_certificates = 2",
    "descriptor.materialization_passage_pad_z_digest = aggregate",
    "lazy passage target-level certificate identity drifted",
    "prepared_underground_level ~= underground_preparation_z",
    'and "explicit target level mismatch"',
)
required_generation = (
    "passage_pad_z_certificate_exact",
    "deferred underground completion omitted the exact passage-pad target-Z certificate",
)
for token in required_terrain:
    if token not in TERRAIN:
        raise SystemExit(f"missing terrain target-Z contract token: {token}")
for token in required_generation:
    if token not in GENERATION:
        raise SystemExit(f"missing materialization target-Z contract token: {token}")
if "return nil, \"not a lazy underground capsule\"" not in TERRAIN:
    raise SystemExit("ordinary/eager passage branch separation is missing")
if "underground_preparation_z, source_level_reason, source_q, source_r =\n\t\t\t\t\tpassage_pad_level" not in TERRAIN:
    raise SystemExit("ordinary source-level fallback was not retained")
if "SuperBigMap.GENERATOR_PATCH_VERSION = 298" not in VERSION or "'version', 992" not in METADATA:
    raise SystemExit("v992 forward production version is missing")

for source in (ROOT / "Code" / "sbm_terrain_copy.lua", ROOT / "Code" / "sbm_map_generation.lua"):
    parsed = subprocess.run(
        [str(LUA), "-e", f"assert(loadfile([[{source.as_posix()}]]))"],
        text=True, capture_output=True, check=False,
    )
    if parsed.returncode:
        sys.stderr.write(parsed.stdout + parsed.stderr)
        raise SystemExit(f"Lua 5.3 parse failed: {source.name}")
oracle = subprocess.run([str(LUA), str(ORACLE)], text=True, capture_output=True, check=False)
if oracle.returncode or "ok=true" not in oracle.stdout:
    sys.stderr.write(oracle.stdout + oracle.stderr)
    raise SystemExit("v989 target-Z oracle failed")

print("ok=true")
print("version=992")
print("lazy_level_source=committed-target-terrain")
print("surface_validation_z_role=integrity-only")
print("target_certificate=owner+capsule+plan+validation-digest+coordinate+height")
print("ordinary_fallback=retained")
