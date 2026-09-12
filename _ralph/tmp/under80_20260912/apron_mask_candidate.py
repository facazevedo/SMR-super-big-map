"""Non-deployed experiment: native mask plus per-cell rounding uncertainty."""
from pathlib import Path
import hashlib
import json
import argparse

parser = argparse.ArgumentParser()
parser.add_argument('--name', default='native_mask_research')
args = parser.parse_args()

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
body = once(body, 'mask_cells_skipped=0, mask_fast_zero=0, mask_fast_one=0 }',
    'mask_cells_skipped=0, mask_fast_zero=0, mask_fast_one=0,\n'
    '\t\tnative_mask_cells=0, native_mask_patches=0, scalar_mask_patches=0 }')
body = once(body, '\t\t\t\tlocal mask=own(api.NewComputeGrid(w,h,"f",32))\n'
    '\t\t\t\tif not float_source or not seed or not mask then return "native apron grid allocation failed" end\n'
    '\t\t\t\tapi.GridFill(mask,0)',
    '\t\t\t\tlocal mask\n'
    '\t\t\t\tif not float_source or not seed then return "native apron grid allocation failed" end')
c = body.index('\t\t\t\tlocal row_bounds=mask_row_bounds(')
d = body.index('\t\t\t\tlocal cube=own(mask:clone())', c)
scalar_loop = body[c:d]
body = body[:c] + '''\t\t\t\tlocal native_mask,mask_error=NativeApronMask(api,own,candidate,policy,short_radius,long_radius,x0,y0,w,h)
\t\t\t\tif mask_error then return mask_error end
\t\t\t\tlocal mask_samples=0
\t\t\t\tif native_mask then
\t\t\t\t\tmask=native_mask
\t\t\t\t\tstats.native_mask_cells=stats.native_mask_cells+w*h
\t\t\t\t\tstats.native_mask_patches=stats.native_mask_patches+1
\t\t\t\telse
\t\t\t\t\tstats.scalar_mask_patches=stats.scalar_mask_patches+1
\t\t\t\t\tmask=own(api.NewComputeGrid(w,h,"f",32))
\t\t\t\t\tif not mask then return "native apron scalar-mask allocation failed" end
\t\t\t\t\tapi.GridFill(mask,0)
''' + scalar_loop.replace('local mask_samples=0', 'mask_samples=0') + '\t\t\t\tend\n' + body[d:]
body = once(body, '\t\t\t\tapi.GridMulDivAdd(result,H,1,0)\n', '''\t\t\t\tapi.GridMulDivAdd(result,H,1,0)
\t\t\t\t-- Certified domain and root/reciprocal residuals bound mask error by1/4096.
\t\t\t\t-- Cubic Lipschitz bound uses the upper possible local weight, not global 1.
\t\t\t\tlocal uncertainty=own(result:clone())
\t\t\t\tif not uncertainty then return "native apron uncertainty allocation failed" end
\t\t\t\tapi.GridAddMulDiv(uncertainty,plane,-1);api.GridAbs(uncertainty)
\t\t\t\tlocal sensitivity=own(mask:clone())
\t\t\t\tif not sensitivity then return "native apron sensitivity allocation failed" end
\t\t\t\tapi.GridMulDivAdd(sensitivity,1,1,4096);api.GridClamp(sensitivity,0,W)
\t\t\t\tapi.GridMulDivAdd(sensitivity,sensitivity,W,0)
\t\t\t\tapi.GridMulDivAdd(uncertainty,sensitivity,W,0)
\t\t\t\tapi.GridMulDivAdd(uncertainty,3,4096,0)
\t\t\t\tif not native_mask then api.GridFill(uncertainty,0) end
''')
body = once(body, '\t\t\t\t\tapi.GridMulDivAdd(value,1,1,offset)\n',
    '\t\t\t\t\tapi.GridAddMulDiv(value,uncertainty,offset<0 and -1 or 1)\n'
    '\t\t\t\t\tapi.GridMulDivAdd(value,1,1,offset)\n')
body = once(body, 'stats.mask_cells_skipped=stats.mask_cells_skipped+w*h-mask_samples',
    'stats.mask_cells_skipped=stats.mask_cells_skipped+(native_mask and 0 or w*h-mask_samples)')
source = source[:a] + body + source[b:]
source = once(source, '"GridForeach", "GridFill", "GridRound", "GridMinMax", "box", "point"}) do',
    '"GridForeach", "GridFill", "GridRound", "GridMinMax", "GridPow", "box", "point"}) do')
out = ROOT / '_ralph/runs/under80-20260912/artifacts' / args.name
out.mkdir(parents=True, exist_ok=False)
(out / 'terrain_candidate.lua').write_text(source, encoding='utf-8')
(out / 'source_manifest.json').write_text(json.dumps(dict(
    baseline_sha256=hashlib.sha256(baseline.encode()).hexdigest(),
    candidate_sha256=hashlib.sha256(source.encode()).hexdigest(),
    production_changed=False, uncertainty_bound_proof_pending=True), indent=2))
print(out / 'terrain_candidate.lua')
