"""Mechanically generate private local-error candidate from accepted v987."""
import hashlib
import json
from pathlib import Path
import subprocess

root = Path(__file__).resolve().parents[3]
out = root/'_ralph/runs/under80-20260912/artifacts/apron_local_research'
source = subprocess.check_output(['git','show','56fbf44:Code/sbm_terrain_copy.lua'],cwd=root,text=True)
changes = []
def replace(old,new):
    global source
    assert source.count(old)==1, old
    changes.append(dict(old=old,new=new))
    source=source.replace(old,new)

replace('\t    return polynomial\n', '''\t    -- Private local certificate: reuse consumed cube; original weight is unchanged.
\t    local c=policy.core_fraction
\t    local d=math.floor(((0.0000056+0.0000018/(c+0.0))/(1.0-c))*W+6)+2
\t    cube:copyrect(radius,api.box(0,0,w,h),api.point(0,0))
\t    api.GridMulDivAdd(cube,-1,1,1)
\t    api.GridMulDivAdd(cube,radius,1,0)
\t    api.GridMulDivAdd(cube,W,1,d+2)
\t    api.GridClamp(cube,0,W/4)
\t    api.GridMulDivAdd(cube,cube,W,0)
\t    api.GridMulDivAdd(cube,90*d,W,240)
\t    return polynomial,nil,cube
''')
replace('local native_mask,mask_error=NativeApronMask(',
        'local native_mask,mask_error,local_error=NativeApronMask(')
replace('if mask_error then return mask_error end',
        'if mask_error then return mask_error end\n\t\t\t\tif native_mask and not local_error then return "native apron local error missing" end')
replace('api.GridMulDivAdd(sensitivity,1,1,error_numerator*256);api.GridClamp(sensitivity,0,W)',
'''if native_mask then api.GridAddMulDiv(sensitivity,local_error,1,3)
\t\t\t\telse api.GridMulDivAdd(sensitivity,1,1,error_numerator*256) end
\t\t\t\tapi.GridClamp(sensitivity,0,W)''')
replace('api.GridMulDivAdd(uncertainty,3*error_numerator,65536,0)',
'''if native_mask then api.GridMulDivAdd(uncertainty,local_error,W,0)
\t\t\t\telse api.GridMulDivAdd(uncertainty,3*error_numerator,65536,0) end''')
replace('local margin=ceil((max(math.abs(relative_min),math.abs(relative_max))+magnitude)*H/524288)+4',
'''-- A separate H unit covers newly introduced tiny arithmetic terms.
\t\t\t\tlocal margin=ceil((max(math.abs(relative_min),math.abs(relative_max))+magnitude)*H/524288)+4+(native_mask and 1 or 0)''')

out.mkdir(parents=True,exist_ok=False)
(out/'terrain_candidate.lua').write_text(source)
(out/'manifest.json').write_text(json.dumps(dict(baseline='56fbf44',production_changed=False,
    candidate_sha256=hashlib.sha256(source.encode()).hexdigest(),changes=changes,
    qualification='Private conditional certificate; native and cold gates NOT run'),indent=2))
print('Generated private local-error candidate, no deployment or production edits')

