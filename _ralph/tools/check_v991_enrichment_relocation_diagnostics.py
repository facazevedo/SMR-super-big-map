#!/usr/bin/env python3
"""Static fail-closed contract for v991 relocation and post-T1 diagnostics."""

from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[2]
DEPOSITS = (ROOT / "Code/sbm_deposits.lua").read_text(encoding="utf-8")
GENERATION = (ROOT / "Code/sbm_map_generation.lua").read_text(encoding="utf-8")
SESSION = (ROOT / "_ralph/tools/v991_post_t1_diagnostic_session.lua").read_text(encoding="utf-8")
ANALYZER = (ROOT / "_ralph/tools/analyze_v991_terminal_bundle.py").read_text(encoding="utf-8")
VERSION = (ROOT / "Code/sbm_version.lua").read_text(encoding="utf-8")
META = (ROOT / "metadata.lua").read_text(encoding="utf-8")

required_deposits = [
    "schema = 2", "maximum_candidate_corpus = 256", "candidate_corpus_digest",
    "live_before_hash", "live_after_hash", "neighbourhood_samples",
    "if invalid_i > relocation_debug.maximum_markers", "if #candidates >= 2048 then break end",
    "local fallback_buckets = {}", "for oq = -1, 1 do", "fallback_minimum_hex",
    "local viable_candidates = {}", "remove_committed_candidate(successful_source_candidate)",
    "marker.SuperBigMapUndergroundFallbackSpacingRelaxed = nil",
    'note_relocation_rejection("repulsion"', 'note_relocation_rejection("fallback_minimum"',
]
missing = [token for token in required_deposits if token not in DEPOSITS]
assert not missing, "missing v991 relocation contract: " + ", ".join(missing)
success = DEPOSITS.index("if success then", DEPOSITS.index("local viable_candidates = {}"))
remove = DEPOSITS.index("remove_committed_candidate(successful_source_candidate)", success)
unresolved = DEPOSITS.index("unresolved = unresolved + 1", remove)
assert success < remove < unresolved
assert "local function take_near" not in DEPOSITS
assert "fallback_clearance_entries) do" not in DEPOSITS[DEPOSITS.index("local function fallback_clearance_hex"):DEPOSITS.index("local function update_fallback_clearance_entry")]

required_generation = [
    "function Lazy.PublishDiagnosticTerminalFailure(surface, reason)",
    'schema ~= "smr.ralph.lazy-terminal-failure-sink.v1"',
    "sink.diagnostic_only ~= true", "sink.acceptance_timing_eligible ~= false",
    '"schema=smr.sbm.lazy-terminal-causal-bundle.v1"',
    '"live_before_hash="', '"live_after_hash="',
    '"private_clone_before_hash=not-run-production"',
    "protected_write(write, sink.bundle_path, payload)",
    "protected_write(write, sink.sentinel_path, sentinel)",
    "Lazy.PublishDiagnosticTerminalFailure(surface, reason)",
]
missing = [token for token in required_generation if token not in GENERATION]
assert not missing, "missing v991 terminal contract: " + ", ".join(missing)
bundle_write = GENERATION.index("protected_write(write, sink.bundle_path, payload)")
sentinel_write = GENERATION.index("protected_write(write, sink.sentinel_path, sentinel)")
assert bundle_write < sentinel_write

for forbidden in ("ChangeCurrentMapSlot", "SetPos", "AsyncRand", "Lazy.Materialize",
                  "ReleasePostT1", "g_SmrRalphRelease"):
    assert forbidden not in SESSION, f"diagnostic session contains forbidden capability: {forbidden}"
for token in ("deadline_ms > 300000", 'command.name == "cleanup"',
              'command.name ~= "enrichment-relocation-private-simulation"',
              "live_after ~= live_before", "acceptance_timing_eligible=false",
              'rawset(_G, "g_SmrRalphDiagnosticCommand", nil)'):
    assert token in SESSION
for token in ("duplicate key", "bundle byte receipt mismatch", "root_cause_candidates",
              "diagnostics complete but root cause is unknown", "raw_bounded_fields"):
    assert token in ANALYZER

assert "SuperBigMap.GENERATOR_PATCH_VERSION = 297" in VERSION
assert re.search(r"'version',\s*991\b", META)
print("ok=true")
print("candidate_consumption=commit-only")
print("fallback_clearance_index=bounded-exact")
print("terminal_publication=bundle-before-sentinel")
print("diagnostic_session=post-t1-non-promoting-read-only-private-clone")
print("unknown_or_incomplete_diagnostics=fail-closed")
