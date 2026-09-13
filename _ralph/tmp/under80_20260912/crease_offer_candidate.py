"""Generate collection-only per-width offers; no production or deployment edits."""
import difflib
import argparse
import hashlib
import json
from pathlib import Path

root=Path(__file__).resolve().parents[3]
parser=argparse.ArgumentParser()
parser.add_argument('--name',default='crease_offer_research_2')
args=parser.parse_args()
out=root/'_ralph/runs/under80-20260912/artifacts'/args.name
source=(root/'Code/sbm_terrain_copy.lua').read_text()
candidate=source
def once(old,new):
    global candidate
    assert candidate.count(old)==1,repr(old)
    candidate=candidate.replace(old,new)

once('if perp1 < perp0 then return {}, stats end','if perp1 < perp0 then return {}, stats, {} end')
once('local rows, row_seen = {}, {}','local rows, row_seen, offers = {}, {}, {}')
once('''				api.GridMulDivAdd(a, -1, 1, 0); api.GridAdd(magnitude, a); api.GridAbs(magnitude)''',
'''				api.GridMulDivAdd(a, -1, 1, 0); api.GridAdd(magnitude, a)
				-- a is no longer needed as an operand. Preserve signed differences
				-- in that existing f32 scratch grid, with no extra allocation.
				local signed = a
				signed:copyrect(magnitude, api.box(0, 0, local_w, local_h), api.point(0, 0))
				api.GridAbs(magnitude)''')
once('''				api.GridForeach(magnitude, function(jump, x, y)
					if callback_error then return end''',
'''				-- Accepted even packets range2..262142; rejected packets are0.
				-- Threshold1 is unambiguous for either native boundary convention.
				api.GridMulDivAdd(signed, 2, 1, 131072)
				api.GridMulDivAdd(signed, accepted, 1, 0)
				local width_rows = {}; offers[width] = width_rows
				api.GridForeach(signed, function(encoded, x, y)
					if callback_error then return end
					if type(encoded) ~= "number" or encoded ~= math.floor(encoded)
						or encoded % 2 ~= 0 or encoded < 2 or encoded > 262142 then
						callback_error = "native crease signed offer invalid"; return
					end
					local delta = (encoded - 131072) / 2
					local jump = math.abs(delta)''')
once('''					local perp = perp0 + (axis == "x" and x or y)
					local seen = row_seen[along]''',
'''					local perp = perp0 + (axis == "x" and x or y)
					local offer_row = width_rows[along]
					if not offer_row then offer_row = {}; width_rows[along] = offer_row end
					offer_row[perp] = delta
					local seen = row_seen[along]''')
once('\t\treturn rows, stats\n','\t\treturn rows, stats, offers\n')
once('local ok, rows, detail = pcall(work)','local ok, rows, detail, offers = pcall(work)')
once('\treturn rows, detail\n','\treturn rows, detail, offers\n')
once('\tlocal function collect_axis(axis, perp_n, along_n, before_edge, after_edge,\n',
'''	-- Consume only immutable collection offers. Refinement retains its original
	-- live scalar path and unchanged exclusion guide after any height write.
	local function offer_discovered_row(row, axis, along, positions, edge, offers, perp_n)
		local max_width = wide_ring_only and 1 or 3
		local width1 = offers and offers[1] and offers[1][along]
		local width2 = offers and offers[2] and offers[2][along]
		local width3 = offers and offers[3] and offers[3][along]
		local before_edge = edge == "left" or edge == "top"
		for _, perp in ipairs(positions or {}) do
			-- A hit at a narrow width can lie outside a wider native operand's
			-- domain. Keep every original scalar read/predicate at that boundary.
			if not offers or perp > perp_n - max_width - 2 then
				scan_line_range(row, axis, along, perp, perp, edge)
			else
				for width = 1, max_width do
					local values
					if width == 1 then values = width1
					elseif width == 2 then values = width2 else values = width3 end
					local delta = values and values[perp]
					if delta then
						local low_before = delta > 0
						if wide_ring_only or (before_edge and low_before) or (not before_edge and not low_before) then
							offer_candidate(row, axis, perp, width, edge, low_before, math.abs(delta))
						end
					end
				end
			end
		end
	end

	local function collect_axis(axis, perp_n, along_n, before_edge, after_edge,
''')
once('local rows, detail = BuildHeightStepDiscoveryIndex(discovery_api, grid, axis,',
     'local rows, detail, offers = BuildHeightStepDiscoveryIndex(discovery_api, grid, axis,')
once('\t\t\treturn rows\n','\t\t\treturn rows, offers\n')
once('local before = index(before_perp0, before_perp1)','local before, before_offers = index(before_perp0, before_perp1)')
once('local after = index(after_perp0, after_perp1)','local after, after_offers = index(after_perp0, after_perp1)')
once('''			for _, perp in ipairs(before[along] or {}) do
				scan_line_range(row, axis, along, perp, perp, before_edge)
			end
			for _, perp in ipairs(after[along] or {}) do
				scan_line_range(row, axis, along, perp, perp, after_edge)
			end''',
'''			offer_discovered_row(row, axis, along, before[along], before_edge, before_offers, perp_n)
			offer_discovered_row(row, axis, along, after[along], after_edge, after_offers, perp_n)''')
# No old packed-word decoder, refinement changes or rejected contiguous grouping.
for first,last in [('\tlocal function NewHeightStepRefinementGuide(','\t-- INDEXED_HEIGHT_REFINE_END'),
                   ('\tlocal function scan_line_range(','\tlocal function collect_axis('),
                   ('\tlocal function refine_step(','\tlocal function validate_sampled_track(')]:
    old=source[source.index(first):source.index(last,source.index(first))]
    assert old in candidate,first
out.mkdir(parents=True,exist_ok=False)
(out/'sbm_terrain_copy.lua').write_text(candidate)
(out/'candidate.patch').write_text(''.join(difflib.unified_diff(source.splitlines(True),candidate.splitlines(True),
    fromfile='a/Code/sbm_terrain_copy.lua',tofile='b/Code/sbm_terrain_copy.lua')))
(out/'manifest.json').write_text(json.dumps(dict(status='private_not_deployed',
    baseline_sha256=hashlib.sha256(source.encode()).hexdigest(),
    candidate_sha256=hashlib.sha256(candidate.encode()).hexdigest(),
    production_changed=False,refinement_unchanged=True),indent=2))
print(out)
