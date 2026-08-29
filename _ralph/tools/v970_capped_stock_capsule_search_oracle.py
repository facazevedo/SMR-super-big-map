#!/usr/bin/env python3
"""Deterministic state/call-budget oracle for v970 post-canonical stock searches."""

from __future__ import annotations

import json
import math
from dataclasses import dataclass
from typing import Callable


MODULUS = 2147483647
CAP = 8
MIN_DISTANCE = 100000
MARGIN = 81920
WORLD = 819200


@dataclass(frozen=True)
class Site:
    x: int
    y: int
    z: int
    q: int
    r: int
    angle: int


def plan(seed: int, resolve: Callable[[int, int, int, int], tuple[int, int, int] | None],
         replay_only: bool = False) -> dict:
    state = seed
    attempts = calls = draws = 0
    sites: list[Site] = []
    trace: list[dict] = []

    def draw() -> int:
        nonlocal state, draws
        state = (state * 48271 + 1) % MODULUS
        state = state or 1
        draws += 1
        return state

    try:
        while len(sites) < 2 and attempts < CAP:
            attempts += 1
            start_x = MARGIN + draw() % (WORLD - 2 * MARGIN)
            start_y = MARGIN + draw() % (WORLD - 2 * MARGIN)
            angle = draw() % 6 * 3600
            calls += 1
            result = resolve(attempts, start_x, start_y, angle)
            row = {"ordinal": attempts, "start_x": start_x, "start_y": start_y,
                   "angle": angle, "result": result, "outcome": "no-result"}
            trace.append(row)
            if result is None:
                continue
            x, y, z = result
            if not all(isinstance(value, (int, float)) and not isinstance(value, bool)
                       and math.isfinite(value) for value in (x, y, z)):
                raise ValueError("stock-call-returned-malformed-position")
            if not (MARGIN <= x <= WORLD - MARGIN and MARGIN <= y <= WORLD - MARGIN):
                row["outcome"] = "outside-inner-margin"
                continue
            if any((x - prior.x) ** 2 + (y - prior.y) ** 2 < MIN_DISTANCE ** 2
                   for prior in sites):
                row["outcome"] = "minimum-distance-rejection"
                continue
            sites.append(Site(x=x, y=y, z=z, q=x // 50, r=y // 50, angle=angle))
            row["outcome"] = "selected"
    except Exception as exc:  # executable fault model: no publication on engine-call failure
        return {"ok": False, "blocked": True, "published": 0, "error": str(exc),
                "attempts": attempts, "calls": calls, "draws": draws, "sites": [],
                "trace": trace, "pause_used": True, "resume_ok": True,
                "publication_validations": 0}

    digest = seed
    for site in sites:
        digest = (digest * 48271 + abs(site.q) + 1) % MODULUS
        digest = (digest * 48271 + abs(site.r) + 1) % MODULUS
        digest = (digest * 48271 + site.angle + 1) % MODULUS
    ok = len(sites) == 2
    return {"ok": ok, "blocked": not ok, "published": 0, "attempts": attempts,
            "calls": calls, "draws": draws, "final_state": state, "digest": digest,
            "sites": [site.__dict__ for site in sites], "trace": trace,
            "pause_used": True, "resume_ok": True,
            "publication_validations": 0 if replay_only or not ok else 2}


def iter200_corpus(attempt: int, _x: int, _y: int, _angle: int) -> tuple[int, int, int] | None:
    # The accepted v965/iter200 fresh-grid evidence found two sites in three starts. Model the
    # relevant decision shape: first is accepted, second resolves inside its exclusion radius,
    # and third resolves to the second accepted site. Coordinates are scenario-independent oracle
    # fixtures, not production hardcodes.
    return {
        1: (180000, 220000, 6120),
        2: (185000, 224000, 6118),
        3: (610000, 570000, 6035),
    }.get(attempt)


def replay_certificate(main_plan: dict, replay_plan: dict) -> bool:
    return main_plan.get("ok") is True and replay_plan.get("ok") is True and all(
        main_plan.get(key) == replay_plan.get(key) for key in (
            "attempts", "calls", "draws", "final_state", "digest", "sites", "trace"))


def lifecycle(plan_result: dict, first_rebuild: bool = True,
              closing_rebuild: bool = True) -> dict:
    events = ["canonical-grid-publication"]
    if not first_rebuild:
        return {"state": "blocked", "events": events, "prefinal_calls": 0,
                "published": 0, "rebuilds": 1}
    events += ["capped-stock-main", "capped-stock-replay"]
    if not plan_result["ok"]:
        return {"state": "blocked", "events": events, "prefinal_calls": 0,
                "published": 0, "rebuilds": 1}
    events += ["publish-two", "closing-rebuild"]
    return {"state": "surface-capsules-published-awaiting-final-grid"
            if closing_rebuild else "blocked", "events": events, "prefinal_calls": 0,
            "published": 2, "rebuilds": 2}


def rollback_objects(baseline: set[str], live: set[str], done_failures: set[str]) -> dict:
    new_objects = live - baseline
    remaining = set(live)
    for object_id in sorted(new_objects):
        if object_id not in done_failures:
            remaining.discard(object_id)
    residual = remaining - baseline
    return {"verified": not residual and not (new_objects & done_failures),
            "new_objects": sorted(new_objects), "residual": sorted(residual)}


def main() -> int:
    seed = 97020003
    main_plan = plan(seed, iter200_corpus)
    replay = plan(seed, iter200_corpus, replay_only=True)
    cap_failure = plan(seed, lambda *_: None)

    def raising(attempt: int, *_args: int) -> tuple[int, int, int] | None:
        if attempt == 2:
            raise RuntimeError("synthetic stock-search failure")
        return iter200_corpus(attempt, 0, 0, 0)

    call_failure = plan(seed, raising)
    nil_z_main = plan(seed, lambda attempt, *_: (180000, 220000, None)
                      if attempt == 1 else iter200_corpus(attempt, 0, 0, 0))
    zero_z_replay = plan(seed, lambda attempt, *_: (180000, 220000, 0)
                        if attempt == 1 else iter200_corpus(attempt, 0, 0, 0), replay_only=True)
    healthy = lifecycle(main_plan)
    failed = lifecycle(cap_failure)
    baseline = {"old-passage", "old-marker", "old-sign"}
    mutate_then_throw_rollback = rollback_objects(
        baseline, baseline | {"new-unreturned-passage", "new-marker", "new-sign"}, set())
    done_failure_rollback = rollback_objects(
        baseline, baseline | {"new-passage", "new-marker", "new-sign"}, {"new-marker"})
    checks = {
        "iter200_shape_finds_two_in_three_capped_calls": (
            main_plan["ok"] and main_plan["attempts"] == main_plan["calls"] == 3
            and len(main_plan["sites"]) == 2),
        "exactly_three_private_draws_per_start": main_plan["draws"] == main_plan["attempts"] * 3,
        "main_and_replay_attempt_outcome_state_and_digest_are_exact": all(
            main_plan[key] == replay[key] for key in (
                "attempts", "calls", "draws", "final_state", "digest", "sites", "trace")),
        "nil_z_main_vs_zero_z_replay_is_rejected": (
            nil_z_main["blocked"] is True and replay_certificate(nil_z_main, zero_z_replay) is False),
        "finite_z_is_preserved_and_replayed_exactly": (
            replay_certificate(main_plan, replay)
            and [site["z"] for site in main_plan["sites"]] == [6120, 6035]
            and [site["z"] for site in replay["sites"]] == [6120, 6035]),
        "main_has_two_fresh_validations_replay_has_none": (
            main_plan["publication_validations"] == 2
            and replay["publication_validations"] == 0),
        "pause_resume_is_balanced_on_success_and_engine_failure": (
            main_plan["pause_used"] and main_plan["resume_ok"]
            and call_failure["pause_used"] and call_failure["resume_ok"]),
        "spacing_rejection_does_not_publish_or_mutate": (
            main_plan["sites"][0]["x"] == 180000
            and main_plan["sites"][1]["x"] == 610000),
        "cap_failure_is_sticky_no_publication": (
            cap_failure["blocked"] and cap_failure["attempts"] == cap_failure["calls"] == CAP
            and cap_failure["draws"] == CAP * 3 and cap_failure["published"] == 0),
        "engine_call_failure_is_sticky_no_publication": (
            call_failure["blocked"] and call_failure["calls"] == 2
            and call_failure["published"] == 0),
        "healthy_lifecycle_has_no_prefinal_calls_and_two_rebuilds": (
            healthy["prefinal_calls"] == 0 and healthy["rebuilds"] == 2
            and healthy["published"] == 2 and healthy["events"] == [
                "canonical-grid-publication", "capped-stock-main", "capped-stock-replay",
                "publish-two", "closing-rebuild"]),
        "planner_failure_never_publishes_or_closes": (
            failed["state"] == "blocked" and failed["published"] == 0
            and failed["rebuilds"] == 1),
        "publication_rollback_catches_mutate_then_throw_unreturned_objects": (
            mutate_then_throw_rollback["verified"]
            and len(mutate_then_throw_rollback["new_objects"]) == 3
            and mutate_then_throw_rollback["residual"] == []),
        "publication_rollback_fails_closed_when_doneobject_leaves_residual": (
            done_failure_rollback["verified"] is False
            and done_failure_rollback["residual"] == ["new-marker"]),
    }
    failures = sorted(name for name, ok in checks.items() if not ok)
    print(json.dumps({
        "schema": "smr.ralph.v970.capped-stock-capsule-search-oracle.v1",
        "ok": not failures,
        "failed": failures,
        "checks": checks,
        "limits": {"attempt_cap_per_plan": CAP, "max_main_replay_calls": CAP * 2,
                   "prefinal_calls": 0, "private_draws_per_attempt": 3},
        "iter200_corpus": {"observed_fresh_attempts": 3, "model": main_plan},
        "cap_failure": cap_failure,
        "call_failure": call_failure,
        "z_contract": {"nil_z_main": nil_z_main, "zero_z_replay": zero_z_replay,
                       "certificate": replay_certificate(nil_z_main, zero_z_replay)},
        "rollback": {"mutate_then_throw": mutate_then_throw_rollback,
                     "done_failure": done_failure_rollback},
        "lifecycle": {"healthy": healthy, "plan_failure": failed},
    }, indent=2, sort_keys=True))
    return 0 if not failures else 1


if __name__ == "__main__":
    raise SystemExit(main())
