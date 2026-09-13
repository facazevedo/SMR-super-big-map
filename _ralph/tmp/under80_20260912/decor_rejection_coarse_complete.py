"""Close the original finite matrix after ONLY its unstarted fourth run resumed.

The original driver stopped after three successful samples because the Windows
process census briefly retained the normally exited third PID. Preserve that
three-row journal and the original plan; never replace or rerun a sample.
"""
import hashlib
import json
from pathlib import Path
import subprocess
root=Path(__file__).resolve().parents[3]
art=root/'_ralph/runs/under80-20260912/artifacts'
out=art/'decor_rejection_coarse_matrix'
target=out/'comparison.json'
assert not target.exists(),'Preserve completed evidence'
read=lambda p:json.loads(p.read_text())
plan=read(out/'plan.json');journal=read(out/'results.json')
assert len(journal)==3,'Expected exactly three originally completed samples'
assert subprocess.check_output(['git','rev-parse','HEAD'],cwd=root,text=True).strip()==plan['commit']
assert all(hashlib.sha256((root/p).read_bytes()).hexdigest()==h for p,h in plan['hashes'].items())
results=[]
for variant,suffix in plan['order']:
 name=f'v987_decor_rejection_coarse_{variant}_61n_{suffix}'
 audit=read(art/name/'private_process_audit.json')
 assert audit['status']=='pass' and not audit['issues'] and audit['checkpoint']['commit']==plan['commit']
 assert audit['normal_shutdown'] and audit['pair']['verdict']=='pass' and audit['private_fields_checked']==4
 assert audit['variant']==('accepted' if variant=='old' else 'candidate')
 results.append(dict(name=name,variant=variant,order=suffix,decor_ms=audit['decor_ms'],identity=audit['identity']))
assert results[:3]==journal,'Completed samples changed'
assert len({tuple(row['identity']) for row in results})==4
report=dict(samples=results,old_new_saving_ms=results[0]['decor_ms']-results[1]['decor_ms'],
 new_old_saving_ms=results[3]['decor_ms']-results[2]['decor_ms'],
 completion='Original driver23225 ended after three; only unstarted old_b resumed in12667 after authoritative fresh-game/hash checks.',
 original_journal_preserved=True,replacement_samples=0,
 qualification='Separate fresh runs; wall-time differences do not establish causation, significance or cold-start acceptance.')
target.write_text(json.dumps(report,indent=2))
print(json.dumps(report,indent=2))
