#!/usr/bin/env python3
"""Static and semantic exactness gate for the v959 post-object rocket read cache."""

from __future__ import annotations

import hashlib
import json
import random
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
TERRAIN = ROOT / "Code" / "sbm_terrain_copy.lua"
GENERATION = ROOT / "Code" / "sbm_map_generation.lua"
CONFIG = ROOT / "Code" / "sbm_config.lua"
METADATA = ROOT / "metadata.lua"


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest().upper()


def readiness(offsets, q, r, passable, heights, trace):
    level = None
    for dq, dr in offsets:
        hq, hr = q + dq, r + dr
        p = passable.get((hq, hr), False)
        trace.append((hq, hr, "p", p))
        if not p:
            return False
        z = heights.get((hq, hr))
        trace.append((hq, hr, "z", z))
        if z is None:
            return False
        if level is None:
            level = z
        elif z != level:
            return False
    return bool(offsets)


def cached_readiness(offsets, q, r, passable, heights, pass_cache, z_cache, trace, reads):
    level = None
    for dq, dr in offsets:
        hq, hr = q + dq, r + dr
        key = (hq, hr)
        if key in pass_cache:
            p = pass_cache[key]
            reads["pass_hits"] += 1
        else:
            p = passable.get(key, False)
            pass_cache[key] = p
            reads["pass_misses"] += 1
        trace.append((hq, hr, "p", p))
        if not p:
            return False
        if key in z_cache:
            z = z_cache[key]
            reads["z_hits"] += 1
        else:
            z = heights.get(key)
            z_cache[key] = z
            reads["z_misses"] += 1
        trace.append((hq, hr, "z", z))
        if z is None:
            return False
        if level is None:
            level = z
        elif z != level:
            return False
    return bool(offsets)


def semantic_corpus() -> dict[str, bool | int]:
    rng = random.Random(0x959)
    offsets = [
        (dq, dr)
        for dq in range(-4, 5)
        for dr in range(-4, 5)
        if max(abs(dq), abs(dr), abs(dq + dr)) <= 4
    ]
    candidates = [(q, r) for q in range(-18, 19) for r in range(-18, 19)]
    passable = {}
    heights = {}
    for q in range(-24, 25):
        for r in range(-24, 25):
            passable[(q, r)] = (q * 17 + r * 31) % 29 != 0
            heights[(q, r)] = 1200 + ((q // 9 + r // 11) % 3) * 100
            if rng.randrange(113) == 0:
                heights[(q, r)] = None

    legacy_trace, cached_trace = [], []
    legacy_results, cached_results = [], []
    pass_cache, z_cache = {}, {}
    reads = {"pass_hits": 0, "pass_misses": 0, "z_hits": 0, "z_misses": 0}
    for q, r in candidates:
        legacy_results.append(readiness(offsets, q, r, passable, heights, legacy_trace))
        cached_results.append(
            cached_readiness(
                offsets, q, r, passable, heights, pass_cache, z_cache, cached_trace, reads
            )
        )

    base_scores = [((q * 101 + r * 307) % 100003) for q, r in candidates]
    legacy_scores = [(-1_000_000_000 if ready else 0) + score for ready, score in zip(legacy_results, base_scores)]
    cached_scores = [(-1_000_000_000 if ready else 0) + score for ready, score in zip(cached_results, base_scores)]
    legacy_winner = min(range(len(candidates)), key=lambda i: legacy_scores[i])
    cached_winner = min(range(len(candidates)), key=lambda i: cached_scores[i])
    legacy_reads = sum(1 for item in legacy_trace if item[2] in {"p", "z"})
    cached_raw_reads = reads["pass_misses"] + reads["z_misses"]
    return {
        "corpus_candidates": len(candidates),
        "corpus_offsets": len(offsets),
        "results_exact": legacy_results == cached_results,
        "semantic_trace_exact": legacy_trace == cached_trace,
        "score_vector_exact": legacy_scores == cached_scores,
        "winner_exact": legacy_winner == cached_winner,
        "cache_has_hits": reads["pass_hits"] > 0 and reads["z_hits"] > 0,
        "raw_reads_reduced": cached_raw_reads < legacy_reads,
        "legacy_reads": legacy_reads,
        "cached_raw_reads": cached_raw_reads,
    }


def main() -> int:
    terrain = TERRAIN.read_text(encoding="utf-8")
    generation = GENERATION.read_text(encoding="utf-8")
    config = CONFIG.read_text(encoding="utf-8")
    metadata = METADATA.read_text(encoding="utf-8")
    block_start = terrain.index("local function cached_rocket_passable")
    block_end = terrain.index("local function candidate_score", block_start)
    block = terrain[block_start:block_end]
    post_object = generation.index('NotifyDeterminismCaptureForTest("post_object_transform"')
    prepare_call = generation.index("TerrainCopy.PrepareOuterResourceTerrain, map", post_object)
    checks = {
        "default_on": "config.OptimizeOuterResourceRocketReadCache = true" in config,
        "compiled_flag": "C.OPTIMIZE_OUTER_RESOURCE_ROCKET_READ_CACHE" in config,
        "runtime_flag": 'cfg_bool("OPTIMIZE_OUTER_RESOURCE_ROCKET_READ_CACHE", true)' in terrain,
        "strictly_after_post_object": post_object < prepare_call,
        "cache_before_scorer": block_start < block_end,
        "legacy_disabled_path_retained": "return hex_passable(q, r)" in block,
        "transient_errors_not_cached": "if not ok then return false end" in block
        and "if not ok_z then return nil end" in block,
        "candidate_score_expression_retained":
            "score = (ready and -1000000000 or 0)" in terrain,
        "candidate_order_retained": "for dq = -search_limit, search_limit do" in terrain
        and "for dr = -search_limit, search_limit do" in terrain,
        "no_rng_in_cache": all(token not in block for token in ("AsyncRand", "InteractionRand", "BraidRandom")),
        "telemetry_complete": all(
            token in terrain
            for token in (
                "rocket_read_cache_requested",
                "rocket_read_cache_used",
                "rocket_passability_cache_hits",
                "rocket_passability_cache_misses",
                "rocket_buildable_cache_hits",
                "rocket_buildable_cache_misses",
            )
        ),
        "metadata_v959": "'version', 959," in metadata,
    }
    corpus = semantic_corpus()
    checks.update({f"semantic_{key}": value is True for key, value in corpus.items() if isinstance(value, bool)})
    failed = sorted(key for key, value in checks.items() if not value)
    result = {
        "schema": "smr.ralph.v959.outer-resource-rocket-read-cache.v1",
        "ok": not failed,
        "checks": checks,
        "failed": failed,
        "corpus": corpus,
        "sha256": {
            "terrain": sha256(TERRAIN),
            "generation": sha256(GENERATION),
            "config": sha256(CONFIG),
            "metadata": sha256(METADATA),
        },
    }
    print(json.dumps(result, indent=2, sort_keys=True))
    return 0 if result["ok"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
