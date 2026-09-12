"""Nondeployed whole-certified-domain bracket; the default core is covered."""
import hashlib
import json
from pathlib import Path

ROOT=Path(__file__).resolve().parents[3]
out=ROOT/'_ralph/runs/under80-20260912/artifacts/apron_bracket_general_research'
source=(ROOT/'Code/sbm_terrain_copy.lua').read_text()
candidate=source
def once(old,new):
    global candidate
    assert candidate.count(old)==1,repr(old)
    candidate=candidate.replace(old,new)

once('-- Certified domain and root/reciprocal residuals bound mask error by1/4096.',
     '-- The same residual/domain certificate bounds error by9/65536\n'
     '\t\t\t\t-- for core<=0.60, and12/65536 for the remaining qualified cores.\n'
     '\t\t\t\t-- U24 mask allowances and native API arguments stay integral.\n'
     '\t\t\t\tlocal error_numerator = policy.core_fraction <= 0.60 and 9 or 12')
once('api.GridMulDivAdd(sensitivity,1,1,4096);',
     'api.GridMulDivAdd(sensitivity,1,1,error_numerator*256);')
once('api.GridMulDivAdd(uncertainty,3,4096,0)',
     'api.GridMulDivAdd(uncertainty,3*error_numerator,65536,0)')
out.mkdir(parents=True,exist_ok=False)
(out/'terrain_candidate.lua').write_text(candidate,encoding='utf-8')
(out/'manifest.json').write_text(json.dumps(dict(production_changed=False,
    before_sha256=hashlib.sha256(source.encode()).hexdigest(),
    candidate_sha256=hashlib.sha256(candidate.encode()).hexdigest()),indent=2))
print(out)
