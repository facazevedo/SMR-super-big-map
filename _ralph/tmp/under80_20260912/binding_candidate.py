"""Build a non-deployed, exact-body standard-library binding experiment."""
import hashlib
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
DECL = '\tlocal math, type, ipairs, pairs, table = math, type, ipairs, pairs, table\n'
ANCHORS = [
    'local function RepairRaisedTerminalHeightStrips(grid)\n',
    'local function BuildHeightStepDiscoveryIndex(api, grid, axis, perp0, perp1, along_n,\n\t\tsample_step, max_width, threshold)\n',
    'local function RepairInternalHeightStep(grid, wide_ring_only)\n',
    'local function RasterNaturalMountainBaseAprons(api, grid, selected, policy)\n',
    'local function PrepareOuterResourceTerrain(map)\n',
]

def candidate(source):
    result = source
    for anchor in ANCHORS:
        assert result.count(anchor) == 1 and anchor + DECL not in result
        result = result.replace(anchor, anchor + DECL)
    assert result.replace(DECL, '') == source
    return result

if __name__ == '__main__':
    source = (ROOT / 'Code/sbm_terrain_copy.lua').read_text()
    result = candidate(source)
    out = ROOT / '_ralph/runs/under80-20260912/artifacts/binding_research'
    out.mkdir(parents=True, exist_ok=False)
    (out / 'terrain_candidate.lua').write_text(result, encoding='utf-8')
    (out / 'source_certificate.json').write_text(json.dumps(dict(
        source_sha256=hashlib.sha256(source.encode()).hexdigest(),
        candidate_sha256=hashlib.sha256(result.encode()).hexdigest(),
        anchors=ANCHORS, declaration=DECL, body_identical_after_removing_bindings=True), indent=2))
    print(out / 'terrain_candidate.lua')
