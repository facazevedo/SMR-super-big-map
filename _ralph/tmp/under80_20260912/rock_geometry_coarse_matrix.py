"""Predeclared four fresh whole-annotation samples; no production changes."""
import hashlib
import json
from pathlib import Path
import subprocess
import sys
root=Path(__file__).resolve().parents[3]
base=root/'_ralph/tmp/under80_20260912'
art=root/'_ralph/runs/under80-20260912/artifacts'
out=art/'rock_geometry_coarse_matrix'
out.mkdir(parents=True,exist_ok=False)
head=subprocess.check_output(['git','rev-parse','HEAD'],cwd=root,text=True).strip()
paths=list((root/'Code').glob('*.lua'))+[root/'metadata.lua',root/'items.lua',
 art/'rock_geometry_candidate_2/candidate.lua',base/'rock_geometry_native.lua',
 base/'rock_geometry_coarse.lua',base/'rock_geometry_coarse_old.lua',base/'rock_geometry_coarse_new.lua']
def hashes():return {str(p.relative_to(root)):hashlib.sha256(p.read_bytes()).hexdigest() for p in paths}
frozen=hashes();order=[('old','a'),('new','a'),('new','b'),('old','b')]
(out/'plan.json').write_text(json.dumps(dict(commit=head,order=order,hashes=frozen,
 qualification='Whole-annotation diagnostic timing with initialization included. All four samples retained; no cold-start claim.'),indent=2))
results=[]
for variant,suffix in order:
 assert subprocess.check_output(['git','rev-parse','HEAD'],cwd=root,text=True).strip()==head
 assert hashes()==frozen,'Frozen payload changed'
 name=f'v987_rock_geometry_coarse_{variant}_61n_{suffix}'
 subprocess.run([sys.executable,'-u',str(base/'profile.py'),'--name',name,
  '--prior','_ralph/runs/under80-20260912/artifacts/v987_matrix/61n136w_a',
  '--setup',str(base/f'rock_geometry_coarse_{variant}.lua'),
  '--diagnostic-query','SBM_ROCK_GEOMETRY_COARSE'],cwd=root,check=True)
 subprocess.run([sys.executable,str(base/'rock_geometry_coarse_audit.py'),'--name',name],cwd=root,check=True)
 audit=json.loads((art/name/'private_process_audit.json').read_text())
 assert audit['status']=='pass' and audit['variant']==('accepted' if variant=='old' else 'candidate')
 results.append(dict(name=name,variant=variant,order=suffix,annotation_ms=audit['annotation_ms'],
  capture_ms=audit['capture_ms'],identity=audit['identity']))
 (out/'results.json').write_text(json.dumps(results,indent=2))
 assert hashes()==frozen
assert len({tuple(row['identity']) for row in results})==4
comparison=dict(samples=results,old_new_saving_ms=results[0]['annotation_ms']-results[1]['annotation_ms'],
 new_old_saving_ms=results[3]['annotation_ms']-results[2]['annotation_ms'],
 qualification='Separate fresh runs; differences do not establish causation, significance or cold-start acceptance.')
(out/'comparison.json').write_text(json.dumps(comparison,indent=2))
print(json.dumps(comparison,indent=2),flush=True)
