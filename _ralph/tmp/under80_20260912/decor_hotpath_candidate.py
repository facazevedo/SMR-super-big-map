"""Generate a nondeployed decor hot-path candidate from accepted v983."""
import hashlib
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
out = ROOT / '_ralph/runs/under80-20260912/artifacts/decor_hotpath_research_2'
source = (ROOT / 'Code/sbm_decor_topup.lua').read_text()
candidate = source

def once(old, new):
    global candidate
    assert candidate.count(old) == 1, repr(old)
    candidate = candidate.replace(old, new)

once('local function circle_hits(list, x, y, radius)\n', '''local function circle_hits(list, x, y, radius)
	-- Private last-hit hints only accelerate definite positives. Every miss still
	-- runs the complete accepted index, including its append catch-up.
	local cache = list.hit_hint_cache
	if not cache then
		cache = { rows = {}, queries = 0, slots = 0, floor = math.floor }
		list.hit_hint_cache = cache
	end
	local floor, cell = cache.floor, 16384
	local active, hint_x, hint_y, hint_row, hint
	if cache.queries < 32 then
		cache.queries = cache.queries + 1
	else
		active = x >= -67108864 and x <= 67108864 and y >= -67108864 and y <= 67108864
			and radius >= 0 and radius <= 65536
		if active then
			hint_x, hint_y = floor((x + 0.0) / 4096), floor((y + 0.0) / 4096)
			hint_row = cache.rows[hint_x]
			hint = hint_row and hint_row[hint_y]
			if hint then
				local dx, dy = x - hint.x, y - hint.y
				local reach = radius + hint.r
				local distance2 = dx * dx + dy * dy
				-- Exact predicate plus an inward one-unit margin: the old bounding
				-- box index must include this immutable circle despite roundoff.
				if distance2 < reach * reach and reach > 1
					and distance2 < (reach - 1) * (reach - 1) then return true end
			end
		end
	end
''')
once('\tlocal floor, cell = math.floor, 16384\n', '')
once('if dx * dx + dy * dy < reach * reach then return true end', '''if dx * dx + dy * dy < reach * reach then
							if active and c ~= hint and (hint or cache.slots < 32768)
								and c.x >= -67108864 and c.x <= 67108864
								and c.y >= -67108864 and c.y <= 67108864 and c.r >= 0 and c.r <= 67108864 then
								if not hint_row then hint_row = {}; cache.rows[hint_x] = hint_row end
								if not hint then cache.slots = cache.slots + 1 end
								hint_row[hint_y] = c
							end
							return true
						end''')
start = candidate.index('local function NewDecorInteriorCursor(')
end = candidate.index('-- DECOR_FINITE_SITES_END', start)
old_cursor = candidate[start:end]
tail = old_cursor[old_cursor.index('\treturn function()\n'):]
# Original empty-rectangle closure is on one line; the anchored multi-line tail
# is the post-seed finite cursor and is retained verbatim for unsupported domains.
optimized = '''	local floor = math.floor
	if count > 67108864 or step > 67108864 or index ~= floor(index) or stride ~= floor(stride)
		or math.abs(x0) > 67108864 or math.abs(x1) > 67108864
		or math.abs(y0) > 67108864 or math.abs(y1) > 67108864 then
'''
legacy_closure = tail.rsplit('\nend', 1)[0]
optimized += '\n'.join('\t' + line for line in legacy_closure.splitlines()) + '\n\tend\n'
optimized += '''	-- Every non-final cell has full width/height. Only the final column/row
	-- can be partial; preserve the original integer expression for those limits.
	local last_w = math.min(step, x1 - (x0 + (nx - 1) * step))
	local last_h = math.min(step, y1 - (y0 + (ny - 1) * step))
	return function()
		if remaining == 0 then return nil end
		local ix, iy = index % nx, floor(index / nx)
		local cx, cy = x0 + ix * step, y0 + iy * step
		local width = ix == nx - 1 and last_w or step
		local height = iy == ny - 1 and last_h or step
		index, remaining = (index + stride) % count, remaining - 1
		return cx + rand(width), cy + rand(height)
	end
end
'''
new_cursor = old_cursor[:old_cursor.index('\treturn function()\n')] + optimized
once(old_cursor, new_cursor)
once('function DecorTopUp.Run(map, pass_edits_already_suspended)\n', '''function DecorTopUp.Run(map, pass_edits_already_suspended)
	-- Bind standard primitives/tables once for this pass, retaining
	-- per-Run lookup and all original call arguments, order and arithmetic.
	local type, tonumber, tostring, ipairs, pairs, pcall = type, tonumber, tostring, ipairs, pairs, pcall
	local math, string, table = math, string, table
''')
once('local get_type = terrain_api.GetTerrainType\n', 'local get_type = terrain_api.GetTerrainType\n\t\t\tlocal has_get_type = type(get_type) == "function"\n')
once('if type(get_type) ~= "function" then return 0 end', 'if not has_get_type then return 0 end')
out.mkdir(parents=True, exist_ok=False)
(out / 'decor_candidate.lua').write_text(candidate, encoding='utf-8')
(out / 'manifest.json').write_text(json.dumps(dict(production_changed=False,
    before_sha256=hashlib.sha256(source.encode()).hexdigest(),
    candidate_sha256=hashlib.sha256(candidate.encode()).hexdigest()), indent=2), encoding='utf-8')
print(out)
