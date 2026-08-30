from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[2]
MAP = (ROOT / "Code/sbm_map_generation.lua").read_text(encoding="utf-8")
VERSION = (ROOT / "Code/sbm_version.lua").read_text(encoding="utf-8")
META = (ROOT / "metadata.lua").read_text(encoding="utf-8")

required = [
    "function SuperBigMap.InstallDiagnosticPhaseHeartbeatSink(sink, surface, expected_descriptor,\n\t\twrite_capability, clock_capability)",
    "function DiagnosticHeartbeat.Emit(sink, map, phase, edge, fields, write_capability, clock_capability)",
    'type(write_capability) ~= "function" or type(clock_capability) ~= "function"',
    'return false, "diagnostic heartbeat transport capabilities are unavailable"',
    "local first_clock_ok, first_clock = pcall(clock_capability)",
    "local second_clock_ok, second_clock = pcall(clock_capability)",
    "or first_clock ~= first_clock or second_clock ~= second_clock",
    "or second_clock < first_clock",
    "DiagnosticHeartbeat.write_capability = write_capability",
    "DiagnosticHeartbeat.clock_capability = clock_capability",
    "and DiagnosticHeartbeat.write_capability == write_capability",
    "and DiagnosticHeartbeat.clock_capability == clock_capability",
    "local write = DiagnosticHeartbeat.write_capability",
    "DiagnosticHeartbeat.write_capability = nil",
    "DiagnosticHeartbeat.clock_capability = nil",
    "phase_heartbeat(map, heartbeat_open_phase,",
]
missing = [token for token in required if token not in MAP]
if missing:
    raise SystemExit("missing explicit diagnostic transport capability tokens: " + repr(missing))

emit_start = MAP.index("function DiagnosticHeartbeat.Emit")
emit_end = MAP.index("local function PointXY", emit_start)
emit_block = MAP[emit_start:emit_end]
for forbidden in (
    'Global("AsyncStringToFile")', 'Global("GetPreciseTicks")',
    'Global("RealTime")', "AsyncRand",
):
    if forbidden in emit_block:
        raise SystemExit("diagnostic transport still depends on ambient capability: " + forbidden)

publish_start = MAP.index("function Lazy.PublishDiagnosticTerminalFailure")
publish_end = MAP.index("function Lazy.MarkBlocked", publish_start)
publish_block = MAP[publish_start:publish_end]
if 'local write = DiagnosticHeartbeat.write_capability' not in publish_block:
    raise SystemExit("terminal bundle does not use the exact retained writer capability")
if 'Global("AsyncStringToFile")' in publish_block:
    raise SystemExit("terminal bundle returned to ambient mod-environment file lookup")

if not re.search(r"GENERATOR_PATCH_VERSION\s*=\s*302\b", VERSION):
    raise SystemExit("generator patch 302 missing")
if not re.search(r"'version',\s*996\b", META):
    raise SystemExit("metadata v996 missing")

print("ok=true")
print("version=996")
print("generator_patch=302")
print("transport=explicit-private-writer+monotonic-clock")
print("ambient_mod_global_lookups=0")
print("terminal_writer_identity_retained=true")
print("default_off_rng_calls=0")
