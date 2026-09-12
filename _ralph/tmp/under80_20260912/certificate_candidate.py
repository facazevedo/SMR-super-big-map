"""Build a non-deployed native signed-step certificate experiment."""
import hashlib
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
source = (ROOT / 'Code/sbm_terrain_copy.lua').read_text()
before = source

def once(text, old, new):
    assert text.count(old) == 1, repr(old)
    return text.replace(old, new)

def block(start, end, transform):
    global source
    a, b = source.index(start), source.index(end, source.index(start))
    source = source[:a] + transform(source[a:b]) + source[b:]

def native(text):
    text = once(text, 'if perp1 < perp0 then return {}, stats end',
                'if perp1 < perp0 then return {}, stats, {} end')
    text = once(text,
        '\t\t\t\tapi.GridMulDivAdd(a, -1, 1, 0); api.GridAdd(magnitude, a); api.GridAbs(magnitude)',
        '\t\t\t\tapi.GridMulDivAdd(a, -1, 1, 0); api.GridAdd(magnitude, a)\n'
        '\t\t\t\tlocal signed = own(magnitude:clone())\n'
        '\t\t\t\tif not signed then return nil, "native crease signed clone failed" end\n'
        '\t\t\t\tapi.GridAbs(magnitude)')
    text = once(text,
        '\t\t\t\tapi.GridForeach(magnitude, function(jump, x, y)\n\t\t\t\t\tif callback_error then return end',
        '\t\t\t\t-- Bias and double exact signed U16 differences. Accepted codes are >=2;\n'
        '\t\t\t\t-- zero remains rejected under either native lower-bound convention.\n'
        '\t\t\t\tapi.GridMulDivAdd(signed, 2, 1, 131072)\n'
        '\t\t\t\tapi.GridMulDivAdd(signed, accepted, 1, 0)\n'
        '\t\t\t\tlocal factor = width == 1 and 1 or width == 2 and 131072 or 17179869184\n'
        '\t\t\t\tapi.GridForeach(signed, function(encoded, x, y)\n'
        '\t\t\t\t\tif callback_error then return end\n'
        '\t\t\t\t\tif type(encoded) ~= "number" or encoded ~= math.floor(encoded)\n'
        '\t\t\t\t\t\tor encoded % 2 ~= 0 or encoded < 2 or encoded > 262142 then\n'
        '\t\t\t\t\t\tcallback_error = "native crease signed certificate invalid"; return\n'
        '\t\t\t\t\tend\n'
        '\t\t\t\t\tlocal code = encoded / 2\n'
        '\t\t\t\t\tlocal jump = math.abs(code - 65536)')
    text = once(text,
        '\t\t\t\t\tif not seen[perp] then\n'
        '\t\t\t\t\t\tseen[perp] = true; rows[along][#rows[along] + 1] = perp\n'
        '\t\t\t\t\t\tstats.candidates = stats.candidates + 1\n\t\t\t\t\tend',
        '\t\t\t\t\tlocal prior = seen[perp]\n'
        '\t\t\t\t\tif not prior then\n'
        '\t\t\t\t\t\trows[along][#rows[along] + 1] = perp\n'
        '\t\t\t\t\t\tstats.candidates = stats.candidates + 1\n\t\t\t\t\tend\n'
        '\t\t\t\t\t-- Three 17-bit width slots fit exactly in binary64 as well as int64.\n'
        '\t\t\t\t\tseen[perp] = (prior or 0) + code * factor')
    text = once(text, '\t\treturn rows, stats', '\t\treturn rows, stats, row_seen')
    text = once(text, 'local ok, rows, detail = pcall(work)', 'local ok, rows, detail, certificates = pcall(work)')
    return once(text, '\treturn rows, detail', '\treturn rows, detail, certificates')

block('local function BuildHeightStepDiscoveryIndex(', '-- Batched translation of independent rows', native)

def guide(text):
    text = once(text, 'register_domain(axis, edge, lo, hi, step, rows)',
        'register_domain(axis, edge, lo, hi, step, rows, certificates)')
    text = once(text, '{ lo = lo, hi = hi, rows = rows }',
        '{ lo = lo, hi = hi, rows = rows, certificates = certificates }')
    return once(text, 'return domain.rows[along] or empty',
        'return domain.rows[along] or empty, domain.certificates and (domain.certificates[along] or empty)')

block('\tlocal function NewHeightStepRefinementGuide(', '\t-- HEIGHT_REFINEMENT_GUIDE_END', guide)

# Reuse the independently checked research decoder literally, only rename it.
prototype = (ROOT / '_ralph/tmp/under80_20260912/certified_steps.lua').read_text()
a = prototype.index('local function refine(')
b = prototype.index('\nreturn {scan=', a)
helper = prototype[a:b].replace('local function refine(', 'local function RefineCertifiedHeightStep(', 1)
helper = '\n'.join('\t' + line for line in helper.splitlines()) + '\n'
source = once(source, '\tlocal function RefineIndexedHeightStep(at, track, along, predicted, lo, hi, max_width, threshold, indexed)\n',
    helper + '\tlocal function RefineIndexedHeightStep(at, track, along, predicted, lo, hi, max_width, threshold, indexed, certificates)\n'
    '\t\tif certificates then\n'
    '\t\t\treturn RefineCertifiedHeightStep(track, predicted, lo, hi, max_width, indexed, certificates)\n'
    '\t\tend\n')

def scan(text):
    text = once(text, 'scan_line_range(row, axis, along, perp0, perp1, edge)',
        'scan_line_range(row, axis, along, perp0, perp1, edge, certificates)')
    branch = '''
        if certificates then
            local before = edge == "left" or edge == "top"
            for perp = perp0, perp1 do
                local word = certificates[perp] or 0
                for width = 1, max_width do
                    local code = word % 131072
                    word = math.floor(word / 131072)
                    if code ~= 0 then
                        local delta = code - 65536
                        local low_before = delta > 0
                        if wide_ring_only or (before and low_before) or (not before and not low_before) then
                            offer_candidate(row, axis, perp, width, edge, low_before, math.abs(delta))
                        end
                    end
                end
            end
            return
        end
'''.replace('    ', '\t')
    return once(text, '\t\tlocal max_width = wide_ring_only and 1 or 3\n',
        '\t\tlocal max_width = wide_ring_only and 1 or 3\n' + branch.lstrip('\n'))

block('\tlocal function scan_line_range(', '\tlocal function collect_axis(', scan)

def collect(text):
    text = once(text, 'local rows, detail = BuildHeightStepDiscoveryIndex(',
        'local rows, detail, certificates = BuildHeightStepDiscoveryIndex(')
    text = once(text, '\t\t\treturn rows\n', '\t\t\treturn rows, certificates\n')
    text = once(text, 'local before = index(before_perp0, before_perp1)',
        'local before, before_certificates = index(before_perp0, before_perp1)')
    text = once(text, 'local after = index(after_perp0, after_perp1)',
        'local after, after_certificates = index(after_perp0, after_perp1)')
    text = once(text, 'sample_step, before)', 'sample_step, before, before_certificates)')
    text = once(text, 'sample_step, after)', 'sample_step, after, after_certificates)')
    text = once(text, 'scan_line_range(row, axis, along, perp, perp, before_edge)',
        'scan_line_range(row, axis, along, perp, perp, before_edge, before_certificates and before_certificates[along])')
    return once(text, 'scan_line_range(row, axis, along, perp, perp, after_edge)',
        'scan_line_range(row, axis, along, perp, perp, after_edge, after_certificates and after_certificates[along])')

block('\tlocal function collect_axis(', '\tlocal function refine_step(', collect)

def refine(text):
    text = once(text,
        '\t\tlocal indexed = refinement_guide and refinement_guide.Candidates(track, along,\n'
        '\t\t\tlo, hi, hi + max_width + 1)',
        '\t\tlocal indexed, certificates\n'
        '\t\tif refinement_guide then\n'
        '\t\t\tindexed, certificates = refinement_guide.Candidates(track, along, lo, hi, hi + max_width + 1)\n'
        '\t\tend')
    return once(text, 'max_width, threshold, indexed)', 'max_width, threshold, indexed, certificates)')

block('\tlocal function refine_step(', '\tlocal function validate_sampled_track(', refine)
out = ROOT / '_ralph/runs/under80-20260912/artifacts/certified_steps_research'
out.mkdir(parents=True, exist_ok=False)
(out / 'terrain_candidate.lua').write_text(source, encoding='utf-8')
(out / 'source_manifest.json').write_text(json.dumps(dict(
    baseline_sha256=hashlib.sha256(before.encode()).hexdigest(),
    candidate_sha256=hashlib.sha256(source.encode()).hexdigest(),
    production_changed=False, native_validation_pending=True), indent=2))
print(out / 'terrain_candidate.lua')
