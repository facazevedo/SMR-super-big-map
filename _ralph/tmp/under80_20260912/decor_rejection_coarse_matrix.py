"""Finite old/new/new/old whole-decor experiment, every fresh process fully audited.

NOT a cold-start acceptance batch. No production or deployment changes; the new
variant uses only the private exact-shadowed Run source. No replacement samples.
"""
import hashlib
import json
from pathlib import Path
import subprocess
import sys
root=Path(__file__).resolve().parents[3]
base=root/'_ralph/tmp/under80_20260912'
art=root/'_ralph/runs/under80-20260912/artifacts'
out=art/'decor_rejection_coarse_matrix'
out.mkdir(parents=True,exist_ok=False)
head=subprocess.check_output(['git','rev-parse','HEAD'],cwd=root,text=True).strip()
paths=list((root/'Code').glob('*.lua'))+[root/'metadata.lua',root/'items.lua',
 art/'decor_rejection_fusion_2/candidate.lua',base/'decor_rejection_coarse.lua',
 base/'decor_rejection_coarse_old.lua',base/'decor_rejection_coarse_new.lua']
def hashes():return {str(p.relative_to(root)):hashlib.sha256(p.read_bytes()).hexdigest() for p in paths}
frozen=hashes();order=[('old','a'),('new','a'),('new','b'),('old','b')]
(out/'plan.json').write_text(json.dumps(dict(commit=head,order=order,hashes=frozen,
 qualification='Whole-decor diagnostic wall timing, not cold startup acceptance; all four samples retained.'),indent=2))
results=[]
for variant,suffix in order:
 assert subprocess.check_output(['git','rev-parse','HEAD'],cwd=root,text=True).strip()==head
 assert hashes()==frozen,'Frozen payload changed'
 name=f'v987_decor_rejection_coarse_{variant}_61n_{suffix}'
 subprocess.run([sys.executable,'-u',str(base/'profile.py'),'--name',name,
  '--prior','_ralph/runs/under80-20260912/artifacts/v987_matrix/61n136w_a',
  '--setup',str(base/f'decor_rejection_coarse_{variant}.lua'),
  '--diagnostic-query','SBM_DECOR_REJECTION_COARSE'],cwd=root,check=True)
 subprocess.run([sys.executable,str(base/'decor_rejection_coarse_audit.py'),'--name',name],cwd=root,check=True)
 audit=json.loads((art/name/'private_process_audit.json').read_text())
 assert audit['status']=='pass' and audit['variant']==('accepted' if variant=='old' else 'candidate')
 results.append(dict(name=name,variant=variant,order=suffix,decor_ms=audit['decor_ms'],identity=audit['identity']))
 (out/'results.json').write_text(json.dumps(results,indent=2))
 assert hashes()==frozen
assert len({tuple(row['identity']) for row in results})==4
comparison=dict(samples=results,old_new_saving_ms=results[0]['decor_ms']-results[1]['decor_ms'],
 new_old_saving_ms=results[3]['decor_ms']-results[2]['decor_ms'],
 qualification='Separate fresh runs; wall-time differences do not establish causation, significance or cold-start acceptance.')
(out/'comparison.json').write_text(json.dumps(comparison,indent=2))
print(json.dumps(comparison,indent=2),flush=True)
