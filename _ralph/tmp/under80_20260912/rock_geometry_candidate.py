"""Generate a private scalar-reuse Capture; production remains untouched."""
from pathlib import Path
import hashlib
import json
import argparse
p=argparse.ArgumentParser();p.add_argument('--out',required=True);args=p.parse_args()
root=Path(__file__).resolve().parents[3]
source=(root/'Code/sbm_rock_grounding.lua').read_text()
a=source.index('local function Capture(');b=source.index('\nend\n',a)+4
original=source[a:b];candidate=original
edits=[]
def replace(old,new):
 global candidate
 if candidate.count(old)!=1:raise RuntimeError('nonunique source anchor: '+old)
 candidate=candidate.replace(old,new);edits.append((old,new))
serial=0
def read(receiver,method,indent):
 global serial
 serial+=1;name=f'geometry_{serial}';slot=receiver+'_'+method
 lines=[f'local {name}_fn = {receiver}.{method}',f'local {name}',
  f'if reuse_geometry and {name}_fn == NativeGeometry.{slot} and cached_{slot} ~= nil then',
  f'\t{name} = cached_{slot}', 'else',f'\t{name} = {name}_fn({receiver})',
  f'\tif reuse_geometry and {name}_fn == NativeGeometry.{slot} then cached_{slot} = {name} end','end']
 return '\n'.join(indent+line for line in lines),name
roles=[('bounds',n) for n in ('maxz','minz','minx','miny','sizex','sizey')]+[('visual',n) for n in ('z','x','y')]
anchor='\tlocal tile = Global("const").HeightTileSize\n'
replace(anchor,anchor+'\tlocal reuse_geometry = NativeGeometry.Qualify(bounds, visual)\n'+
 '\tlocal '+', '.join('cached_'+r+'_'+m for r,m in roles)+'\n')
s1,v1=read('bounds','maxz','\t');s2,v2=read('visual','z','\t')
replace('\tif bounds:maxz() <= visual:z() + tile then',s1+'\n'+s2+f'\n\tif {v1} <= {v2} + tile then')
# Only canonical native size methods have a documented scalar tuple. Keep the
# literal variadic math.max call for every custom/rebound size method.
old='\tlocal count = math.min(9, math.max(3,\n\t\tmath.ceil(math.max(bounds:sizex(), bounds:sizey()) / (4.0 * tile))))'
s1,v1=read('bounds','sizex','\t\t');s2,v2=read('bounds','sizey','\t\t')
replace(old,'\tlocal count\n\tif reuse_geometry and bounds.sizex == NativeGeometry.bounds_sizex\n'+
 '\t\tand bounds.sizey == NativeGeometry.bounds_sizey then\n'+s1+'\n'+s2+
 f'\n\t\tcount = math.min(9, math.max(3, math.ceil(math.max({v1}, {v2}) / (4.0 * tile))))\n'+
 '\telse\n'+old.replace('local count','count')+'\n\tend')
s1,v1=read('bounds','minx','\t\t');s2,v2=read('bounds','sizex','\t\t')
replace('\t\tlocal x = bounds:minx() + math.floor(bounds:sizex() * (ix + 0.0) / (count + 1) + 0.5)',
 s1+'\n\t\tlocal floor_x = math.floor\n'+s2+f'\n\t\tlocal x = {v1} + floor_x({v2} * (ix + 0.0) / (count + 1) + 0.5)')
s1,v1=read('bounds','miny','\t\t\t');s2,v2=read('bounds','sizey','\t\t\t')
replace('\t\t\tlocal y = bounds:miny() + math.floor(bounds:sizey() * (iy + 0.0) / (count + 1) + 0.5)',
 s1+'\n\t\t\tlocal floor_y = math.floor\n'+s2+f'\n\t\t\tlocal y = {v1} + floor_y({v2} * (iy + 0.0) / (count + 1) + 0.5)')
s1,v1=read('bounds','minz','\t\t\t\t');s2,v2=read('bounds','maxz','\t\t\t\t')
replace('\t\t\t\tlocal hit = obj:IntersectSegment(point_fn(x, y, bounds:minz() - tile),\n\t\t\t\t\tpoint_fn(x, y, bounds:maxz() + tile))',
 '\t\t\t\tlocal segment_fn = obj.IntersectSegment\n'+s1+f'\n\t\t\t\tlocal ray_from = point_fn(x, y, {v1} - tile)\n'+s2+
 f'\n\t\t\t\tlocal ray_to = point_fn(x, y, {v2} + tile)\n\t\t\t\tlocal hit = segment_fn(obj, ray_from, ray_to)')
s1,v1=read('visual','z','\t\t\t\t\t')
replace('\t\t\t\t\tlocal dz = hit:z() - visual:z()',
 '\t\t\t\t\tlocal hit_z = hit:z()\n'+s1+f'\n\t\t\t\t\tlocal dz = hit_z - {v1}')
s1,v1=read('visual','x','\t\t\t\t\t\t');s2,v2=read('visual','y','\t\t\t\t\t\t')
replace('\t\t\t\t\t\tsamples[#samples + 1] = { dx = x - visual:x(), dy = y - visual:y(), dz = dz }',
 '\t\t\t\t\t\tlocal sample_index = #samples + 1\n'+s1+f'\n\t\t\t\t\t\tlocal dx = x - {v1}\n'+s2+
 f'\n\t\t\t\t\t\tlocal dy = y - {v2}\n\t\t\t\t\t\tsamples[sample_index] = {{ dx = dx, dy = dy, dz = dz }}')
s1,v1=read('bounds','maxz','\t\t');s2,v2=read('visual','z','\t\t')
replace('\t\tcontext.objects[obj] = { scale = obj:GetScale(), angle = obj:GetAngle(),\n\t\t\taxis = obj:GetAxis(), top = bounds:maxz() - visual:z(), samples = samples }',
 '\t\tlocal record_objects = context.objects\n\t\tlocal record_scale = obj:GetScale()\n\t\tlocal record_angle = obj:GetAngle()\n\t\tlocal record_axis = obj:GetAxis()\n'+s1+'\n'+s2+
 f'\n\t\trecord_objects[obj] = {{ scale = record_scale, angle = record_angle,\n\t\t\taxis = record_axis, top = {v1} - {v2}, samples = samples }}')
restored=candidate
for old,new in reversed(edits):
 if restored.count(new)!=1:raise RuntimeError('reverse anchor')
 restored=restored.replace(new,old)
assert restored==original and serial==15
out=root/args.out;out.mkdir(parents=True,exist_ok=False)
(out/'accepted.lua').write_text(original+'\n')
(out/'candidate.lua').write_text(candidate+'\n')
sha=lambda s:hashlib.sha256(s.encode()).hexdigest()
(out/'manifest.json').write_text(json.dumps(dict(source_sha256=sha(source),accepted_sha256=sha(original+'\n'),
 candidate_sha256=sha(candidate+'\n'),source_edits=len(edits),read_sites=serial,reverse_exact=True),indent=2))
print('PASS private candidate: '+str(len(edits))+' reversible source edits, 15 read sites')
