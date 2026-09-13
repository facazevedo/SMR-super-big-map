"""Private, nondeployed exact-control-flow specialization of finite decor rejection."""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
root=Path(__file__).resolve().parents[3]
p=argparse.ArgumentParser();p.add_argument('--out',default='decor_rejection_fusion');args=p.parse_args()
out=root/'_ralph/runs/under80-20260912/artifacts'/args.out
source=(root/'Code/sbm_decor_topup.lua').read_text()
accepted=subprocess.check_output(['git','show','56fbf44:Code/sbm_decor_topup.lua'],cwd=root,text=True)
assert source==accepted,'Private candidate must start from exact accepted decor'
candidate=source
replacements=[]
def once(old,new):
 global candidate
 assert candidate.count(old)==1,repr(old[:150])
 candidate=candidate.replace(old,new)
 replacements.append(dict(old=old,new=new))

start=source.index('\t\tlocal function try_stamp(marker, sx, sy, site_radius)\n')
tail=source.index('\t\t\tlocal prefab = weighted_rand(prefabs, prefab_weight_decor, stream.seed())',start)
end=source.index('\n\t\t-- 5. Vanilla',tail)
old=source[start:end]
prefix=source[start:tail]
stamp=source[tail:end]
assert stamp.endswith('\t\tend\n')
# Successful tail is byte-identical: only its function header receives the already
# matched list. The original prefix still serves authored/random-annulus attempts.
new='\t\tlocal function stamp_matched(prefabs, sx, sy, site_radius)\n'+stamp
new+='\n'+prefix+'\t\t\treturn stamp_matched(prefabs, sx, sy, site_radius)\n\t\tend\n'
once(old,new)

old='''					local outcome
					if allowed_count > 0 and not allowed_types[terrain_type_at(sx, sy)] then
						outcome = "terrain"
					else
						outcome = try_stamp(template.marker, sx, sy, template.radius)
					end'''
new='''					local outcome
					-- Private finite-loop specialization: identical cache/lookup/branch order,
					-- but rejected candidates do not cross terrain/stamp helper boundaries.
					if allowed_count > 0 then
						local terrain_type
						if type(get_type) ~= "function" then
							terrain_type = 0
						else
							local key = math.floor(sx / type_tile) * 1000003 + math.floor(sy / type_tile)
							local cached = type_cache[key]
							if cached ~= nil then
								terrain_type = cached
							else
								local okt, t = pcall(get_type, map, point_fn(sx, sy))
								t = okt and type(t) == "number" and t or -1
								type_cache[key] = t
								terrain_type = t
							end
						end
						if not allowed_types[terrain_type] then outcome = "terrain" end
					end
					if not outcome then
						local marker, site_radius = template.marker, template.radius
						local prefabs = matches_cache[marker]
						if prefabs == nil then
							prefabs = SafeCall(marker.GetMatchingMarkers, marker, revision, version)
							if type(prefabs) == "table" then matches_cache[marker] = prefabs end
						end
						if type(prefabs) ~= "table" or #prefabs == 0 then
							outcome = "no_match"
						elseif circle_hits(obstruct, sx, sy, site_radius) then
							outcome = "obstruct"
						elseif circle_hits(decorated, sx, sy, site_radius) then
							outcome = "decorated"
						else
							outcome = stamp_matched(prefabs, sx, sy, site_radius)
						end
					end'''
once(old,new)
reverse=candidate
for row in reversed(replacements):
 assert reverse.count(row['new'])==1
 reverse=reverse.replace(row['new'],row['old'])
assert reverse==source
for begin,finish in [('local function circle_hits(', '-- DECOR_OUTPUT_HELPERS_BEGIN'),
 ('-- DECOR_FINITE_SITES_BEGIN','-- DECOR_FINITE_SITES_END')]:
 assert candidate[candidate.index(begin):candidate.index(finish)]==source[source.index(begin):source.index(finish)]
assert candidate.count(stamp)==1,'Successful stamping tail changed or duplicated'
out.mkdir(parents=True,exist_ok=False)
(out/'accepted.lua').write_text(source,encoding='utf-8')
(out/'candidate.lua').write_text(candidate,encoding='utf-8')
terrain_start=source.index('local get_type = terrain_api.GetTerrainType')
terrain_end=source.index('-- Vanilla-like context means',terrain_start)
terrain=source[terrain_start:terrain_end]
assert terrain.count('local type_cache = {}')==1
terrain=terrain.replace('local type_cache = {}','local type_cache = deps.type_cache')
oracle='return function(deps)\n'
oracle+='local terrain_api = {GetTerrainType=deps.get_type}\n'
for key in ('map','point_fn','type_tile','SafeCall','matches_cache','revision','version',
 'circle_hits','obstruct','decorated','allowed_count','allowed_types'):
 oracle+=f'local {key} = deps.{key}\n'
oracle+=terrain+prefix+'\t\t\treturn nil, prefabs\n\t\tend\n'
oracle+='''return function(marker, sx, sy, site_radius)
 if allowed_count > 0 and not allowed_types[terrain_type_at(sx, sy)] then return "terrain" end
 return try_stamp(marker, sx, sy, site_radius)
end
end
'''
(out/'oracle_factory.lua').write_text(oracle,encoding='utf-8')
(out/'manifest.json').write_text(json.dumps(dict(production_changed=False,baseline='56fbf44',
 source_sha256=hashlib.sha256(source.encode()).hexdigest(),candidate_sha256=hashlib.sha256(candidate.encode()).hexdigest(),
 replacements=replacements,successful_tail_unchanged=True,circle_cursor_unchanged=True),indent=2))
print(out)
