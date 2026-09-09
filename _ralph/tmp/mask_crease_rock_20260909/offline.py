"""All prior offline regressions plus the current preservation candidates."""
import argparse
import json
from pathlib import Path
import subprocess
import sys
import time
ROOT=Path(__file__).resolve().parents[3]
p=argparse.ArgumentParser();p.add_argument('--version',required=True);p.add_argument('--extra',action='append',default=[])
a=p.parse_args();out=ROOT/('_ralph/runs/manual-mask-crease-rock/artifacts/v'+a.version+'_offline')
subprocess.run([sys.executable,'_ralph/tmp/g3_grounding_20260909/run_offline.py',str(out)],cwd=ROOT,check=True)
rows=json.loads((out/'results.json').read_text())
for name in ['rocket_sampling','native_apron','crease_sampling','rocket_pruning','crease_discovery','apron_mask','outer_mask_shortcuts']+a.extra:
    command=['lua','_ralph/tools/parity/'+name+'_test.lua'];start=time.monotonic()
    proc=subprocess.run(command,cwd=ROOT,capture_output=True,text=True,timeout=300)
    (out/(name+'.log')).write_text(proc.stdout+proc.stderr)
    row=dict(name=name,command=command,exit=proc.returncode,seconds=time.monotonic()-start)
    rows.append(row);print(name,proc.returncode,flush=True)
(out/'all_results.json').write_text(json.dumps(rows,indent=2))
if any(r['exit'] for r in rows): raise RuntimeError('Offline regression failed')
