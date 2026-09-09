"""Native scratch experiment; never publishes or mutates terrain."""
import json
from pathlib import Path
import subprocess
import sys
import time
ROOT=Path(__file__).resolve().parents[3];HERE=Path(__file__).resolve().parent
kind=sys.argv[1] if len(sys.argv)>1 else 'row'
if kind not in ('row','track'):raise RuntimeError('Unknown probe')
suffix=sys.argv[2] if len(sys.argv)>2 else ''
if suffix and not suffix.isalnum():raise RuntimeError('Invalid evidence suffix')
OUT=ROOT/('_ralph/runs/manual-mask-crease-rock/artifacts/native_'+kind+'_probe'+suffix)
sys.path.insert(0,str(ROOT/'_ralph/tmp/historical_ports_20260909'))
import measure_port
suite=measure_port.suite;suite.run_cold_matrix.fresh_game_check();OUT.mkdir(parents=True,exist_ok=False)
def cli(*args):
 p=suite.cli(*args)
 if p.returncode: raise RuntimeError(p.stdout+p.stderr)
 return p
(OUT/'start.json').write_text(cli('daemon','start','--hidden','--timeout','300','--json').stdout)
identity=suite.HARNESS/'.daemon.json';owned=json.loads(identity.read_text())
(OUT/'owner.json').write_text(json.dumps(owned,indent=2))
try:
 (OUT/'run.json').write_text(cli('run-file',str(HERE/(kind+'_probe.lua')),'--json').stdout)
 deadline=time.monotonic()+180
 while True:
  status=json.loads(cli('state','ROW_PROBE_STATUS','--json').stdout)['data']['value']
  if status!='running':break
  if time.monotonic()>deadline:raise RuntimeError('Probe timeout')
  time.sleep(2)
 result=json.loads(cli('state','ROW_PROBE_RESULT','--json').stdout)['data']['value']
 (OUT/'result.json').write_text(json.dumps(result,indent=2));print(json.dumps(result,indent=2),flush=True)
 if status!='complete' or result.get('error') or result['mismatches']:raise RuntimeError('Probe failed')
finally:
 current=json.loads(identity.read_text())
 if any(current.get(k)!=owned.get(k) for k in ('pid','process_creation_filetime')):raise RuntimeError('Owner changed')
 (OUT/'quit.json').write_text(cli('quit','--json').stdout)
