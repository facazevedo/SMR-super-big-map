"""Non-deployed experiment: native mask plus per-cell rounding uncertainty."""
from pathlib import Path
import hashlib
import json

ROOT = Path(__file__).resolve().parents[3]
source = (ROOT / 'Code/sbm_terrain_copy.lua').read_text()
baseline = source
a = source.index('local function RasterNaturalMountainBaseAprons(')
b = source.index('local function CreateNaturalMountainBaseBuildableAprons(', a)
body = source[a:b]

def once(text, old, new):
    assert text.count(old) == 1, repr(old)
    return text.replace(old, new)

helper = (Path(__file__).with_name('native_apron_mask.lua')).read_text()
helper = helper[helper.index('return function('):].replace('return function(', 'local NativeApronMask = function(', 1)
body = once(body, '\tlocal W, H = 16777216, 256\n',
    '\tlocal W, H = 16777216, 256\n' + '\n'.join('\t'+line for line in helper.splitlines())+'\n')
body = once(body, '"GridFill","GridRound","GridMinMax","box","point"',
    '"GridFill","GridRound","GridMinMax","GridPow","box","point"')
c = body.index('\t\t\t\tlocal row_bounds=mask_row_bounds(')
d = body.index('\t\t\t\tlocal cube=own(mask:clone())', c)
body = body[:c] + '''\t\t\t\tmask=NativeApronMask(api,own,candidate,policy,short_radius,long_radius,x0,y0,w,h)
\t\t\t\tlocal mask_samples=0
''' + body[d:]
body = once(body, '\t\t\t\tapi.GridMulDivAdd(result,H,1,0)\n', '''\t\t\t\tapi.GridMulDivAdd(result,H,1,0)
\t\t\t\t-- RESEARCH bound: |mask error| <= 1/4096; not yet production-certified.
\t\t\t\t-- Cubic Lipschitz bound uses the upper possible local weight, not global 1.
\t\t\t\tlocal uncertainty=own(result:clone())
\t\t\t\tapi.GridAddMulDiv(uncertainty,plane,-1);api.GridAbs(uncertainty)
\t\t\t\tlocal sensitivity=own(mask:clone())
\t\t\t\tapi.GridMulDivAdd(sensitivity,1,1,4096);api.GridClamp(sensitivity,0,W)
\t\t\t\tapi.GridMulDivAdd(sensitivity,sensitivity,W,0)
\t\t\t\tapi.GridMulDivAdd(uncertainty,sensitivity,W,0)
\t\t\t\tapi.GridMulDivAdd(uncertainty,3,4096,0)
''')
body = once(body, '\t\t\t\t\tapi.GridMulDivAdd(value,1,1,offset)\n',
    '\t\t\t\t\tapi.GridAddMulDiv(value,uncertainty,offset<0 and -1 or 1)\n'
    '\t\t\t\t\tapi.GridMulDivAdd(value,1,1,offset)\n')
source = source[:a] + body + source[b:]
out = ROOT / '_ralph/runs/under80-20260912/artifacts/native_mask_research'
out.mkdir(parents=True, exist_ok=False)
(out / 'terrain_candidate.lua').write_text(source, encoding='utf-8')
(out / 'source_manifest.json').write_text(json.dumps(dict(
    baseline_sha256=hashlib.sha256(baseline.encode()).hexdigest(),
    candidate_sha256=hashlib.sha256(source.encode()).hexdigest(),
    production_changed=False, uncertainty_bound_proof_pending=True), indent=2))
print(out / 'terrain_candidate.lua')
