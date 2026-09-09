"""Finish a predeclared A/B/A/B test; A1 is the second fresh v967 repeat."""
import json
from pathlib import Path
import re
import statistics
import subprocess
import sys
import time

ROOT=Path(__file__).resolve().parents[3]
HERE=Path(__file__).resolve().parent
OUT=ROOT/'_ralph/runs/manual-mask-crease-rock/artifacts'
BASE=HERE/'baseline_worktree'
sys.path.insert(0,str(ROOT/'_ralph/tmp/g3_grounding_20260909'))
import matrix
suite=matrix.suite

def run(*args,cwd=ROOT):subprocess.run([str(x)for x in args],cwd=cwd,check=True)
def fresh():
    # Read-only grace for tasklist's short retention after confirmed process exit.
    deadline=time.monotonic()+5
    while True:
        try:return suite.run_cold_matrix.fresh_game_check()
        except RuntimeError:
            if time.monotonic()>=deadline:raise
            time.sleep(.5)
fresh()
assert subprocess.check_output(['git','rev-parse','HEAD'],cwd=ROOT,text=True).strip().startswith('3c03de4')
if not BASE.exists():run('git','worktree','add','--detach',BASE,'56b8a1f')

paths=[OUT/'v967_45_repeat_c/45s120w_a']
for label in ('baseline_b1','candidate_a2','baseline_b2'):
    fresh()
    directory=OUT/'rock_bracket45'/label
    if label.startswith('baseline'):
        run(sys.executable,'-u',HERE/'baseline45_one.py','--workspace',BASE,'--out',directory)
        paths.append(directory)
    else:
        run(sys.executable,ROOT/'_ralph/tools/deploy.py','sync')
        run(sys.executable,'-u',ROOT/'_ralph/tmp/historical_ports_20260909/verify_port.py',
            '--out',directory,'--prior',OUT/'v966_matrix','--site','45S120W')
        paths.append(directory/'45s120w_a')

fresh()
run(sys.executable,ROOT/'_ralph/tools/deploy.py','sync')
prior=suite.read_run(OUT/'v966_matrix/45s120w_a')
control=suite.read_run(ROOT/'_ralph/runs/manual-rock-grounding/artifacts/v957_matrix/45s120w_control')
rows=[]
for index,path in enumerate(paths):
    item=suite.read_run(path);checkpoint=json.loads((path/'checkpoint.json').read_text())
    expected='967'if index%2==0 else'966'
    assert str(checkpoint['version'])==expected and checkpoint['payload_audited_before_launch']
    assert checkpoint['commit'].startswith('3c03de4'if expected=='967'else'56b8a1f')
    assert item['report']['status']=='complete' and not item['report'].get('error')
    pair=matrix.exact_pair(prior,item);assert pair['verdict']=='pass'
    gates=suite.judge_run(item,control)
    for gate,value in gates.items():assert value['verdict']==('pending'if gate in ('seed-parity','process')else'pass')
    for label in ('engine','daemon'):
        log=(path/(label+'_flushed.log')).read_text(errors='replace')
        assert '*** Debug::Done()'in log[-2000:]
        assert f'Loaded mod def Super Big Map (id SuperBigMap, v0.00-{expected}) unpacked from appdata'in log
        assert not re.search(r'\[LUA ERROR\]|\[ASSERT\]|assertion failed|assert failed|\[OptimizationFailure\]|exception code|c0000409|c0000005',log,re.I)
    rows.append(dict(path=str(path),checkpoint=checkpoint,identity=item['identity'],pair=pair,gates=gates,
        t0_to_t1_s=item['report']['rules']['t0_to_t1_ms']/1000,
        capture_ms=item['snapshot']['maps']['Surface']['rock_grounding_stats']['capture_ms']))
assert len({(r['identity']['pid'],r['identity']['process_creation_filetime'])for r in rows})==4
candidate=statistics.mean(r['t0_to_t1_s']for r in rows[::2]);baseline=statistics.mean(r['t0_to_t1_s']for r in rows[1::2])
result=dict(order='A/B/A/B; A=v967, B=v966',runs=rows,candidate_mean_s=candidate,
    baseline_mean_s=baseline,saving_s=baseline-candidate,current_payload_restored=True)
(OUT/'rock_bracket45/review.json').write_text(json.dumps(result,indent=2))
print(json.dumps({k:v for k,v in result.items()if k!='runs'},indent=2),flush=True)
