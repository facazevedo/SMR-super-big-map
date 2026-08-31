#!/usr/bin/env python3
"""Differential oracle for the per-patch Surface apron-weight specialization."""

from __future__ import annotations

import math
import random
import struct
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
SOURCE = (ROOT / "Code" / "sbm_terrain_copy.lua").read_text(encoding="utf-8")


def old(candidate: dict[str, float], short_radius: float, long_radius: float,
        dx: float, dy: float, core_fraction: float) -> tuple[float, bool]:
    u = dx * candidate["mountain_x"] + dy * candidate["mountain_y"]
    v = -dx * candidate["mountain_y"] + dy * candidate["mountain_x"]
    ru, rv = u / short_radius, v / long_radius
    radius = math.sqrt(ru * ru + rv * rv)
    if radius >= 1.12:
        return 0, False
    nx, ny = 1, 0
    if radius > 0.0001:
        nx, ny = ru / radius, rv / radius
    lobe3 = nx * nx * nx - 3 * nx * ny * ny
    lobe2 = nx * nx - ny * ny
    boundary = 1 + 0.055 * lobe3 + 0.035 * lobe2
    normalized = radius / boundary
    if normalized >= 1:
        return 0, False
    if normalized <= core_fraction:
        return 1, True
    t = (normalized - core_fraction) / (1 - core_fraction)
    smooth = t * t * t * (t * (t * 6 - 15) + 10)
    return 1 - smooth, False


def specialized(mountain_x: float, mountain_y: float, short_radius: float,
                long_radius: float, dx: float, dy: float,
                core_fraction: float) -> tuple[float, bool]:
    u = dx * mountain_x + dy * mountain_y
    v = -dx * mountain_y + dy * mountain_x
    ru, rv = u / short_radius, v / long_radius
    radius = math.sqrt(ru * ru + rv * rv)
    if radius >= 1.12:
        return 0, False
    nx, ny = 1, 0
    if radius > 0.0001:
        nx, ny = ru / radius, rv / radius
    lobe3 = nx * nx * nx - 3 * nx * ny * ny
    lobe2 = nx * nx - ny * ny
    boundary = 1 + 0.055 * lobe3 + 0.035 * lobe2
    normalized = radius / boundary
    if normalized >= 1:
        return 0, False
    if normalized <= core_fraction:
        return 1, True
    t = (normalized - core_fraction) / (1 - core_fraction)
    smooth = t * t * t * (t * (t * 6 - 15) + 10)
    return 1 - smooth, False


def bits(value: float) -> bytes:
    return struct.pack(">d", value)


required = (
    "local candidate_x, candidate_y = candidate.x, candidate.y",
    "local mountain_x, mountain_y = candidate.mountain_x, candidate.mountain_y",
    "local function patch_apron_weight(dx, dy)",
    "local u = dx * mountain_x + dy * mountain_y",
    "local v = -dx * mountain_y + dy * mountain_x",
)
assert all(token in SOURCE for token in required), "production specialization is incomplete"
assert SOURCE.count("patch_apron_weight(") == 4, "expected evaluator plus three exact call sites"

rng = random.Random(1012)
checked = 0
for variant in range(-4, 5):
    short_radius = 200.0 * (1 + variant * 0.012)
    long_radius = 270.0 * (1 - variant * 0.009)
    for _ in range(25000):
        angle = rng.uniform(-math.pi, math.pi)
        mountain_x, mountain_y = math.cos(angle), math.sin(angle)
        candidate = {"mountain_x": mountain_x, "mountain_y": mountain_y}
        dx, dy = rng.uniform(-310, 310), rng.uniform(-310, 310)
        before = old(candidate, short_radius, long_radius, dx, dy, 0.2)
        after = specialized(mountain_x, mountain_y, short_radius, long_radius,
                            dx, dy, 0.2)
        assert before[1] == after[1] and bits(before[0]) == bits(after[0])
        checked += 1

print(f"APRON_WEIGHT_SPECIALIZATION_OK samples={checked} calls=3 variants=9")
