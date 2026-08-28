#!/usr/bin/env python3
"""Static and semantic exactness gate for v960 rocket relief deferral."""

from __future__ import annotations

import hashlib
import json
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
TERRAIN_PATH = ROOT / "Code" / "sbm_terrain_copy.lua"
CONFIG_PATH = ROOT / "Code" / "sbm_config.lua"
METADATA_PATH = ROOT / "metadata.lua"

DIRECTIONS = (
    (1, 0), (-1, 0), (0, 1), (0, -1),
    (1, 1), (-1, 1), (1, -1), (-1, -1),
)
CANDIDATE_KEYS = frozenset({
    "x", "y", "q", "r", "ready_before", "mountain", "maximum_rise",
    "higher_samples", "height_range", "inner_clearance", "score",
})


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest().upper()


def height(x: int, y: int) -> int:
    """Stable immutable corpus with flat, rolling, and mountain-like samples."""
    return 12000 + ((x * 37 + y * 73 + (x // 17) * 911 + (y // 23) * 577) % 5000)


def relief(x: int, y: int, center: int) -> tuple[bool, int, int]:
    maximum_rise = 0
    higher = 0
    for dx, dy in DIRECTIONS:
        z = height(x + dx * 120, y + dy * 120)
        if z - center >= 500:
            maximum_rise = max(maximum_rise, z - center)
            higher += 1
    return maximum_rise >= 500 and higher >= 2, maximum_rise, higher


def candidate_shell(group: int, ordinal: int) -> dict[str, int | bool]:
    x = 700 + group * 503 + ordinal * 19
    y = 900 + group * 431 + ordinal * 31
    height_range = (x * 11 + y * 7) % 83
    ready = (ordinal + group * 3) % 97 == 0
    return {
        "x": x,
        "y": y,
        "q": x // 10,
        "r": y // 10,
        "ready_before": ready,
        "mountain": False,
        "maximum_rise": 0,
        "higher_samples": 0,
        "height_range": height_range,
        "inner_clearance": min(x, y),
        "score": (-1_000_000_000 if ready else 0) + height_range * 100
        + (ordinal % 41),
    }


def eager(groups: list[list[dict[str, int | bool]]]):
    winners = []
    score_trace = []
    reads = 0
    for group in groups:
        best = None
        group_trace = []
        for source in group:
            candidate = dict(source)
            values = relief(int(candidate["x"]), int(candidate["y"]),
                            height(int(candidate["x"]), int(candidate["y"])))
            reads += 8
            candidate["mountain"], candidate["maximum_rise"], candidate["higher_samples"] = values
            group_trace.append((candidate["score"], frozenset(candidate)))
            if best is None or int(candidate["score"]) < int(best["score"]):
                best = candidate
        winners.append(best)
        score_trace.append(group_trace)
    return score_trace, winners, reads


def deferred(groups: list[list[dict[str, int | bool]]]):
    winners = []
    score_trace = []
    reads = 0
    for group in groups:
        best = None
        group_trace = []
        for source in group:
            candidate = dict(source)
            group_trace.append((candidate["score"], frozenset(candidate)))
            if best is None or int(candidate["score"]) < int(best["score"]):
                best = candidate
        assert best is not None
        center = height(int(best["x"]), int(best["y"]))
        reads += 1
        values = relief(int(best["x"]), int(best["y"]), center)
        reads += 8
        best["mountain"], best["maximum_rise"], best["higher_samples"] = values
        winners.append(best)
        score_trace.append(group_trace)
    return score_trace, winners, reads


def semantic_corpus() -> dict[str, bool | int]:
    viable_by_group = (2302, 2302, 2302, 2301, 2301, 2301)
    groups = [[candidate_shell(group, ordinal) for ordinal in range(viable)]
              for group, viable in enumerate(viable_by_group)]
    eager_result = eager(groups)
    deferred_result = deferred(groups)
    viable = sum(len(group) for group in groups)
    return {
        "groups": len(groups),
        "viable_candidates": viable,
        "score_and_key_trace_exact": eager_result[0] == deferred_result[0],
        "candidate_key_shape_exact": all(
            frozenset(candidate) == CANDIDATE_KEYS for group in groups for candidate in group
        ),
        "winner_all_fields_exact": eager_result[1] == deferred_result[1],
        "eager_reads": eager_result[2],
        "deferred_reads": deferred_result[2],
        "saved_reads": eager_result[2] - deferred_result[2],
        "eager_read_formula_exact": eager_result[2] == viable * 8,
        "deferred_read_formula_exact": deferred_result[2] == len(groups) * 9,
    }


def main() -> int:
    terrain = TERRAIN_PATH.read_text(encoding="utf-8")
    config = CONFIG_PATH.read_text(encoding="utf-8")
    metadata = METADATA_PATH.read_text(encoding="utf-8")
    scorer_start = terrain.index("local function candidate_score")
    scorer_end = terrain.index("local cluster_groups_by_plan", scorer_start)
    scorer = terrain[scorer_start:scorer_end]
    winner_start = terrain.index("if best then", scorer_end)
    winner_end = terrain.index("best.members = #members", winner_start)
    winner = terrain[winner_start:winner_end]
    checks = {
        "default_on": "config.OptimizeOuterResourceRocketReliefDeferral = true" in config,
        "compiled_flag": "C.OPTIMIZE_OUTER_RESOURCE_ROCKET_RELIEF_DEFERRAL" in config,
        "runtime_flag": 'cfg_bool("OPTIMIZE_OUTER_RESOURCE_ROCKET_RELIEF_DEFERRAL", true)'
        in terrain,
        "literal_legacy_branch": all(token in scorer for token in (
            "if not rocket_relief_deferral_used then",
            "for _, direction in ipairs(relief_directions) do",
            "local z = grid_value(cx + direction[1] * 12 * cells_per_hex,",
            "mountain = maximum_rise >= 5 * guim_v and higher >= 2",
        )),
        "placeholder_shape_before_score": all(token in scorer for token in (
            "local maximum_rise, higher, mountain = 0, 0, false",
            "mountain = mountain, maximum_rise = maximum_rise, higher_samples = higher,",
        )),
        "score_expression_unchanged": all(token in scorer for token in (
            "score = (ready and -1000000000 or 0) + (range_max - range_min) * 100",
            "+ axial_distance(q, r, cq, cr),",
        )),
        "strict_tie_order_unchanged":
            "if candidate and (not best or candidate.score < best.score) then" in terrain,
        "winner_uses_cached_original_center": all(token in winner for token in (
            "local row = rocket_height_cache[best.q]",
            "local center = row and row[best.r]",
            'assert(type(center) == "number"',
            'assert(reloaded_center == center',
        )),
        "winner_has_one_center_reload": winner.count("grid_value(cx, cy)") == 1,
        "winner_has_ordered_eight_direction_loop": all(token in winner for token in (
            "for _, direction in ipairs(relief_directions) do",
            "local z = grid_value(cx + direction[1] * 12 * cells_per_hex,",
            "best.maximum_rise = maximum_rise",
            "best.higher_samples = higher",
            "best.mountain = maximum_rise >= 5 * guim_v and higher >= 2",
        )),
        "telemetry_complete": all(token in terrain for token in (
            "rocket_relief_deferral_requested",
            "rocket_relief_deferral_used",
            "rocket_relief_viable_candidates",
            "rocket_relief_selected_groups",
            "rocket_relief_eager_equivalent_reads",
            "rocket_relief_deferred_reads",
            "rocket_relief_saved_reads",
            "rocket_relief_center_mismatches",
        )),
        "no_rng_in_scorer_or_winner": all(
            token not in scorer + winner
            for token in ("AsyncRand", "InteractionRand", "BraidRandom")
        ),
        "metadata_v960_or_later": any(
            f"'version', {version}," in metadata for version in range(960, 1000)
        ),
    }
    corpus = semantic_corpus()
    checks.update({
        f"semantic_{key}": value is True
        for key, value in corpus.items()
        if isinstance(value, bool)
    })
    failed = sorted(key for key, value in checks.items() if not value)
    report = {
        "schema": "smr.ralph.v960.outer-resource-relief-deferral.v1",
        "ok": not failed,
        "checks": checks,
        "failed": failed,
        "corpus": corpus,
        "sha256": {
            "terrain": sha256(TERRAIN_PATH),
            "config": sha256(CONFIG_PATH),
            "metadata": sha256(METADATA_PATH),
        },
    }
    print(json.dumps(report, indent=2, sort_keys=True))
    return 0 if report["ok"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
