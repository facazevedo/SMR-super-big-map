#!/usr/bin/env python3
"""Executable lifecycle and conservative-marker-index oracle for v969."""

from __future__ import annotations

import json
import math
import random
import time
from dataclasses import dataclass


BUCKET_SIZE = 4096
SAFE_WORLD_NUMBER = 2147483647
SAFE_BUCKET_BOUND = 1048576


@dataclass(frozen=True)
class Marker:
    x: int
    y: int
    radius: int
    kind: str
    ordinal: int


def finite_safe(value: object, limit: int) -> bool:
    return isinstance(value, (int, float)) and not isinstance(value, bool) \
        and math.isfinite(value) and -limit <= value <= limit


def build_index(markers: list[Marker]) -> dict[str, list[Marker]] | None:
    buckets: dict[str, list[Marker]] = {}
    entries = 0
    for marker in markers:
        if (not finite_safe(marker.x, SAFE_WORLD_NUMBER)
                or not finite_safe(marker.y, SAFE_WORLD_NUMBER)
                or not finite_safe(marker.radius, SAFE_WORLD_NUMBER)
                or marker.radius < 0):
            return None
        min_bx = math.floor((marker.x - marker.radius - 1) / BUCKET_SIZE)
        max_bx = math.floor((marker.x + marker.radius + 1) / BUCKET_SIZE)
        min_by = math.floor((marker.y - marker.radius - 1) / BUCKET_SIZE)
        max_by = math.floor((marker.y + marker.radius + 1) / BUCKET_SIZE)
        if not all(finite_safe(bound, SAFE_BUCKET_BOUND)
                   for bound in (min_bx, max_bx, min_by, max_by)):
            return None
        span_x, span_y = max_bx - min_bx + 1, max_by - min_by + 1
        if (span_x < 1 or span_y < 1 or span_x > 4096 or span_y > 4096
                or (span_x > 1 and min_bx + 1 == min_bx)
                or (span_y > 1 and min_by + 1 == min_by)):
            return None
        marker_entries = span_x * span_y
        if marker_entries < 1 or marker_entries > 4096 or entries + marker_entries > 65536:
            return None
        for bx in range(min_bx, max_bx + 1):
            for by in range(min_by, max_by + 1):
                buckets.setdefault(f"{bx}:{by}", []).append(marker)
                entries += 1
    return buckets


def select_marker_filter(markers: list[Marker], fresh_grid_flag: bool) -> tuple[object, int]:
    """Flag-off models literal v968 and must not construct the v969 index."""
    index_calls = 0
    if not fresh_grid_flag:
        return lambda x, y: literal_reject(markers, x, y), index_calls
    index_calls += 1
    index = build_index(markers)
    if index is None:
        return lambda x, y: literal_reject(markers, x, y), index_calls
    return lambda x, y: indexed_reject(index, x, y), index_calls


def literal_reject(markers: list[Marker], x: int, y: int) -> tuple[bool, int | None]:
    for marker in markers:
        if (x - marker.x) ** 2 + (y - marker.y) ** 2 <= marker.radius ** 2:
            return True, marker.ordinal
    return False, None


def indexed_reject(index: dict[str, list[Marker]], x: int, y: int) -> tuple[bool, int | None]:
    candidates = index.get(f"{math.floor(x / BUCKET_SIZE)}:{math.floor(y / BUCKET_SIZE)}", [])
    return literal_reject(candidates, x, y)


def lifecycle(first_rebuild: bool = True, plan: bool = True, publish: bool = True,
              closing_rebuild: bool = True) -> dict[str, object]:
    events: list[str] = []
    attempts = published = rebuilds = 0
    state = "suppressed-awaiting-surface-capsules"
    ready = False
    events.append("first-rebuild")
    rebuilds += 1
    if not first_rebuild:
        return dict(events=events, attempts=attempts, published=published,
                    rebuilds=rebuilds, state="blocked", ready=ready)
    events.append("fresh-plan")
    attempts = 1
    if not plan:
        return dict(events=events, attempts=attempts, published=published,
                    rebuilds=rebuilds, state="blocked", ready=ready)
    events.append("replay")
    events.append("publish-two")
    if not publish:
        return dict(events=events, attempts=attempts, published=published,
                    rebuilds=rebuilds, state="blocked", ready=ready)
    published = 2
    state = "surface-capsules-published-awaiting-final-grid"
    events.append("closing-rebuild")
    rebuilds += 1
    if not closing_rebuild:
        return dict(events=events, attempts=attempts, published=published,
                    rebuilds=rebuilds, state="blocked", ready=ready)
    ready = True
    return dict(events=events, attempts=attempts, published=published,
                rebuilds=rebuilds, state=state, ready=ready)


def main() -> int:
    started = time.perf_counter()
    rng = random.Random(96904096)
    concrete = [Marker(rng.randrange(0, 819200), rng.randrange(0, 819200),
                       rng.randrange(0, 18001), "concrete", i)
                for i in range(80)]
    geysers = [Marker(rng.randrange(0, 819200), rng.randrange(0, 819200),
                     rng.randrange(0, 12001), "geyser", 1000 + i)
               for i in range(40)]
    # Force bucket-edge, zero-radius, and exact-tangent cases.
    concrete += [Marker(4096, 8192, 0, "concrete", 9001),
                 Marker(12288, 16384, 4096, "concrete", 9002)]
    geysers += [Marker(20480, 24576, 8192, "geyser", 9003)]
    concrete_index = build_index(concrete)
    geyser_index = build_index(geysers)
    points = [(rng.randrange(0, 819200), rng.randrange(0, 819200)) for _ in range(20000)]
    points += [(4096, 8192), (8192, 16384), (16384, 16384),
               (20480, 16384), (20480, 32768), (0, 0)]
    index_exact = concrete_index is not None and geyser_index is not None
    first_mismatch = None
    if index_exact:
        for x, y in points:
            literal = literal_reject(concrete, x, y)
            indexed = indexed_reject(concrete_index, x, y)
            if literal != indexed:
                index_exact = False
                first_mismatch = ["concrete", x, y, literal, indexed]
                break
            if not literal[0]:
                literal = literal_reject(geysers, x, y)
                indexed = indexed_reject(geyser_index, x, y)
                if literal != indexed:
                    index_exact = False
                    first_mismatch = ["geyser", x, y, literal, indexed]
                    break

    healthy = lifecycle()
    first_failure = lifecycle(first_rebuild=False)
    plan_failure = lifecycle(plan=False)
    publication_failure = lifecycle(publish=False)
    closing_failure = lifecycle(closing_rebuild=False)
    checks = {
        "healthy_order_is_first_rebuild_plan_replay_publish_close": healthy["events"] == [
            "first-rebuild", "fresh-plan", "replay", "publish-two", "closing-rebuild"],
        "healthy_has_zero_stale_attempts_and_two_rebuilds": (
            healthy["attempts"] == 1 and healthy["rebuilds"] == 2
            and healthy["published"] == 2 and healthy["ready"] is True),
        "first_rebuild_failure_never_plans_or_publishes": (
            first_failure["events"] == ["first-rebuild"]
            and first_failure["attempts"] == first_failure["published"] == 0
            and first_failure["state"] == "blocked" and first_failure["ready"] is False),
        "fresh_plan_failure_never_publishes_or_closes": (
            plan_failure["events"] == ["first-rebuild", "fresh-plan"]
            and plan_failure["published"] == 0 and plan_failure["rebuilds"] == 1
            and plan_failure["state"] == "blocked" and plan_failure["ready"] is False),
        "publication_failure_is_no_partial_and_does_not_close": (
            publication_failure["published"] == 0 and publication_failure["rebuilds"] == 1
            and publication_failure["state"] == "blocked" and publication_failure["ready"] is False),
        "closing_failure_is_sticky_and_never_ready": (
            closing_failure["published"] == 2 and closing_failure["rebuilds"] == 2
            and closing_failure["state"] == "blocked" and closing_failure["ready"] is False),
        "marker_bucket_index_matches_literal_ordered_predicates": index_exact,
        "flag_off_is_literal_v968_and_constructs_no_index": all(
            select_marker_filter(concrete + geysers, False)[0](x, y)
            == literal_reject(concrete + geysers, x, y)
            and select_marker_filter(concrete + geysers, False)[1] == 0
            for x, y in points[:1000]),
        "negative_or_pathological_radius_forces_literal_fallback": (
            build_index([Marker(0, 0, -1, "concrete", 1)]) is None
            and build_index([Marker(0, 0, BUCKET_SIZE * 100, "concrete", 1)]) is None),
        "nan_inf_and_huge_values_fallback_before_bucket_loops": all(
            build_index([marker]) is None for marker in (
                Marker(0, 0, float("nan"), "concrete", 1),
                Marker(0, 0, float("inf"), "concrete", 2),
                Marker(0, 0, float("-inf"), "concrete", 3),
                Marker(float("nan"), 0, 1, "concrete", 4),
                Marker(float("inf"), 0, 1, "concrete", 5),
                Marker(1e300, 0, 1, "concrete", 6),
                Marker(0, -1e300, 1, "concrete", 7),
                Marker(0, 0, 1e300, "concrete", 8),
                Marker(0, 0, SAFE_WORLD_NUMBER, "concrete", 9),
            )),
    }
    failed = sorted(name for name, ok in checks.items() if not ok)
    print(json.dumps({
        "schema": "smr.ralph.v969.fresh-grid-capsule-publication-oracle.v1",
        "ok": not failed,
        "failed": failed,
        "checks": checks,
        "first_index_mismatch": first_mismatch,
        "lifecycle": {
            "healthy": healthy,
            "first_rebuild_failure": first_failure,
            "plan_failure": plan_failure,
            "publication_failure": publication_failure,
            "closing_failure": closing_failure,
        },
        "index_corpus": {"concrete": len(concrete), "geysers": len(geysers),
                         "queries": len(points), "bucket_size": BUCKET_SIZE},
        "elapsed_ms": round((time.perf_counter() - started) * 1000, 3),
    }, indent=2, sort_keys=True))
    return 0 if not failed else 1


if __name__ == "__main__":
    raise SystemExit(main())
