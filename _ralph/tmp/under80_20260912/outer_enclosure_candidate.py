"""Generate a NONDEPLOYED outer-mask candidate and reproducible source manifest."""
import hashlib
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
out = ROOT / '_ralph/runs/under80-20260912/artifacts/outer_enclosure_research'
source = (ROOT / 'Code/sbm_terrain_copy.lua').read_text()
candidate = source

def once(old, new):
    global candidate
    assert candidate.count(old) == 1, repr(old)
    candidate = candidate.replace(old, new)

once('\tlocal native_circle_set = Global("GridCircleSet")\n',
     '\tlocal native_circle_set = Global("GridCircleSet")\n\tlocal native_fill = Global("GridFill")\n')
once('\trequire_native("GridCircleSet", native_circle_set)\n',
     '\trequire_native("GridCircleSet", native_circle_set)\n\trequire_native("GridFill", native_fill)\n')
once('\t\t\t\tassert(coarse, "native coarse-mask allocation failed")\n', '''				assert(coarse, "native coarse-mask allocation failed")
				native_fill(coarse, 0)
				-- The enclosure only removes guaranteed-zero cells. All evaluated cells
				-- retain the predecessor expression, order, and U12 rounding below.
				-- Bound arithmetic away from overflow and cancellation; unsupported
				-- numeric domains still evaluate the complete original rectangle.
				local bounded = radius >= 0 and radius <= 65536
					and patch.core_cells >= 0 and patch.core_cells <= radius
					and patch.cx >= -65536 and patch.cx <= 65536
					and patch.cy >= -65536 and patch.cy <= 65536
					and x0 >= -65536 and x1 <= 65536
					and y0 >= -65536 and y1 <= 65536
					and (sample_step == 1 or sample_step == 4)
				local enclosure_radius = radius + 1.0
''')
once('''					local y = y0 + coarse_y * sample_step
					for coarse_x = 0, coarse_width - 1 do
''', '''					local y = y0 + coarse_y * sample_step
					local first_x, last_x = 0, coarse_width - 1
					if bounded then
						local dy = y - patch.cy
						if math.abs(dy) > enclosure_radius then
							last_x = -1
						else
							local span = math.sqrt(math.max(0,
								enclosure_radius * enclosure_radius - dy * dy)) + 2 * sample_step
							first_x = math.max(0, math.floor((patch.cx - span - x0) / sample_step))
							last_x = math.min(last_x, math.ceil((patch.cx + span - x0) / sample_step))
						end
					end
					for coarse_x = first_x, last_x do
''')
once('''						for _, protected in ipairs(protection_blends) do
''', '''						for protected_index = 1, #protection_blends do
''')
once('''							if weight == 0 then break end
							local px, py = x - protected.cx, y - protected.cy
''', '''							if weight == 0 then break end
							local protected = protection_blends[protected_index]
							local px, py = x - protected.cx, y - protected.cy
''')
out.mkdir(parents=True, exist_ok=False)
(out / 'sbm_terrain_copy.lua').write_text(candidate, encoding='utf-8')
(out / 'manifest.json').write_text(json.dumps({
    'status': 'research_only_not_deployed',
    'source_sha256': hashlib.sha256(source.encode()).hexdigest(),
    'candidate_sha256': hashlib.sha256(candidate.encode()).hexdigest(),
}, indent=2), encoding='utf-8')
print(out)
