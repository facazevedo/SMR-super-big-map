"""Verify actual v990 equals the native-shadowed bound-only candidate."""
from pathlib import Path
import subprocess
root=Path(__file__).resolve().parents[3]
source=(root/'Code/sbm_terrain_copy.lua').read_text()
artifact=(root/'_ralph/runs/under80-20260912/artifacts/apron_tight_research/terrain_candidate.lua').read_text()
assert source==artifact,'Actual production differs from native-shadowed candidate'
old=('-- Adaptively biased Q22 coordinates and the unchanged residual certificate bound error\n'
     '\t\t\t\t-- by5/65536 through core0.60, and7/65536 for the remaining qualified cores.\n'
     '\t\t\t\tlocal error_numerator = policy.core_fraction <= 0.60 and 5 or 7')
new=('-- The same Q22/residual domain with tighter propagation and an explicit\n'
     '\t\t\t\t-- polynomial/core rounding bound gives3/65536 through core0.60, else5/65536.\n'
     '\t\t\t\tlocal error_numerator = policy.core_fraction <= 0.60 and 3 or 5')
assert source.count(new)==1
baseline=subprocess.check_output(['git','show','56fbf44:Code/sbm_terrain_copy.lua'],cwd=root,text=True)
assert source.replace(new,old)==baseline,'Other native/scalar/guard/cleanup/order changes'
changed=subprocess.check_output(['git','diff','--name-only','56fbf44','--','Code','metadata.lua','items.lua'],cwd=root,text=True).splitlines()
assert sorted(changed)==['Code/sbm_terrain_copy.lua','Code/sbm_version.lua','metadata.lua'],changed
print('PASS actual native-shadowed3/5 bounds only; every native operation, guard, scalar correction and other terrain code literalv987')
