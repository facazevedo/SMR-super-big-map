"""Actual v991 equals native-shadowed artifact; reconstruct all other source exactly."""
import json
from pathlib import Path
import subprocess
root=Path(__file__).resolve().parents[3]
out=root/'_ralph/runs/under80-20260912/artifacts/apron_local_research'
source=(root/'Code/sbm_terrain_copy.lua').read_text()
assert source==(out/'terrain_candidate.lua').read_text(),'Actual candidate differs from native-shadowed source'
manifest=json.loads((out/'manifest.json').read_text())
assert len(manifest['changes'])==6
for change in reversed(manifest['changes']):
    assert source.count(change['new'])==1
    source=source.replace(change['new'],change['old'])
baseline=subprocess.check_output(['git','show','56fbf44:Code/sbm_terrain_copy.lua'],cwd=root,text=True)
assert source==baseline,'Undeclared source change'
changed=subprocess.check_output(['git','diff','--name-only','56fbf44','--','Code','metadata.lua','items.lua'],cwd=root,text=True).splitlines()
assert sorted(changed)==['Code/sbm_terrain_copy.lua','Code/sbm_version.lua','metadata.lua'],changed
assert 'GENERATOR_PATCH_VERSION = 303' in (root/'Code/sbm_version.lua').read_text()
assert "'version', 991," in (root/'metadata.lua').read_text()
print('PASS actual native-shadowed local field; six exact replacements only, scalar/RNG/rebuild code unchanged')
