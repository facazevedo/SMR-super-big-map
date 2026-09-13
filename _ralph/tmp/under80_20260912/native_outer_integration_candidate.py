"""Generate an undeployed integration candidate; never modifies production files."""
import difflib
import argparse
import hashlib
import json
from pathlib import Path

root = Path(__file__).resolve().parents[3]
parser = argparse.ArgumentParser()
parser.add_argument('--name', default='native_outer_integration_research')
args = parser.parse_args()
out = root / '_ralph/runs/under80-20260912/artifacts' / args.name
source = (root / 'Code/sbm_terrain_copy.lua').read_text()
kernel = (root / '_ralph/tmp/under80_20260912/native_outer_mask.lua').read_text()
candidate = source

def once(old, new):
    global candidate
    assert candidate.count(old) == 1, repr(old)
    candidate = candidate.replace(old, new)

# Research output retains the private kernel warning. Promotion requires its
# full source/numeric/failure review and frozen six-site shadow evidence first.
body = kernel[kernel.index('return function(api, row, scalar, epsilon_numerator)'):]
body = body.replace('return function(api, row, scalar, epsilon_numerator)',
                    'local NativeOuterMask = function(api, row, scalar, epsilon_numerator)', 1)
assert body.count('experimental_epsilon_numerator = epsilon_numerator, certificate_proved = false') == 1
body = body.replace('experimental_epsilon_numerator = epsilon_numerator, certificate_proved = false',
    'experimental_epsilon_numerator = epsilon_numerator, certificate_proved = false, domain_qualified = false')
assert body.count('    local owned, lookup = {}, {}') == 1
body = body.replace('    local owned, lookup = {}, {}',
    '    stats.domain_qualified = true\n    local owned, lookup = {}, {}')
once('\tlocal function apply_native_patch(patch)\n',
    '\t-- PRIVATE INTEGRATION RESEARCH: numeric certificate/source review still gates promotion.\n'
    + '\n'.join('\t' + line if line else '' for line in body.rstrip().splitlines()) + '\n\n'
    + '\tlocal native_mask_failure\n\tlocal function apply_native_patch(patch)\n')

anchor = '\tlocal native_is_compute = Global("IsComputeGrid")\n'
extra = '\tlocal mask_api = {}\n\tfor _, name in ipairs({ "NewComputeGrid", "GridMulDivAdd",\n'
extra += '\t\t"GridAdd", "GridAddMulDiv", "GridPow", "GridAbs", "GridMask", "GridClamp",\n'
extra += '\t\t"GridRound", "GridCount", "GridForeach", "point", "box" }) do\n'
extra += '\t\tmask_api[name] = Global(name)\n\tend\n'
once(anchor, anchor + extra)
anchor = '\trequire_native("IsComputeGrid", native_is_compute)\n'
once(anchor, anchor + '\tfor name, value in pairs(mask_api) do require_native(name, value) end\n'
    # Missing globals are absent from the table; validate the added primitives
    # by name explicitly rather than relying on pairs to enumerate nil entries.
    + '\tfor _, name in ipairs({ "GridPow", "GridMask", "GridRound", "GridForeach" }) do\n'
    + '\t\trequire_native(name, mask_api[name])\n\tend\n')

start = candidate.index('\t\t\t\tlocal cached_zero_sine, cached_zero_harmonic\n',
                        candidate.index('local function apply_native_patch'))
end = candidate.index('\t\t\t\tsamples = coarse_width * coarse_height', start)
original_loop = candidate[start:end]
cell_start = original_loop.index('local dx, dy = x - patch.cx, y - patch.cy')
cell_end = original_loop.index('coarse:set(coarse_x, coarse_y,', cell_start)
cell = original_loop[cell_start:cell_end] + 'return math.floor(weight * native_weight_scale + 0.5)\n'
# Keep the literal scalar loop first, including its cache placement, so existing
# source-extracted predecessor tests continue to test the actual scalar branch.
replacement = '\t\t\t\tlocal function fill_scalar_coarse()\n' + original_loop + '\t\t\t\tend\n'
replacement += '''                local cached_zero_sine, cached_zero_harmonic
                local function scalar_native_weight(cx, cy)
                    local x, y = x0 + cx * sample_step, y0 + cy * sample_step
'''
replacement += cell + '''                end
                local native_coarse, mask_stats, mask_error = NativeOuterMask(mask_api, {
                    patch = patch, guards = protection_blends, radius = radius,
                    base_transition = base_transition, irregularity = transition_irregularity,
                    x0 = x0, y0 = y0, width = coarse_width, height = coarse_height,
                    sample_step = sample_step, atan2_present = math.atan2 ~= nil,
                }, scalar_native_weight)
                if native_coarse then
                    coarse = own(native_coarse)
                elseif mask_stats.domain_qualified then
                    -- Never install a partial working grid after a native failure.
                    native_mask_failure = tostring(mask_error or "native outer mask returned no result")
                    return nil, nil, nil
                else
                    -- Numeric nonqualification selects the original scalar mask,
                    -- matching the accepted apron mask's domain dispatch contract.
                    fill_scalar_coarse()
                end
'''
candidate = candidate[:start] + replacement + candidate[end:]
anchor = '\t\t\tlocal changed, raster_cells, mask_samples = apply_native_patch(patch)\n'
once(anchor, anchor + '\t\t\tif native_mask_failure then return end\n')
anchor = '\tif type(resume) == "function" then pcall(resume, "SBMOuterResourceTerrain") end\n'
once(anchor, anchor + '\tif native_mask_failure then ok_apply, apply_error = false, native_mask_failure end\n')

out.mkdir(parents=True, exist_ok=False)
(out / 'sbm_terrain_copy.lua').write_text(candidate)
(out / 'candidate.patch').write_text(''.join(difflib.unified_diff(source.splitlines(True),
    candidate.splitlines(True), fromfile='a/Code/sbm_terrain_copy.lua', tofile='b/Code/sbm_terrain_copy.lua')))
(out / 'manifest.json').write_text(json.dumps({
    'status': 'research_only_not_deployed',
    'source_sha256': hashlib.sha256(source.encode()).hexdigest(),
    'kernel_sha256': hashlib.sha256(kernel.encode()).hexdigest(),
    'candidate_sha256': hashlib.sha256(candidate.encode()).hexdigest(),
    'required_next': ['source and transaction review', 'offline full regression',
        'actual integrated failure injection', 'native full parity', 'cold acceptance'],
}, indent=2))
print(out)
