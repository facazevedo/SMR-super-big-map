from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
MAP = (ROOT / "Code/sbm_map_generation.lua").read_text(encoding="utf-8")
TERRAIN = (ROOT / "Code/sbm_terrain_copy.lua").read_text(encoding="utf-8")
DEPOSITS = (ROOT / "Code/sbm_deposits.lua").read_text(encoding="utf-8")

required = [
    "local DiagnosticHeartbeat = {}",
    "function SuperBigMap.InstallDiagnosticPhaseHeartbeatSink(sink, surface, expected_descriptor,",
    "function DiagnosticHeartbeat.Emit(sink, map, phase, edge, fields, write_capability, clock_capability)",
    'emitter(surface, "diagnostic-heartbeat-handshake", "BEFORE"',
    'emitter(surface, "diagnostic-heartbeat-handshake", "AFTER"',
    "State.lazy_diagnostic_heartbeat_emitter = emitter",
    "State.lazy_diagnostic_heartbeat_authorize = function(candidate)",
    "State.lazy_diagnostic_heartbeat_required = true",
    '"lazy-wrapper-materialize-call", "BEFORE"',
    'lazy.Materialize(\n\t\t\t\t\t\tlazy_surface, "change-current-map-slot", heartbeat)',
    "function Lazy.Materialize(surface, route, diagnostic_heartbeat)",
    '"lazy-materialize-entry", "BEFORE"',
    "diagnostic_heartbeat = diagnostic_heartbeat,",
    "local heartbeat = type(expected_owner) == \"table\" and expected_owner.diagnostic_heartbeat",
    'heartbeat(surface, "lazy-native-GenerateRandomMap", "BEFORE"',
    'heartbeat(callback_map or surface,\n\t\t"lazy-native-GenerateRandomMap"',
    "diagnostic_heartbeat = expected_owner.diagnostic_heartbeat,",
    "local phase_heartbeat = capability_context and capability_context.diagnostic_heartbeat",
]
missing = [token for token in required if token not in MAP]
if missing:
    raise SystemExit("missing heartbeat capability tokens: " + repr(missing))

phase_start = MAP.index("function SuperBigMap.DiagnosticPhaseHeartbeat")
phase_end = MAP.index("local function PointXY", phase_start)
phase_block = MAP[phase_start:phase_end]
if 'rawget(_G, "g_SmrRalphDiagnosticFailureSink")' in phase_block:
    raise SystemExit("heartbeat still trusts the debugger/mod-environment ambiguous global")
if "AsyncRand" in phase_block:
    raise SystemExit("heartbeat capability consumes RNG")

publish_start = MAP.index("function Lazy.PublishDiagnosticTerminalFailure")
publish_end = MAP.index("function Lazy.MarkBlocked", publish_start)
if "local sink = DiagnosticHeartbeat.sink" not in MAP[publish_start:publish_end]:
    raise SystemExit("terminal publisher does not use the private closure sink")

if "options.diagnostic_heartbeat or SuperBigMap.DiagnosticPhaseHeartbeat" not in TERRAIN:
    raise SystemExit("terrain pair preparation did not receive the explicit emitter")
if "type(options) == \"table\" and options.diagnostic_heartbeat" not in DEPOSITS:
    raise SystemExit("relocation did not receive the explicit emitter")

print("ok=true")
print("sink_owner=mod-environment-private-closure")
print("handshake_records=2")
print("wrapper_explicit_pass=true")
print("native_boundary_paired=true")
print("pipeline_explicit_pass=true")
print("terrain_relocation_explicit_pass=true")
print("debugger_global_dependency=0")
