"""Generate isolated local-error shadows from retained audited full-raster template."""
from pathlib import Path
root=Path(__file__).resolve().parents[3]
source=(root/'_ralph/tmp/under80_20260912/apron_tight_shadow.lua').read_text()
for old,new in [
 ('SBM_APRON_TIGHT_SHADOW','SBM_APRON_LOCAL_SHADOW'),
 ('APRON_TIGHT_SHADOW_READY','APRON_LOCAL_SHADOW_READY'),
 ('apron_tight_research','apron_local_research'),
 ('apron_tight_polynomial_oracle.lua','apron_local_oracle.lua'),
 ('SBMApronTightPolynomial','SBMApronLocalPolynomial'),
 ('@apron-tight-raster','@apron-local-raster'),
 ("'return polynomial'","'return polynomial,nil,cube'"),
 ('local W=16777216\\n','local W=16777216;local w,h=radius:size()\\n'),
 ("'GridClamp','GridRound'","'GridClamp','GridRound','box','point'"),
]:
    assert old in source,old
    source=source.replace(old,new)
out=root/'_ralph/runs/under80-20260912/artifacts/apron_local_setup'
out.mkdir(parents=True,exist_ok=False)
for reverse in (False,True):
    (out/('reverse.lua' if reverse else 'forward.lua')).write_text(
        source.replace('local reverse=false','local reverse='+str(reverse).lower()))
print('Generated both isolated orders; accepted raster always supplies game terrain')
