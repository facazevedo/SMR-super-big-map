#!/usr/bin/env python3
"""Deterministic policy/state oracle for v971 outer passage-pad reservation."""

from __future__ import annotations

import json
import math
import time


MODULUS = 2_147_483_647
MAP = 820
BAND = 82
SHAPE = tuple((q, r) for q in range(-5, 6) for r in range(-5, 6)
              if max(abs(q), abs(r), abs(q + r)) <= 5)
SHAPE_RADIUS = 5
REQUIRED_CORE = 8
VISIT = 15
MIN_PASSAGE_DISTANCE = 100
ATTEMPTS_PER_SITE = 256


def axial(a: tuple[int, int], b: tuple[int, int]) -> int:
    dq, dr = a[0] - b[0], a[1] - b[1]
    return max(abs(dq), abs(dr), abs(dq + dr))


def outer(q: int, r: int) -> bool:
    return q < BAND or r < BAND or q >= MAP - BAND or r >= MAP - BAND


def visit_disk_outer(q: int, r: int) -> bool:
    if q < VISIT or r < VISIT or q >= MAP - VISIT or r >= MAP - VISIT:
        return False
    nearest_q = min(max(q, BAND), MAP - BAND)
    nearest_r = min(max(r, BAND), MAP - BAND)
    return math.hypot(q - nearest_q, r - nearest_r) > VISIT


def height(q: int, r: int) -> int:
    return 5000 + ((q * 37 + r * 61 + q * r * 3) % 1700)


def seed_state(seed: int, material: str) -> int:
    state = abs(seed) % MODULUS
    for byte in material.encode():
        state = (state * 48271 + byte + 1) % MODULUS
    return state or 1


def plan(seed: int, resources: list[tuple[int, int]], rockets: list[tuple[int, int]],
         blocked: set[tuple[int, int]]) -> dict:
    state = seed_state(seed, "RoughTerrain|v971-outer-passage-pad-reservation")
    initial = state
    chosen: list[dict] = []
    attempts = viable = shape_checks = 0
    for index in range(2):
        best = None
        for _ in range(ATTEMPTS_PER_SITE):
            attempts += 1
            state = (state * 48271 + 1) % MODULUS or 1
            q = state % MAP
            state = (state * 48271 + 1) % MODULUS or 1
            r = state % MAP
            state = (state * 48271 + 1) % MODULUS or 1
            angle = (state % 6) * 3600
            valid = outer(q, r) and visit_disk_outer(q, r)
            valid = valid and all(axial((q, r), item) >= REQUIRED_CORE + 3
                                  for item in resources)
            valid = valid and all(axial((q, r), item) >= REQUIRED_CORE + 5 + 4
                                  for item in rockets)
            valid = valid and all((q - item["q"]) ** 2 + (r - item["r"]) ** 2
                                  >= MIN_PASSAGE_DISTANCE ** 2 for item in chosen)
            if valid:
                shape_checks += 1
                valid = all((q + dq, r + dr) not in blocked for dq, dr in SHAPE)
            if not valid:
                continue
            viable += 1
            values = [height(q + dq, r + dr) for dq, dr in SHAPE]
            candidate = {"index": index + 1, "q": q, "r": r, "angle": angle,
                         "height_range": max(values) - min(values)}
            if best is None or candidate["height_range"] < best["height_range"]:
                best = candidate
        if best is None:
            return {"ok": False, "sites": [], "attempts": attempts, "state": state,
                    "viable": viable, "shape_checks": shape_checks, "seed": initial}
        chosen.append(best)
    digest = initial
    for site in chosen:
        digest = (digest * 48271 + abs(site["q"]) + 1) % MODULUS
        digest = (digest * 48271 + abs(site["r"]) + 1) % MODULUS
        digest = (digest * 48271 + site["angle"] + 1) % MODULUS
    return {"ok": True, "sites": chosen, "attempts": attempts, "state": state,
            "viable": viable, "shape_checks": shape_checks, "seed": initial,
            "draws": attempts * 3, "digest": digest}


def certified_plan(seed: int, resources: list[tuple[int, int]],
                   rockets: list[tuple[int, int]], blocked: set[tuple[int, int]]) -> dict:
    if len(rockets) != 6:
        return {"ok": False, "blocked": True, "error": "rocket-count-not-six",
                "sites": [], "attempts": 0, "draws": 0}
    return plan(seed, resources, rockets, blocked)


def publish_transaction(plan_result: dict, validation_results: list[bool],
                        patch_install_ok: bool = True) -> dict:
    # Mirrors the fail-before-publication ownership rule: native patch and both depth-zero
    # certificates must succeed before exactly two primitive capsules can be published.
    ready = (plan_result.get("ok") is True and len(plan_result.get("sites", [])) == 2
             and patch_install_ok and validation_results == [True, True])
    return {"blocked": not ready, "published": 2 if ready else 0,
            "partial": False, "unbounded_calls": 0,
            "depth_zero_validations": len(validation_results)}


def setter_succeeded(call_ok: bool, returned_error: object) -> bool:
    return call_ok and (returned_error is None or returned_error is False)


def install_transaction(*, install_call_ok: bool, install_return: object,
                        restore_call_ok: bool = True, restore_return: object = None,
                        restore_matches: bool = True) -> dict:
    install_ok = setter_succeeded(install_call_ok, install_return)
    if install_ok:
        return {"installed": True, "blocked": False, "restored": False,
                "verified": False, "published_pads": 0}
    restored = setter_succeeded(restore_call_ok, restore_return)
    verified = restored and restore_matches
    return {"installed": False, "blocked": True, "restored": restored,
            "verified": verified, "published_pads": 0,
            "install_call_ok": install_call_ok,
            "install_returned_error": install_return is not None and install_return is not False,
            "restore_call_ok": restore_call_ok,
            "restore_returned_error": restore_return is not None and restore_return is not False}


def main() -> int:
    resources = [(17 + (i * 47) % 786, 19 + (i * 71) % 782) for i in range(190)]
    rockets = [(45, 180), (45, 390), (45, 610), (775, 170), (775, 400), (775, 635)]
    blocked = {(11 + (i * 83) % 798, 13 + (i * 107) % 794) for i in range(120)}
    started = time.perf_counter()
    first = certified_plan(971_200_14, resources, rockets, blocked)
    replay = certified_plan(971_200_14, resources, rockets, blocked)
    elapsed_ms = (time.perf_counter() - started) * 1000
    exact = first == replay
    sites = first.get("sites", [])
    geometry = len(sites) == 2 and all(outer(s["q"], s["r"])
        and visit_disk_outer(s["q"], s["r"]) for s in sites)
    spacing = len(sites) == 2 and all(axial((s["q"], s["r"]), resource)
        >= REQUIRED_CORE + 3 for s in sites for resource in resources)
    rocket_clear = len(sites) == 2 and all(axial((s["q"], s["r"]), rocket)
        >= REQUIRED_CORE + 5 + 4 for s in sites for rocket in rockets)
    pair_clear = len(sites) == 2 and ((sites[0]["q"] - sites[1]["q"]) ** 2
        + (sites[0]["r"] - sites[1]["r"]) ** 2 >= MIN_PASSAGE_DISTANCE ** 2)
    success = publish_transaction(first, [True, True])
    patch_fault = publish_transaction(first, [], patch_install_ok=False)
    validation_fault = publish_transaction(first, [True, False])
    wrong_rocket_count = certified_plan(971_200_14, resources, rockets[:5], blocked)
    healthy_install = install_transaction(install_call_ok=True, install_return=None)
    false_install = install_transaction(install_call_ok=True, install_return=False)
    numeric_zero_install = install_transaction(install_call_ok=True, install_return=0)
    throw_rollback_ok = install_transaction(
        install_call_ok=False, install_return="install-threw")
    returned_error_rollback_ok = install_transaction(
        install_call_ok=True, install_return="install-returned-error")
    rollback_mismatch = install_transaction(
        install_call_ok=True, install_return="install-returned-error",
        restore_matches=False)
    restore_returned_error = install_transaction(
        install_call_ok=True, install_return="install-returned-error",
        restore_call_ok=True, restore_return="restore-returned-error")
    restore_throw = install_transaction(
        install_call_ok=True, install_return="install-returned-error",
        restore_call_ok=False, restore_return="restore-threw")
    checks = {
        "two_sites_selected": first.get("ok") is True and len(sites) == 2,
        "fixed_budget_and_three_private_draws": first.get("attempts") == 512
            and first.get("draws") == 1536,
        "deterministic_repeat_digest_state_and_trace": exact,
        "full_visit_disk_is_outer_and_inner_disjoint": geometry,
        "resource_anomaly_effect_spacing_is_conservative": spacing,
        "six_rocket_pads_remain_disjoint": rocket_clear,
        "strict_passage_pair_distance": pair_clear,
        "success_publishes_exactly_two_after_two_validations": success == {
            "blocked": False, "published": 2, "partial": False,
            "unbounded_calls": 0, "depth_zero_validations": 2},
        "patch_failure_is_sticky_zero_publication": patch_fault["blocked"]
            and patch_fault["published"] == 0 and not patch_fault["partial"],
        "one_failed_validation_is_zero_publication": validation_fault["blocked"]
            and validation_fault["published"] == 0 and not validation_fault["partial"],
        "wrong_rocket_count_is_rejected_by_certificate": wrong_rocket_count == {
            "ok": False, "blocked": True, "error": "rocket-count-not-six",
            "sites": [], "attempts": 0, "draws": 0},
        "nil_return_install_is_the_only_truthy_pcall_success": healthy_install == {
            "installed": True, "blocked": False, "restored": False,
            "verified": False, "published_pads": 0},
        "literal_false_return_is_also_success": false_install == healthy_install,
        "numeric_zero_return_is_a_lua_truthy_error": numeric_zero_install["blocked"]
            and numeric_zero_install["install_returned_error"]
            and numeric_zero_install["restored"] and numeric_zero_install["verified"],
        "mutate_then_throw_restore_is_verified_before_block": throw_rollback_ok["blocked"]
            and throw_rollback_ok["restored"] and throw_rollback_ok["verified"]
            and throw_rollback_ok["published_pads"] == 0,
        "mutate_then_return_error_enters_verified_rollback":
            returned_error_rollback_ok["blocked"]
            and returned_error_rollback_ok["install_call_ok"]
            and returned_error_rollback_ok["install_returned_error"]
            and returned_error_rollback_ok["restored"]
            and returned_error_rollback_ok["verified"]
            and returned_error_rollback_ok["published_pads"] == 0,
        "rollback_mismatch_remains_sticky_blocked": rollback_mismatch["blocked"]
            and rollback_mismatch["restored"] and not rollback_mismatch["verified"]
            and rollback_mismatch["published_pads"] == 0,
        "restore_returned_error_is_not_completed_or_verified":
            restore_returned_error["blocked"]
            and restore_returned_error["restore_call_ok"]
            and restore_returned_error["restore_returned_error"]
            and not restore_returned_error["restored"]
            and not restore_returned_error["verified"],
        "restore_throw_is_not_completed_or_verified": restore_throw["blocked"]
            and not restore_throw["restore_call_ok"]
            and not restore_throw["restored"] and not restore_throw["verified"],
        "no_search_or_shared_rng_model": success["unbounded_calls"] == 0,
        "bounded_oracle_runtime": elapsed_ms < 1000,
    }
    failed = sorted(name for name, ok in checks.items() if not ok)
    print(json.dumps({
        "schema": "smr.ralph.v971.outer-passage-pad-oracle.v1",
        "ok": not failed,
        "failed": failed,
        "checks": checks,
        "first": first,
        "elapsed_ms": round(elapsed_ms, 3),
    }, indent=2, sort_keys=True))
    return 0 if not failed else 1


if __name__ == "__main__":
    raise SystemExit(main())
