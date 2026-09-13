"""Generate frozen v3 native shadows from the established read-only comparator."""
from pathlib import Path
root=Path(__file__).resolve().parents[3]
source=(root/'_ralph/tmp/under80_20260912/decor_positive_cell_shadow.lua').read_text()
out=root/'_ralph/runs/under80-20260912/artifacts/decor_positive_cell_v3_setup'
out.mkdir(parents=True,exist_ok=False)
def replace_once(text,old,new):
    assert text.count(old)==1,old
    return text.replace(old,new)
source=replace_once(source,"result.variant='v2'","result.variant='v3_workload4096'")
source=replace_once(source,'decor_positive_cell_v2.lua','decor_positive_cell_v3.lua')
source=replace_once(source,'full_queries=copy.spatial_index',
    'admitted=copy.positive_cell_cache~=nil, full_queries=copy.spatial_index')
for reverse in (False,True):
    value=replace_once(source,'local reverse=true','local reverse='+str(reverse).lower())
    (out/('reverse.lua' if reverse else 'forward.lua')).write_text(value)
print('Generated forward/reverse v3-only native shadows; no production changes')
