"""Generate an isolated native-list candidate, leaving production unchanged."""
import argparse
import hashlib
import json
from pathlib import Path

ROOT=Path(__file__).resolve().parents[3]
parser=argparse.ArgumentParser()
parser.add_argument('--name',default='class_batch_research')
args=parser.parse_args()
OUT=ROOT/'_ralph/runs/under80-20260912/artifacts'/args.name
original={name:(ROOT/'Code'/('sbm_'+name+'.lua')).read_text() for name in ['engine','object_clone']}
candidate=original.copy()
helper=Path(__file__).with_name('class_batch_helper.lua').read_text()
def once(name,old,new):
    assert candidate[name].count(old)==1,repr(old)
    candidate[name]=candidate[name].replace(old,new)

once('engine','-- Best-effort world position of an object:',helper+'\n-- Best-effort world position of an object:')
once('object_clone','local IsKindOfSafe = Engine.IsKindOf\n',
     'local IsKindOfSafe = Engine.IsKindOf\nlocal FirstKindOfSafe = Engine.FirstKindOf\n'
     '-- Older/custom Engine tables retain the original ordered scalar behavior.\n'
     'if type(FirstKindOfSafe) ~= "function" then\n'
     '\tFirstKindOfSafe = function(obj, classes, single_kind)\n'
     '\t\tlocal last_value\n'
     '\t\tfor i = 1, #classes do\n'
     '\t\t\tlast_value = single_kind(obj, classes[i])\n'
     '\t\t\tif last_value then return classes[i], last_value end\n'
     '\t\tend\n\t\treturn nil, last_value\n\tend\nend\n')
for name in ['mystery_kinds','skip_clone_kinds']:
    once('object_clone', '\tfor i = 1, #'+name+' do\n\t\tif IsKindOfSafe(obj, '+name+'[i]) then\n'
         '\t\t\treturn true\n\t\tend\n\tend\n\treturn false\n' if name=='mystery_kinds' else
         '\tfor i = 1, #'+name+' do\n\t\tif IsKindOfSafe(obj, '+name+'[i]) then\n'
         '\t\t\treturn true\n\t\tend\n\tend\n\n\treturn false\n',
         '\treturn FirstKindOfSafe(obj, '+name+', IsKindOfSafe) ~= nil\n')
once('object_clone', '\tfor i = 1, #underground_access_clone_kinds do\n'
     '\t\tlocal kind = underground_access_clone_kinds[i]\n'
     '\t\tif IsKindOfSafe(obj, kind) then\n\t\t\treturn true, "kind", kind\n\t\tend\n\tend\n',
     '\tlocal kind = FirstKindOfSafe(obj, underground_access_clone_kinds, IsKindOfSafe)\n'
     '\tif kind then return true, "kind", kind end\n')
once('object_clone', '\t\t\tfor i = 1, #underground_access_clone_kinds do\n'
     '\t\t\t\tlocal kind = underground_access_clone_kinds[i]\n'
     '\t\t\t\tif IsKindOfSafe(parent, kind) then\n'
     '\t\t\t\t\treturn true, "parent_kind", kind\n\t\t\t\tend\n\t\t\tend\n',
     '\t\t\tlocal kind = FirstKindOfSafe(parent, underground_access_clone_kinds, IsKindOfSafe)\n'
     '\t\t\tif kind then return true, "parent_kind", kind end\n')
once('object_clone','local function IsResourceDepositMarker(obj)\n'
     '\treturn IsKindOfSafe(obj, "SurfaceDepositMarker")\n'
     '\t\tor IsKindOfSafe(obj, "SubsurfaceDepositMarker")\n'
     '\t\tor IsKindOfSafe(obj, "TerrainDepositMarker")\nend\n',
     'local resource_marker_kinds = { "SurfaceDepositMarker", "SubsurfaceDepositMarker", "TerrainDepositMarker" }\n'
     'local spawned_deposit_kinds = { "Deposit", "SubsurfaceAnomaly", "SubsurfaceAnomalyMarker", "EffectDepositMarker" }\n'
     'local function IsResourceDepositMarker(obj)\n'
     '\tlocal _, matched = FirstKindOfSafe(obj, resource_marker_kinds, IsKindOfSafe)\n'
     '\treturn matched\nend\n')
once('object_clone','\t\tif IsKindOfSafe(obj, "Deposit")\n'
     '\t\t\tor IsKindOfSafe(obj, "SubsurfaceAnomaly")\n'
     '\t\t\tor IsKindOfSafe(obj, "SubsurfaceAnomalyMarker")\n'
     '\t\t\tor IsKindOfSafe(obj, "EffectDepositMarker") then\n',
     '\t\tif FirstKindOfSafe(obj, spawned_deposit_kinds, IsKindOfSafe) then\n')
OUT.mkdir(parents=True,exist_ok=False)
manifest={'production_changed':False}
for name,text in candidate.items():
    (OUT/(name+'_candidate.lua')).write_text(text,encoding='utf-8')
    manifest[name]={'before_sha256':hashlib.sha256(original[name].encode()).hexdigest(),
                    'candidate_sha256':hashlib.sha256(text.encode()).hexdigest()}
(OUT/'manifest.json').write_text(json.dumps(manifest,indent=2))
print(OUT)
