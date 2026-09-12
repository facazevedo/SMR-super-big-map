"""Uninstalled bracket candidate; never modify a production file."""
import hashlib
import json
from pathlib import Path

ROOT=Path(__file__).resolve().parents[3]
out=ROOT/'_ralph/runs/under80-20260912/artifacts/apron_bracket_research'
source=(ROOT/'Code/sbm_terrain_copy.lua').read_text()
candidate=source
def once(old,new):
    global candidate
    assert candidate.count(old)==1,repr(old)
    candidate=candidate.replace(old,new)

once('-- Certified domain and root/reciprocal residuals bound mask error by1/4096.',
     '-- The same certificate tightens to1/8192 for core in[0.25,0.55].\n'
     '\t\t\t\t-- Other qualified cores retain the original1/4096 bound.\n'
     '\t\t\t\tlocal narrow_error = policy.core_fraction >= 0.25 and policy.core_fraction <= 0.55\n'
     '\t\t\t\tlocal error_divisor = narrow_error and 8192 or 4096\n'
     '\t\t\t\tlocal mask_error_units = narrow_error and 2048 or 4096')
once('api.GridMulDivAdd(sensitivity,1,1,4096);',
     'api.GridMulDivAdd(sensitivity,1,1,mask_error_units);')
once('api.GridMulDivAdd(uncertainty,3,4096,0)',
     'api.GridMulDivAdd(uncertainty,3,error_divisor,0)')
out.mkdir(parents=True,exist_ok=False)
(out/'terrain_candidate.lua').write_text(candidate,encoding='utf-8')
(out/'manifest.json').write_text(json.dumps(dict(production_changed=False,
    before_sha256=hashlib.sha256(source.encode()).hexdigest(),
    candidate_sha256=hashlib.sha256(candidate.encode()).hexdigest()),indent=2))
print(out)
