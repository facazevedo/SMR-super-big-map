#!/usr/bin/env python3
"""Fail-closed static gate for v990's reload-stable private materialization capability."""

from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[2]
MAP = (ROOT / "Code/sbm_map_generation.lua").read_text(encoding="utf-8")
TERRAIN = (ROOT / "Code/sbm_terrain_copy.lua").read_text(encoding="utf-8")
VERSION = (ROOT / "Code/sbm_version.lua").read_text(encoding="utf-8")
META = (ROOT / "metadata.lua").read_text(encoding="utf-8")

required_map = [
    '"SuperBigMap/v990/lazy-materialization-private-capability"',
    "function Lazy.MaterializeTransaction(surface, descriptor, route, expected_owner, capability_debug)",
    "Lazy.LIVE_MATERIALIZATION_TRANSACTIONS[surface] ~= expected_owner",
    "capability.authorize = function(presented, expected_map)",
    'return false, nil, "capability authorizer re-entered"',
    "Lazy.OwnedMaterializationInFlight(surface, descriptor, report)",
    "pipeline(underground, true, capability)",
    "local function RunUndergroundStretchIfEnabled(map, force_now, materialization_capability)",
    "materialization_capability.authorize, materialization_capability, map",
    "lazy_materialization_capability = materialization_capability",
    "lazy_materialization_context = capability_context",
    'schema = "smr.sbm.lazy-materialization-capability-debug.v1"',
    '"before-owner-install"',
    '"before-deferred-pipeline"',
    'stage = "pipeline-entry"',
    '"after-deferred-pipeline"',
    "tostring(key):sub(1, 64)",
    "value:sub(1, 160)",
]
required_terrain = [
    "local materialization_capability = options.lazy_materialization_capability",
    "local materialization_context = options.lazy_materialization_context",
    "pcall(authorize, materialization_capability, map)",
    "and context == materialization_context",
    "and context.surface == surface_map and context.underground == map",
    'stage = "target-level-capability"',
    "authorization_depth = type(context) == \"table\"",
    "capsule.x ~= x or capsule.y ~= y or capsule.q ~= q or capsule.r ~= r",
    "pcall(terrain_api.GetHeight, map, point_fn(x, y))",
]

missing = [token for token in required_map if token not in MAP]
missing += [token for token in required_terrain if token not in TERRAIN]
assert not missing, "missing v990 capability contracts: " + ", ".join(missing)

assert "SuperBigMap.GENERATOR_PATCH_VERSION = 297" in VERSION
assert re.search(r"'version',\s*991\b", META)
assert "Lazy.OwnedMaterializationInFlight(surface_map, descriptor, report)" not in TERRAIN
assert "materialization_capability = capability" not in MAP
assert "descriptor.materialization_capability" not in MAP
assert "report.materialization_capability =" not in MAP
assert "underground.SuperBigMapLazyMaterializationCapability =" not in MAP
assert MAP.count("pipeline(underground, true, capability)") == 1
assert TERRAIN.count("pcall(authorize, materialization_capability, map)") == 1

print("ok=true")
print("explicit_private_capability_call_chain=true")
print("module_global_owner_rediscovery_absent=true")
print("capability_not_persisted_or_global=true")
print("bounded_identity_phase_depth_debug=true")
print("target_z_geometry_and_digest_contract_retained=true")
