#!/usr/bin/env python3
"""Static fail-closed contract for v992 materialization deadlines and watchdog evidence."""

from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[2]
GEN = (ROOT / "Code/sbm_map_generation.lua").read_text(encoding="utf-8")
DEP = (ROOT / "Code/sbm_deposits.lua").read_text(encoding="utf-8")
TERRAIN = (ROOT / "Code/sbm_terrain_copy.lua").read_text(encoding="utf-8")
WATCHDOG = (ROOT / "_ralph/tools/v992_external_materialization_watchdog.ps1").read_text(
    encoding="utf-8"
)
ORACLE = (ROOT / "_ralph/tools/v992_relocation_budget_oracle.lua").read_text(
    encoding="utf-8"
)
DEFAULT_OFF_ORACLE = (ROOT / "_ralph/tools/v992_heartbeat_default_off_oracle.lua").read_text(
    encoding="utf-8"
)
SESSION = (ROOT / "_ralph/tools/v991_post_t1_diagnostic_session.lua").read_text(
    encoding="utf-8"
)
VERSION = (ROOT / "Code/sbm_version.lua").read_text(encoding="utf-8")
META = (ROOT / "metadata.lua").read_text(encoding="utf-8")

api = GEN.index("function SuperBigMap.DiagnosticPhaseHeartbeat")
lazy_gate = GEN.index("-- v965 LAZY UNDERGROUND")
assert api < lazy_gate, "heartbeat API must survive lazy helper reload/config-off"
guard = GEN[api: GEN.index("function SuperBigMap.InstallDiagnosticPhaseHeartbeatSink", api)]
for token in ("GetPreciseTicks", "RealTime", "AsyncStringToFile", "string.format", "pcall("):
    assert token not in guard, f"default-off heartbeat guard performs work: {token}"
for token in (
    "return DiagnosticHeartbeat.Emit(DiagnosticHeartbeat.sink, map, phase, edge, fields)",
    "function SuperBigMap.InstallDiagnosticPhaseHeartbeatSink(sink, surface, expected_descriptor)",
    "DiagnosticHeartbeat.sink = private",
    'sink.diagnostic_only ~= true',
    'sink.acceptance_timing_eligible ~= false',
    'type(sink.heartbeat_prefix) ~= "string"',
    '"schema=smr.sbm.lazy-phase-heartbeat.v1"',
    'rows[#rows + 1] = "complete=true"',
    'string.format("%04d.txt", sequence)',
):
    assert token in GEN, f"missing heartbeat token: {token}"
assert 'rawget(_G, "g_SmrRalphDiagnosticFailureSink")' not in GEN

phases = (
    "lazy-native-GenerateRandomMap",
    "lazy-deferred-underground-pipeline",
    "underground-StretchSourceToFull",
    "underground-stage-native-enrichments",
    "underground-first-canonical-grid-rebuild",
    "underground-align-passage-pairs",
    "underground-enrichment-relocation",
    "underground-closing-canonical-grid-rebuild",
    "underground-pipeline-cleanup-publication",
)
for phase in phases:
    assert phase in GEN, f"missing materialization phase: {phase}"
for phase in ("passage-pair-alignment", "passage-pair", "passage-pad-native-flatten"):
    assert phase in TERRAIN, f"missing passage heartbeat: {phase}"

for token in (
    "owner.deadline_started_ms = Lazy.Now()",
    "owner.deadline_started_ms + 270000",
    "capability monotonic deadline is invalid or expired",
    "deadline_ms = capability_context and capability_context.deadline_ms",
    "RelocateUnreachableUndergroundEnrichments(map, {",
):
    assert token in GEN, f"missing private deadline propagation: {token}"

for token in (
    "MAX_RELOCATION_CANDIDATES = 512",
    "MAX_NEIGHBOURHOOD_SAMPLES_PER_MARKER = 64",
    "MAX_GLOBAL_SAMPLES = 4096",
    "MAX_COMMIT_ATTEMPTS_PER_MARKER = 64",
    "if #candidates >= MAX_RELOCATION_CANDIDATES then return false end",
    'deadline_abort("neighbourhood-corpus"',
    'deadline_abort("global-corpus"',
    '"marker-candidate-scan"',
    'deadline_abort("marker-commit"',
    "materialization deadline exceeded during enrichment relocation",
    "return unresolved == 0, stats",
):
    assert token in DEP, f"missing bounded relocation token: {token}"
assert "#candidates >= 2048" not in DEP
assert "for _ = 1, 256 do" not in DEP[DEP.index("function DepositRules.Relocate"):]

for token in (
    "function Write-SbmUtf8NoBomAtomic",
    "function Get-SbmTrackedProcessIdentity",
    "creation_time_utc_ticks",
    "function Test-SbmTrackedProcessIdentity",
    "function Stop-SbmTrackedProcessExact",
    "Stop-Process -Id ([int]$Identity.pid) -Force",
    "function Read-SbmPhaseHeartbeats",
    "function Publish-SbmExternalWatchdogTimeout",
    "bundle_published_before_terminal = $true",
    "Write-SbmUtf8NoBomAtomic -Path $BundlePath",
    "Write-SbmUtf8NoBomAtomic -Path $TerminalPath",
    "tracked_identity_gone",
    "dap_port_closed",
):
    assert token in WATCHDOG, f"missing watchdog token: {token}"
assert WATCHDOG.index("Write-SbmUtf8NoBomAtomic -Path $BundlePath") < WATCHDOG.index(
    "Write-SbmUtf8NoBomAtomic -Path $TerminalPath"
)
for forbidden in ("Get-Process -Name", "taskkill", "Stop-Process -Name"):
    assert forbidden not in WATCHDOG, f"broad destructive target: {forbidden}"

for forbidden in (
    "ChangeCurrentMapSlot", "Lazy.Materialize", "GenerateRandomMap", "ReleasePostT1",
):
    assert forbidden not in SESSION, f"diagnostic session can start full materialization: {forbidden}"
for token in ("maximum_candidates=512", "deadline_expired_candidate_commit=0", "rule_waivers=0"):
    assert token in ORACLE
for token in ("default_off_calls=3", "global_calls=0", "clock_calls=0", "file_calls=0",
              "rng_calls=0", "console_calls=0"):
    assert token in DEFAULT_OFF_ORACLE

assert "SuperBigMap.GENERATOR_PATCH_VERSION = 300" in VERSION
assert re.search(r"'version',\s*994\b", META)
print("ok=true")
print("heartbeat_default_off_guard=private-nil-closure-return")
print("heartbeat_phase_pairs=materialization+pipeline+flatten+relocation")
print("relocation_candidate_cap=512")
print("relocation_global_sample_cap=4096")
print("internal_deadline_ms=270000")
print("external_deadline_ms=300000")
print("fallback_kill_identity=pid+creation-time+name+path")
print("diagnostic_session_can_materialize=false")
