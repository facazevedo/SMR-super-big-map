"""Only declared local-error edits; production and all other source unchanged."""
import json
from pathlib import Path
import subprocess
root=Path(__file__).resolve().parents[3]
out=root/'_ralph/runs/under80-20260912/artifacts/apron_local_research'
manifest=json.loads((out/'manifest.json').read_text())
source=(out/'terrain_candidate.lua').read_text()
for change in reversed(manifest['changes']):
    assert source.count(change['new'])==1
    source=source.replace(change['new'],change['old'])
baseline=subprocess.check_output(['git','show','56fbf44:Code/sbm_terrain_copy.lua'],cwd=root,text=True)
assert source==baseline,'Undeclared candidate source edits'
subprocess.run(['git','diff','--exit-code','56fbf44','--','Code','metadata.lua','items.lua'],cwd=root,check=True)
print('PASS exact v987 reconstruction outside six declared local-error replacements; production untouched')
