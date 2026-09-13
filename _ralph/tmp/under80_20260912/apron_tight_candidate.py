"""Generate a nondeployed tighter bound; no native operation or guard changes."""
import hashlib
import json
from pathlib import Path
import subprocess
root=Path(__file__).resolve().parents[3]
out=root/'_ralph/runs/under80-20260912/artifacts/apron_tight_research'
out.mkdir(parents=True,exist_ok=False)
source=subprocess.check_output(['git','show','56fbf44:Code/sbm_terrain_copy.lua'],cwd=root,text=True)
old=('-- Adaptively biased Q22 coordinates and the unchanged residual certificate bound error\n'
     '\t\t\t\t-- by5/65536 through core0.60, and7/65536 for the remaining qualified cores.\n'
     '\t\t\t\tlocal error_numerator = policy.core_fraction <= 0.60 and 5 or 7')
new=('-- The same Q22/residual domain with tighter propagation and an explicit\n'
     '\t\t\t\t-- polynomial/core rounding bound gives3/65536 through core0.60, else5/65536.\n'
     '\t\t\t\tlocal error_numerator = policy.core_fraction <= 0.60 and 3 or 5')
assert source.count(old)==1
candidate=source.replace(old,new)
(out/'terrain_candidate.lua').write_text(candidate)
template=(root/'_ralph/runs/under80-20260912/artifacts/precision_coordinate_research_3/offline_test.lua').read_text()
for a,b in [('precision_coordinate_research_3','apron_tight_research'),('c4d3e67','56fbf44'),
            ('and 5 or 7','and 3 or 5'),('add==1280 or add==1792','add==768 or add==1280'),
            ('mul==15 or mul==21','mul==9 or mul==15'),('adaptive-Q22 apron','tighter unchanged-Q22 apron'),
            ('0.25,0.6-eps','0.25,0.3,1.0/3.0,0.4,0.5,0.65,0.7,0.6-eps')]:
    assert a in template,a
    template=template.replace(a,b)
(out/'offline_test.lua').write_text(template)
(out/'manifest.json').write_text(json.dumps(dict(baseline='56fbf44',production_changed=False,
    source_sha256=hashlib.sha256(source.encode()).hexdigest(),
    candidate_sha256=hashlib.sha256(candidate.encode()).hexdigest(),
    qualification='Private candidate; conditional proof and offline/native/cold gates are separate'),indent=2))
print('Generated isolated3/5 certificate candidate, all native operations and guards literalv987')
