"""Generate an isolated adaptively biased Q22 apron candidate and probes."""
import hashlib
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
TMP = Path(__file__).resolve().parent
research_name = 'precision_coordinate_research_3'
out = ROOT / '_ralph/runs/under80-20260912/artifacts' / research_name
source = (ROOT / 'Code/sbm_terrain_copy.lua').read_text()
candidate = source

def once(old, new):
    global candidate
    assert candidate.count(old) == 1, repr(old)
    candidate = candidate.replace(old, new)

once('local S, W = 1048576, 16777216', 'local Q, S, W = 4194304, 1048576, 16777216')
once('or short_radius<=0 or long_radius<=0 or w<2 or h<2',
     'or short_radius<0.00000095367431640625 or long_radius<0.00000095367431640625 or w<2 or h<2')
once('if math.abs(xv[x]+yv[y])>4 then return nil end',
     'if math.abs(xv[x]+yv[y])>4 then return nil end\n'
     '\t            -- Quantized corner sums must still be exactly representable f32 integers.\n'
     '\t            if math.abs(math.floor(xv[x]*Q+0.5)+math.floor(yv[y]*Q+0.5))>W then return nil end')
once('local function field(values,axis)\n\t        local grid=own(api.NewComputeGrid(w,h,\'f\',32))',
     'local function field(values,axis)\n'
     '\t        -- The native setter is unsigned even for f32. Adapt the positive\n'
     '\t        -- bias to this axis, then decode with native signed arithmetic.\n'
     '\t        local encoded_values,minimum,maximum={},nil,nil\n'
     '\t        for index,value in pairs(values) do\n'
     '\t            local encoded=math.floor(value*Q+0.5)\n'
     '\t            encoded_values[index]=encoded\n'
     '\t            minimum=minimum and math.min(minimum,encoded) or encoded\n'
     '\t            maximum=maximum and math.max(maximum,encoded) or encoded\n'
     '\t        end\n'
     '\t        if maximum-minimum>W then return nil end\n'
     '\t        local grid=own(api.NewComputeGrid(w,h,\'f\',32))')
once('for index,value in pairs(values) do\n\t            local encoded=math.floor(value*S+0.5)+4*S',
     'for index,value in pairs(encoded_values) do\n\t            local encoded=value-minimum')
once('\t        api.GridMulDivAdd(grid,1,1,-4*S)\n\t        api.GridMulDivAdd(grid,1,S,0)',
     '\t        api.GridMulDivAdd(grid,1,1,minimum)\n\t        api.GridMulDivAdd(grid,1,Q,0)')
once('-- Certified domain and root/reciprocal residuals bound mask error by1/4096.',
     '-- Adaptively biased Q22 coordinates and the unchanged residual certificate bound error\n'
     '\t\t\t\t-- by5/65536 through core0.60, and7/65536 for the remaining qualified cores.\n'
     '\t\t\t\tlocal error_numerator = policy.core_fraction <= 0.60 and 5 or 7')
once('api.GridMulDivAdd(sensitivity,1,1,4096);',
     'api.GridMulDivAdd(sensitivity,1,1,error_numerator*256);')
once('api.GridMulDivAdd(uncertainty,3,4096,0)',
     'api.GridMulDivAdd(uncertainty,3*error_numerator,65536,0)')
out.mkdir(parents=True, exist_ok=False)
generated = {'terrain_candidate.lua': candidate}
for name, template in [('offline_test.lua', 'apron_bracket_general_test.lua'),
                       ('native_probe.lua', 'apron_bracket_general_native.lua'),
                       ('shadow.lua', 'apron_bracket_general_shadow.lua')]:
    text = (TMP / template).read_text().replace('apron_bracket_general_research', research_name)
    text = text.replace('and 9 or 12', 'and 5 or 7')
    text = text.replace('add==2304 or add==3072', 'add==1280 or add==1792')
    text = text.replace('mul==27 or mul==36', 'mul==15 or mul==21')
    text = text.replace('general apron bracket:', 'adaptive-Q22 apron:')
    generated[name] = text
for name, text in generated.items():
    (out / name).write_text(text, encoding='utf-8')
(out / 'manifest.json').write_text(json.dumps(dict(production_changed=False,
    before_sha256=hashlib.sha256(source.encode()).hexdigest(),
    generated_sha256={name: hashlib.sha256(text.encode()).hexdigest() for name,text in generated.items()}), indent=2))
print(out)
