"""Non-deployed exact zero-angle harmonic cache, scoped to one coarse patch."""
from pathlib import Path
import hashlib
import json

ROOT=Path(__file__).resolve().parents[3]
source=(ROOT/'Code/sbm_terrain_copy.lua').read_text()
before=source

def once(text,old,new):
    assert text.count(old)==1,repr(old)
    return text.replace(old,new)

source=once(source,
    '\t\t\t\tfor coarse_y = 0, coarse_height - 1 do\n',
    '\t\t\t\tlocal cached_zero_sine, cached_zero_harmonic\n'
    '\t\t\t\tfor coarse_y = 0, coarse_height - 1 do\n')
old='''\t\t\t\t\t\t\tlocal harmonic = 0.52 * math.sin(3 * angle + patch.phase)
\t\t\t\t\t\t\t\t+ 0.30 * math.sin(5 * angle - patch.phase * 1.37)
\t\t\t\t\t\t\t\t+ 0.18 * math.sin(7 * angle + patch.phase * 0.73)'''
new='''\t\t\t\t\t\t\tlocal sine = math.sin
\t\t\t\t\t\t\tlocal harmonic
\t\t\t\t\t\t\tif angle == 0 and sine == cached_zero_sine then
\t\t\t\t\t\t\t\tharmonic = cached_zero_harmonic
\t\t\t\t\t\t\telse
\t\t\t\t\t\t\t\tharmonic = 0.52 * math.sin(3 * angle + patch.phase)
\t\t\t\t\t\t\t\t\t+ 0.30 * math.sin(5 * angle - patch.phase * 1.37)
\t\t\t\t\t\t\t\t\t+ 0.18 * math.sin(7 * angle + patch.phase * 0.73)
\t\t\t\t\t\t\t\tif angle == 0 and sine == math.sin then
\t\t\t\t\t\t\t\t\tcached_zero_sine, cached_zero_harmonic = sine, harmonic
\t\t\t\t\t\t\t\tend
\t\t\t\t\t\t\tend'''
source=once(source,old,new)
out=ROOT/'_ralph/runs/under80-20260912/artifacts/zero_harmonic_research'
out.mkdir(parents=True,exist_ok=False)
(out/'terrain_candidate.lua').write_text(source,encoding='utf-8')
(out/'manifest.json').write_text(json.dumps(dict(
    baseline_sha256=hashlib.sha256(before.encode()).hexdigest(),
    candidate_sha256=hashlib.sha256(source.encode()).hexdigest(),
    production_changed=False),indent=2))
print(out/'terrain_candidate.lua')
