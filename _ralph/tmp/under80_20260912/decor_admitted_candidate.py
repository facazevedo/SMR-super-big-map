"""Generate v989 from accepted v987 and the unchanged native-verified v3 helper."""
from pathlib import Path
import subprocess
root=Path(__file__).resolve().parents[3]
out=root/'_ralph/runs/under80-20260912/artifacts/decor_admitted_candidate'
out.mkdir(parents=True,exist_ok=False)
base=subprocess.check_output(['git','show','56fbf44:Code/sbm_decor_topup.lua'],cwd=root,text=True)
helper=(root/'_ralph/tmp/under80_20260912/decor_positive_cell_v3.lua').read_text()
assert helper.count('return function(indexed_hit)')==1
helper=helper.replace('return function(indexed_hit)','local function NewPositiveCellQuery(indexed_hit)')
start=base.index('local function circle_hits(')
stop=base.index('\nend',start)+len('\nend')
body=base[start:stop]
assert body.count('then return true end')==1
body=body.replace('then return true end','then return true, c end')
block=('-- DECOR_POSITIVE_CELL_BEGIN\n'+helper+'\n'+body+
       '\ncircle_hits = NewPositiveCellQuery(circle_hits)\n-- DECOR_POSITIVE_CELL_END')
candidate=base[:start]+block+base[stop:]
assert candidate.count('DecorTopUp.VERSION = 10')==1
candidate=candidate.replace('DecorTopUp.VERSION = 10','DecorTopUp.VERSION = 11')
(out/'sbm_decor_topup.lua').write_text(candidate)
print('Generated isolated v989 decor candidate; all other Run/placement source is literal v987')
