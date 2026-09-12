"""Isolated v979 candidate: preserve positions, group only consecutive reads."""
import hashlib
import json
from pathlib import Path
import subprocess

ROOT=Path(__file__).resolve().parents[3]
out=ROOT/'_ralph/runs/under80-20260912/artifacts/crease_ranges_research'
source=subprocess.check_output(['git','show','c4d3e67:Code/sbm_terrain_copy.lua'],cwd=ROOT,text=True)
helper="""\t-- Consecutive certified positions use the existing rolling read window.
\t-- Discovery is read-only: preserve every position, edge/width order and tie.
\t-- Never bridge a gap or reuse these samples after a terrain write.
\tlocal function scan_indexed_ranges(row, axis, along, positions, edge)
\t\tif not positions then return end
\t\tlocal first, last
\t\tfor _, perp in ipairs(positions) do
\t\t\tif last and perp == last + 1 then
\t\t\t\tlast = perp
\t\t\telse
\t\t\t\tif first then scan_line_range(row, axis, along, first, last, edge) end
\t\t\t\tfirst, last = perp, perp
\t\t\tend
\t\tend
\t\tif first then scan_line_range(row, axis, along, first, last, edge) end
\tend

"""
anchor='\tlocal function collect_axis(axis, perp_n, along_n, before_edge, after_edge,'
assert source.count(anchor)==1
candidate=source.replace(anchor,helper+anchor)
for side in ['before','after']:
    old=('\t\t\tfor _, perp in ipairs('+side+'[along] or {}) do\n'
         '\t\t\t\tscan_line_range(row, axis, along, perp, perp, '+side+'_edge)\n'
         '\t\t\tend')
    new='\t\t\tscan_indexed_ranges(row, axis, along, '+side+'[along], '+side+'_edge)'
    assert candidate.count(old)==1
    candidate=candidate.replace(old,new)
out.mkdir(parents=True,exist_ok=False)
(out/'terrain_candidate.lua').write_text(candidate,encoding='utf-8')
(out/'manifest.json').write_text(json.dumps(dict(baseline='c4d3e67',production_changed=False,
    before_sha256=hashlib.sha256(source.encode()).hexdigest(),
    candidate_sha256=hashlib.sha256(candidate.encode()).hexdigest()),indent=2))
print(out)
