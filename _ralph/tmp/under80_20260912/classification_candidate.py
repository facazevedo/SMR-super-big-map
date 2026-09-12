"""Non-deployed immediate classification reuse; preserve full previous artifacts."""
import hashlib
import json
from pathlib import Path

ROOT=Path(__file__).resolve().parents[3]
out=ROOT/'_ralph/runs/under80-20260912/artifacts/classification_reuse_research'

def replace_once(text,old,new):
    assert text.count(old)==1,repr(old)
    return text.replace(old,new)

rock=(ROOT/'Code/sbm_rock_grounding.lua').read_text()
terrain=(ROOT/'Code/sbm_terrain_copy.lua').read_text()
before={'rock':rock,'terrain':terrain}
rock=replace_once(rock,
    'local function Eligible(obj)\n\tif not obj or Clone.ShouldSkipObject(obj) or Clone.IsImportantSectorObject(obj)\n',
    'local function Eligible(obj, checked_skip, checked_important)\n'
    '\tlocal classified_for_transform = checked_skip ~= nil and checked_important ~= nil\n'
    '\t\tand checked_skip == Clone.ShouldSkipObject\n'
    '\t\tand checked_important == Clone.IsImportantSectorObject\n'
    '\tif not obj or (not classified_for_transform\n'
    '\t\tand (Clone.ShouldSkipObject(obj) or Clone.IsImportantSectorObject(obj)))\n')
rock=replace_once(rock,'local function Capture(map, obj)\n',
    '-- Checked predicate identities qualify only an immediate call after both\n'
    '-- returned false for this unchanged object. Default callers and rebound\n'
    '-- classifiers retain the complete classification path.\n'
    'local function Capture(map, obj, checked_skip, checked_important)\n')
rock=replace_once(rock,'\tif not Eligible(obj) then\n',
    '\tif not Eligible(obj, checked_skip, checked_important) then\n')
terrain=replace_once(terrain,
    '\t\t\tlocal ground_ok, ground_err = pcall(grounding.Capture, map, obj)\n',
    '\t\t\t-- Both shared exclusion predicates just returned false; only\n'
    '\t\t\t-- a private-list append intervened. Do not carry this fact past a yield.\n'
    '\t\t\tlocal ground_ok, ground_err = pcall(grounding.Capture, map, obj,\n'
    '\t\t\t\tShouldSkipObject, IsImportantSectorObject)\n')
out.mkdir(parents=True,exist_ok=False)
manifest={'production_changed':False}
for name,text in {'rock':rock,'terrain':terrain}.items():
    (out/(name+'_candidate.lua')).write_text(text,encoding='utf-8')
    manifest[name]={'before_sha256':hashlib.sha256(before[name].encode()).hexdigest(),
        'candidate_sha256':hashlib.sha256(text.encode()).hexdigest()}
(out/'manifest.json').write_text(json.dumps(manifest,indent=2))
print(out)
