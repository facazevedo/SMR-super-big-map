#!/usr/bin/env python3
"""Fail-closed static contract for v987 underground post-access correctness."""

from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[2]


def require(text: str, token: str, label: str) -> None:
    if token not in text:
        raise SystemExit(f"missing {label}: {token}")


def main() -> None:
    generation = (ROOT / "Code/sbm_map_generation.lua").read_text(encoding="utf-8")
    terrain = (ROOT / "Code/sbm_terrain_copy.lua").read_text(encoding="utf-8")
    deposits = (ROOT / "Code/sbm_deposits.lua").read_text(encoding="utf-8")
    rocket = (ROOT / "Code/sbm_rocket_rules.lua").read_text(encoding="utf-8")
    metadata = (ROOT / "metadata.lua").read_text(encoding="utf-8")
    version = (ROOT / "Code/sbm_version.lua").read_text(encoding="utf-8")

    require(rocket, "LANDING_FLATTEN_PATCH_VERSION = 3", "flatten wrapper patch bump")
    require(rocket, "State.passage_pad_preparation_depth", "process-local flatten owner")
    require(rocket, "and not passage_pad_preparation", "ambient Elevator flatten guard")
    require(terrain, "state.passage_pad_preparation_depth = previous_depth + 1",
            "owned flatten begin")
    require(terrain, "previous_depth > 0 and previous_depth or nil", "owned flatten cleanup")
    require(terrain, "SuperBigMapUndergroundPassagePreparationDebug", "persisted pad debug")
    require(terrain, 'maximum_pairs = 2', "pad debug bound")
    require(terrain, 'stage = "before"', "pad before capture")
    require(terrain, 'stage = "after"', "pad after capture")
    require(terrain, '",tz" .. terrain_z_text', "exact terrain-Z capture")
    require(terrain, '",nz" .. normal_text', "exact slope capture")

    require(deposits, "SuperBigMapUndergroundEnrichmentRelocationDebug",
            "persisted relocation debug")
    require(deposits, "MAX_INVALID_MARKERS = 8", "relocation marker bound")
    require(deposits, "MAX_COMMIT_ATTEMPTS_PER_MARKER = 64", "relocation attempt bound")
    require(deposits, "describe_candidate_neighborhood", "bounded neighborhood reasons")
    require(deposits, "local actual_exact = actual_pos and ax == nx and ay == ny",
            "exact post-move coordinate")
    require(deposits, "CanReceiveDepositTerrain(map, actual_pos, validation_context) == true",
            "post-move terrain certificate")
    precheck = deposits.find("CanReceiveDeposit(map, new_pos, validation_context)")
    setpos = deposits.find("pcall(marker.SetPos, marker, new_pos)", precheck)
    certificate = deposits.find("local actual_exact", setpos)
    if min(precheck, setpos, certificate) < 0 or not precheck < setpos < certificate:
        raise SystemExit("relocation precheck/SetPos/certificate order drifted")

    require(generation, "map.SuperBigMapUndergroundPassagePairOK = pair_ok == true",
            "pair result publication")
    require(generation, "map.SuperBigMapUndergroundEnrichmentReachabilityOK = audit_ok == true",
            "enrichment result publication")
    require(generation, 'return false, "final passage-pair alignment failed: "',
            "explicit pair false return")
    require(generation, 'return false, "underground enrichment reachability audit left "',
            "explicit enrichment false return")
    require(generation, "if branch_result == false then", "pcall false normalization")
    require(generation, "descriptor.materialization_passage_pair_ok", "descriptor pair evidence")
    require(generation, "descriptor.materialization_enrichment_reachability_ok",
            "descriptor enrichment evidence")
    require(generation, "passage_pad_z_certificate_exact",
            "lazy passage target-Z completion certificate")
    require(generation,
            "deferred underground completion omitted the exact passage-pad target-Z certificate",
            "missing target-Z certificate rejection")
    if re.search(r'if pair_ok ~= true then\s+error\(', generation):
        raise SystemExit("pair false path still relies on error()")
    if re.search(r'if audit_ok ~= true then\s+error\(', generation):
        raise SystemExit("enrichment false path still relies on error()")
    require(metadata, "'version', 993", "metadata v993")
    require(version, "GENERATOR_PATCH_VERSION = 299", "generator patch 299")

    print("ok=true")
    print("version=993")
    print("explicit_false_boundaries=2")
    print("persisted_debug_channels=2")
    print("relocation_order=precheck>SetPos>exact-terrain-certificate")


if __name__ == "__main__":
    main()
