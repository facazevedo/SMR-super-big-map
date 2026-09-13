"""Exact production integration, unchanged callers/RNG and proven helper audit."""
from pathlib import Path
import subprocess
root=Path(__file__).resolve().parents[3]
source=(root/'Code/sbm_decor_topup.lua').read_text()
artifact=(root/'_ralph/runs/under80-20260912/artifacts/decor_admitted_candidate/sbm_decor_topup.lua').read_text()
assert source==artifact,'Actual candidate differs from generated reviewed source'
base=subprocess.check_output(['git','show','56fbf44:Code/sbm_decor_topup.lua'],cwd=root,text=True)
begin='-- DECOR_POSITIVE_CELL_BEGIN\n'
end='\n-- DECOR_POSITIVE_CELL_END'
block=source.split(begin)[1].split(end)[0]
raw=base[base.index('local function circle_hits('):]
raw=raw[:raw.index('\nend')+4]
helper=(root/'_ralph/tmp/under80_20260912/decor_positive_cell_v3.lua').read_text()
expected=helper.replace('return function(indexed_hit)','local function NewPositiveCellQuery(indexed_hit)')+'\n'+raw.replace('then return true end','then return true, c end')+'\ncircle_hits = NewPositiveCellQuery(circle_hits)'
assert block==expected,'Native-tested helper or indexed predicate changed'
restored=source.replace(begin+block+end,raw).replace('DecorTopUp.VERSION = 11','DecorTopUp.VERSION = 10')
assert restored==base,'Unrelated Run/candidate/placement/RNG change'
for name in ('Code/sbm_terrain_copy.lua','Code/sbm_map_generation.lua','items.lua'):
    old=subprocess.check_output(['git','show','56fbf44:'+name],cwd=root,text=True)
    assert (root/name).read_text()==old,name+' changed'
print('PASS actual integrated v3 helper/indexed predicate, unchanged complete Run/RNG/terrain/rebuild sources')
