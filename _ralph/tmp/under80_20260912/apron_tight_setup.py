"""Generate the two execution orders without editing the live template."""
from pathlib import Path
root=Path(__file__).resolve().parents[3]
source=(root/'_ralph/tmp/under80_20260912/apron_tight_shadow.lua').read_text()
assert source.count('local reverse=false')==1
out=root/'_ralph/runs/under80-20260912/artifacts/apron_tight_setup'
out.mkdir(parents=True,exist_ok=False)
for reverse in (False,True):
    (out/('reverse.lua' if reverse else 'forward.lua')).write_text(
        source.replace('local reverse=false','local reverse='+str(reverse).lower()))
print('Generated isolated full-grid shadows; accepted raster always supplies game output')
