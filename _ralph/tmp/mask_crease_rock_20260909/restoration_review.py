"""Verify the final payload is the accepted v966 program after rejecting rock caching."""
import json
from pathlib import Path
import subprocess
import sys

ROOT=Path(__file__).resolve().parents[3]
OUT=ROOT/'_ralph/runs/manual-mask-crease-rock/artifacts'
sys.path.insert(0,str(ROOT/'_ralph/tools/rules'))
from run_cold_matrix import fresh_game_check
fresh_game_check()
def command(*args):return subprocess.check_output(args,cwd=ROOT,text=True).strip()
assert not command('git','diff','56b8a1f','--','Code','Images','metadata.lua','items.lua')
assert not command('git','status','--porcelain','--','Code','Images','metadata.lua','items.lua')
offline=json.loads((OUT/'v966_restored_offline/all_results.json').read_text())
assert len(offline)==64 and all(r['exit']==0 for r in offline)
accepted=json.loads((OUT/'v966_all_ten_rules_review.json').read_text())
assert len(accepted['scenarios'])==5 and all(r['all_ten']=='pass'for r in accepted['scenarios'])
deployment=json.loads(command(sys.executable,'_ralph/tools/deploy.py','audit'));assert deployment['ok']
result=dict(restoration_commit=command('git','rev-parse','HEAD'),version=966,
    identical_accepted_production_commit=accepted['code_commit'],offline_commands_passed=64,
    accepted_five_site_review='v966_all_ten_rules_review.json',deployment=deployment,
    no_game_running=True,accepted_reference_median_s=113.024,
    rejected_experiment_commit='3c03de43bd00771d99026701d0095b6993ad5525',
    qualification='No new cold timing claimed for the revert; production matches the accepted v966 Git content exactly.')
(OUT/'restoration_review.json').write_text(json.dumps(result,indent=2))
print(json.dumps(result,indent=2))
