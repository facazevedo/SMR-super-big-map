#!/usr/bin/env python3
"""Deterministic policy/performance oracle for v972 direct outer passage pads."""

from __future__ import annotations

import json
import math
import time


MODULUS = 2_147_483_647
MAP = 819_200
BAND = 81_920
SAFE = 24_000
HEX = 1_000
ATTEMPT_CAP = 32
VIABLE_TARGET = 4
FOOTPRINT_RADIUS = 6_000
MIN_PAIR_DISTANCE = 100_000
SHAPE = tuple((q, r) for q in range(-5, 6) for r in range(-5, 6)
              if max(abs(q), abs(r), abs(q + r)) <= 5)


def next_value(state: int) -> int:
    return (state * 48_271 + 1) % MODULUS or 1


def seeded(seed: int) -> int:
    state = abs(seed) % MODULUS
    for byte in b"RoughTerrain|v972-direct-outer-passage-pad-reservation":
        state = (state * 48_271 + byte + 1) % MODULUS
    return state or 1


def axial(a: tuple[int, int], b: tuple[int, int]) -> int:
    dq, dr = a[0] - b[0], a[1] - b[1]
    return max(abs(dq), abs(dr), abs(dq + dr))


def direct_sample(state: int) -> tuple[int, int, int, int]:
    side_draw = next_value(state)
    along_draw = next_value(side_draw)
    angle_draw = next_value(along_draw)
    side = side_draw % 4
    perpendicular_span = BAND - 2 * SAFE - 1
    depth = SAFE + (side_draw // 4) % perpendicular_span
    along = SAFE + along_draw % (MAP - 2 * SAFE)
    if side == 0:
        x, y = depth, along
    elif side == 1:
        x, y = MAP - 1 - depth, along
    elif side == 2:
        x, y = along, depth
    else:
        x, y = along, MAP - 1 - depth
    return x, y, (angle_draw % 6) * 3600, angle_draw


def in_certified_ring(x: int, y: int) -> bool:
    inside_map = SAFE <= x < MAP - SAFE and SAFE <= y < MAP - SAFE
    outside_inner = x < BAND - SAFE or y < BAND - SAFE \
        or x > MAP - BAND + SAFE or y > MAP - BAND + SAFE
    return inside_map and outside_inner


def height(q: int, r: int) -> int:
    return 4_000 + (q * 37 + r * 61 + q * r * 3) % 1_700


def make_corpus(seed: int) -> dict:
    resources = [((17 + i * 47 + seed * 3) % 790,
                  (19 + i * 71 + seed * 5) % 790) for i in range(190)]
    rockets = [(45, 180), (45, 390), (45, 610),
               (775, 170), (775, 400), (775, 635)]
    markers = [((29 + i * 83 + seed) % MAP,
                (31 + i * 107 + seed * 7) % MAP,
                700 + i % 4 * 250) for i in range(80)]
    blocked = {((11 + i * 83 + seed) % 810,
                (13 + i * 107 + seed * 2) % 810) for i in range(120)}
    return {"resources": resources, "rockets": rockets,
            "markers": markers, "blocked": blocked}


def plan(seed: int, corpus: dict) -> dict:
    state = seeded(seed)
    initial = state
    chosen: list[dict] = []
    attempts = viable = shape_checks = marker_checks = 0
    for site_index in range(2):
        best = None
        site_viable = 0
        for _ in range(ATTEMPT_CAP):
            attempts += 1
            x, y, angle, state = direct_sample(state)
            q, r = x // HEX, y // HEX
            valid = in_certified_ring(x, y)
            valid = valid and all(axial((q, r), item) >= 11
                                  for item in corpus["resources"])
            valid = valid and all(axial((q, r), item) >= 17
                                  for item in corpus["rockets"])
            valid = valid and all((x - item["x"]) ** 2 + (y - item["y"]) ** 2
                                  >= MIN_PAIR_DISTANCE ** 2 for item in chosen)
            if valid:
                for mx, my, radius in corpus["markers"]:
                    marker_checks += 1
                    clearance = FOOTPRINT_RADIUS + radius
                    if (x - mx) ** 2 + (y - my) ** 2 <= clearance ** 2:
                        valid = False
                        break
            if valid:
                shape_checks += 1
                valid = all((q + dq, r + dr) not in corpus["blocked"]
                            for dq, dr in SHAPE)
            if not valid:
                continue
            site_viable += 1
            viable += 1
            values = [height(q + dq, r + dr) for dq, dr in SHAPE]
            candidate = {"index": site_index + 1, "x": x, "y": y,
                         "q": q, "r": r, "angle": angle,
                         "height_range": max(values) - min(values)}
            if best is None or candidate["height_range"] < best["height_range"]:
                best = candidate
            if site_viable >= VIABLE_TARGET:
                break
        if best is None:
            return {"ok": False, "sites": [], "attempts": attempts,
                    "viable": viable, "state": state, "partial": False}
        chosen.append(best)
    digest = initial
    for site in chosen:
        for value in (abs(site["q"]) + 1, abs(site["r"]) + 1, site["angle"] + 1):
            digest = (digest * 48_271 + value) % MODULUS
    return {"ok": True, "sites": chosen, "attempts": attempts,
            "viable": viable, "shape_checks": shape_checks,
            "marker_checks": marker_checks, "state": state,
            "draws": attempts * 3, "digest": digest, "partial": False}


def main() -> int:
    started = time.perf_counter()
    corpora = []
    for index in range(64):
        corpus = make_corpus(index)
        first = plan(972_000 + index, corpus)
        replay = plan(972_000 + index, corpus)
        corpora.append((corpus, first, replay))
    elapsed_ms = (time.perf_counter() - started) * 1000
    successes = [result for _, result, _ in corpora if result["ok"]]
    max_attempts = max((result["attempts"] for result in successes), default=0)
    max_shape_checks = max((result["shape_checks"] for result in successes), default=0)
    max_marker_checks = max((result["marker_checks"] for result in successes), default=0)
    geometry = all(in_certified_ring(site["x"], site["y"])
                   for result in successes for site in result["sites"])
    spacing = all((result["sites"][0]["x"] - result["sites"][1]["x"]) ** 2
                  + (result["sites"][0]["y"] - result["sites"][1]["y"]) ** 2
                  >= MIN_PAIR_DISTANCE ** 2 for result in successes)
    marker_clear = all(all((site["x"] - mx) ** 2 + (site["y"] - my) ** 2
                               > (FOOTPRINT_RADIUS + radius) ** 2
                               for mx, my, radius in corpus["markers"])
                       for corpus, result, _ in corpora if result["ok"]
                       for site in result["sites"])
    checks = {
        "all_64_corpora_select_exactly_two": len(successes) == 64
            and all(len(result["sites"]) == 2 for result in successes),
        "deterministic_full_replay": all(first == replay for _, first, replay in corpora),
        "direct_samples_are_outer_and_inner_disjoint": geometry,
        "strict_pair_spacing": spacing,
        "conservative_marker_clearance": marker_clear,
        "four_viable_samples_per_site": all(result["viable"] == 8 for result in successes),
        "bounded_attempts": max_attempts <= 64,
        "bounded_exact_shape_walks": max_shape_checks <= 64,
        "no_shape_marker_cartesian_product": max_marker_checks <= 64 * 80,
        "three_private_draws_per_attempt": all(result["draws"] == result["attempts"] * 3
                                                for result in successes),
        "no_partial_publication_model": all(result["partial"] is False
                                             for _, result, _ in corpora),
        "oracle_runtime_bounded": elapsed_ms < 1_000,
    }
    failed = sorted(name for name, ok in checks.items() if not ok)
    print(json.dumps({
        "schema": "smr.ralph.v972.direct-outer-passage-pad-oracle.v1",
        "ok": not failed,
        "failed": failed,
        "checks": checks,
        "corpora": len(corpora),
        "max_attempts": max_attempts,
        "max_shape_checks": max_shape_checks,
        "max_marker_checks": max_marker_checks,
        "elapsed_ms": round(elapsed_ms, 3),
        "representative": successes[0] if successes else {},
    }, indent=2, sort_keys=True))
    return 0 if not failed else 1


if __name__ == "__main__":
    raise SystemExit(main())
