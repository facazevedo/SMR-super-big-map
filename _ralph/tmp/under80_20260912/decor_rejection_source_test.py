from pathlib import Path
import json
import subprocess
root=Path(__file__).resolve().parents[3]
art=root/'_ralph/runs/under80-20260912/artifacts/decor_rejection_fusion_2'
manifest=json.loads((art/'manifest.json').read_text())
source=(art/'accepted.lua').read_text();candidate=(art/'candidate.lua').read_text()
assert source==(root/'Code/sbm_decor_topup.lua').read_text()
assert source==subprocess.check_output(['git','show','56fbf44:Code/sbm_decor_topup.lua'],cwd=root,text=True)
reverse=candidate
assert len(manifest['replacements'])==2
for row in reversed(manifest['replacements']):
 assert reverse.count(row['new'])==1
 reverse=reverse.replace(row['new'],row['old'])
assert reverse==source
tail='\t\t\tlocal prefab = weighted_rand(prefabs, prefab_weight_decor, stream.seed())'
before=source[source.index(tail):source.index('\n\t\t-- 5. Vanilla')]
after=candidate[candidate.index(tail):candidate.index('\n\t\tlocal function try_stamp')]
assert before==after.rstrip('\n')+'\n','stamp tail changed'
for key in ('local function circle_hits(', '-- DECOR_FINITE_SITES_BEGIN'):
 end='-- DECOR_OUTPUT_HELPERS_BEGIN' if key.startswith('local') else '-- DECOR_FINITE_SITES_END'
 assert source[source.index(key):source.index(end)]==candidate[candidate.index(key):candidate.index(end)]
assert 'DecorTopUp.VERSION = 10' in candidate
print('PASS private two-edit reconstruction, literal stamping tail/circle/cursor preservation, exact accepted production')
