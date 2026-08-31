from pathlib import Path


SOURCE = Path(__file__).resolve().parents[2] / "Code" / "sbm_terrain_copy.lua"
text = SOURCE.read_text(encoding="utf-8")
start = text.index("\tlocal function apply_native_patch(candidate, index)")
end = text.index("\n\tlocal function native_apply()", start)
block = text[start:end]

required = (
    "local function apron_weight(candidate, short_radius, long_radius, dx, dy)",
    "local candidate_x, candidate_y = candidate.x, candidate.y",
    "candidate.center, candidate.gx, candidate.gy",
    "apron_weight(candidate, short_radius, long_radius,",
    "x - candidate_x, y - candidate_y",
    "candidate_center + candidate_gx * (x - candidate_x)",
    "+ candidate_gy * (y - candidate_y)",
)
missing = [token for token in required if token not in text]
if missing:
    raise SystemExit(f"missing apron geometry-localization token(s): {missing}")

for forbidden in ("patch_apron_weight", "candidate_center + candidate.gx"):
    if forbidden in block:
        raise SystemExit(f"forbidden specialized/partial apron path remains: {forbidden}")

shared_calls = block.count("apron_weight(candidate, short_radius, long_radius,")
if shared_calls != 3:
    raise SystemExit(f"expected three unchanged shared apron-weight calls, found {shared_calls}")

for stale in (
    "x - candidate.x, y - candidate.y",
    "candidate.x - core_extent",
    "candidate.y - core_extent",
    "candidate.x + core_extent",
    "candidate.y + core_extent",
):
    if stale in block:
        raise SystemExit(f"stale scalar geometry read remains: {stale}")

print("v1012 apron geometry localization oracle: PASS")
