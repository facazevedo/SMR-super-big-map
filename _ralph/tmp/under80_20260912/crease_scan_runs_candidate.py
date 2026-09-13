"""Generate a nondeployed candidate grouping consecutive native discovery hits."""
import hashlib
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
out = ROOT / '_ralph/runs/under80-20260912/artifacts/crease_scan_runs_research'
source = (ROOT / 'Code/sbm_terrain_copy.lua').read_text()
candidate = source

def once(old, new):
    global candidate
    assert candidate.count(old) == 1, repr(old)
    candidate = candidate.replace(old, new)

once('\tlocal function collect_axis(axis, perp_n, along_n, before_edge, after_edge,\n', '''	local function scan_indexed_runs(row, axis, along, positions, edge)
		if not positions then return end
		-- Native discovery returns sorted unique integer positions. Group only
		-- adjacent entries: the existing scanner's sliding window then reuses
		-- immutable height reads without changing any candidate or width order.
		local index, count = 1, #positions
		while index <= count do
			local first, last = positions[index], positions[index]
			index = index + 1
			while index <= count and positions[index] == last + 1 do
				last = positions[index]
				index = index + 1
			end
			scan_line_range(row, axis, along, first, last, edge)
		end
	end

	local function collect_axis(axis, perp_n, along_n, before_edge, after_edge,
''')
once('''			for _, perp in ipairs(before[along] or {}) do
				scan_line_range(row, axis, along, perp, perp, before_edge)
			end
			for _, perp in ipairs(after[along] or {}) do
				scan_line_range(row, axis, along, perp, perp, after_edge)
			end
''', '''			scan_indexed_runs(row, axis, along, before[along], before_edge)
			scan_indexed_runs(row, axis, along, after[along], after_edge)
''')
out.mkdir(parents=True, exist_ok=False)
(out / 'sbm_terrain_copy.lua').write_text(candidate, encoding='utf-8')
(out / 'manifest.json').write_text(json.dumps({
    'status': 'research_only_not_deployed',
    'source_sha256': hashlib.sha256(source.encode()).hexdigest(),
    'candidate_sha256': hashlib.sha256(candidate.encode()).hexdigest(),
}, indent=2), encoding='utf-8')
print(out)
