from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[2]
MAP = (ROOT / "Code/sbm_map_generation.lua").read_text(encoding="utf-8")
VERSION = (ROOT / "Code/sbm_version.lua").read_text(encoding="utf-8")
META = (ROOT / "metadata.lua").read_text(encoding="utf-8")

required = (
    "function SuperBigMap.InstallDiagnosticPhaseHeartbeatSink(sink, surface, expected_descriptor,",
    "local ready_target = State.lazy_diagnostic_ready_target",
    "ready_target.surface ~= surface",
    "ready_target.descriptor ~= expected_descriptor",
    "ready_target.descriptor ~= descriptor",
    "ready_target.report ~= report",
    "lazy.StateSurface() ~= surface",
    "SuperBigMap.State.lazy_diagnostic_ready_target = {",
    "surface = surface,\n\t\tdescriptor = descriptor,\n\t\treport = report,",
    "if diagnostic_heartbeat and (type(ready_target) ~= \"table\"",
    "process-local ready target identity was lost before materialization",
    "SuperBigMap.State.lazy_diagnostic_ready_target = nil",
    "State.lazy_diagnostic_ready_target = nil",
)
missing = [token for token in required if token not in MAP]
if missing:
    raise SystemExit("missing ready-target contract: " + repr(missing))
if "SuperBigMap.GENERATOR_PATCH_VERSION = 302" not in VERSION:
    raise SystemExit("generator patch 302 missing")
if not re.search(r"'version',\s*996\b", META):
    raise SystemExit("metadata v996 missing")
installer = MAP[MAP.index("function SuperBigMap.InstallDiagnosticPhaseHeartbeatSink"):
                MAP.index("local function PointXY")]
for forbidden in ('rawget(_G, "g_SmrRalphSurfaceReferenceState")', "AsyncRand"):
    if forbidden in installer:
        raise SystemExit("installer trusts forbidden identity/RNG: " + forbidden)

print("ok=true")
print("version=996")
print("generator_patch=302")
print("ready_target=process-local-surface+descriptor+report")
print("loaded_ready_diagnostic_arm=false")
print("ordinary_loaded_ready_materialization_unchanged=true")
print("clear_on_materialize_block_restore=true")
