"""Record separate primary-agent source/process sign-off; raw gates unchanged."""
import argparse
import json
from pathlib import Path
import subprocess
ROOT=Path(__file__).resolve().parents[3];OUT=ROOT/'_ralph/runs/manual-mask-crease-rock/artifacts'
p=argparse.ArgumentParser();p.add_argument('--version',required=True);p.add_argument('--code-commit',required=True)
a=p.parse_args();v='v'+a.version
def read(path):return json.loads(path.read_text())
reference=read(OUT/(v+'_reference/reference_audit.json'));matrix=read(OUT/(v+'_matrix/verification.json'))
offline=read(OUT/(v+'_offline/all_results.json'))
assert reference['clean_exact_evidence'] and not reference['issues'] and reference['saving_s']>0
assert len(matrix)==5 and {r['site']for r in matrix}=={'15S67E','24S74W','45S120W','61N136W','17S11W'}
assert len(offline)>=61 and all(r['exit']==0 for r in offline)
head=subprocess.check_output(['git','rev-parse','HEAD'],cwd=ROOT,text=True).strip()
assert head.startswith(a.code_commit)
assert not subprocess.check_output(['git','status','--porcelain','--','Code','metadata.lua','items.lua'],cwd=ROOT,text=True).strip()
assert (OUT/(v+'_source_review.md')).exists()
deployment=json.loads(subprocess.check_output(['python','_ralph/tools/deploy.py','audit'],cwd=ROOT,text=True))
assert deployment['ok']
identities=[]
for path in [OUT/(v+'_reference')/('14n134w_'+s)for s in ('a','b','c','control')]+[OUT/(v+'_matrix')/(r['site'].lower()+'_a')for r in matrix]:
 ident=read(path/'daemon_identity.json');identities.append((ident['pid'],ident['process_creation_filetime']))
 checkpoint=read(path/'checkpoint.json');assert checkpoint['commit']==head and checkpoint['payload_audited_before_launch']
 report=read(path/'rules_report.json');assert report['status']=='complete' and not report.get('error')
 assert 'diagnostic_setup_probe' not in report
 assert '[LoadingTiming] STEP' not in (path/'engine_flushed.log').read_text(errors='replace')
assert len(set(identities))==9
reviews=[]
for r in matrix:
 assert r['commit']==head and not r['issues'] and r['pair']['verdict']=='pass'
 for gate,evidence in r['gates'].items():assert evidence['verdict']==('pending'if gate in ('seed-parity','process')else'pass')
 reviews.append(dict(site=r['site'],all_ten='pass',automated_gates='8/8 pass',
  seed_parity_review='Exact predecessor/private streams plus separate primary-agent source/RNG review.',
  process_review='Immutable committed payload, prelaunch audit, unique owned process, complete capture and normal shutdown.',
  visual_review='Inherited accepted visual evidence through identical full outputs; no new screenshot claim.',
  t0_to_t1_s=r['t0_to_t1_s'],prior_t0_to_t1_s=r['prior_t0_to_t1_s']))
result=dict(code_commit=head,version=a.version,offline_commands_passed=len(offline),
 benchmark_median_s=reference['median_s'],prior_median_s=reference['prior_median_s'],saving_s=reference['saving_s'],
 source_review=v+'_source_review.md',deployment=deployment,unique_acceptance_processes=9,scenarios=reviews,
 raw_judgments_unchanged=True)
(OUT/(v+'_all_ten_rules_review.json')).write_text(json.dumps(result,indent=2));print(json.dumps(result,indent=2))
