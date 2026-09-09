"""Finite acceptance of one committed candidate; no optimization loop."""
import argparse
import json
from pathlib import Path
import subprocess
import sys
ROOT=Path(__file__).resolve().parents[3]
helpers=ROOT/'_ralph/tmp/historical_ports_20260909'
p=argparse.ArgumentParser();p.add_argument('--version',required=True)
p.add_argument('--prior-root',required=True);p.add_argument('--prior-version',required=True)
a=p.parse_args();out=ROOT/'_ralph/runs/manual-mask-crease-rock/artifacts';prior=ROOT/a.prior_root
def run(script,*args):
    subprocess.run([sys.executable,'-u',str(helpers/script),*map(str,args)],cwd=ROOT,check=True)
run('measure_port.py','--out',out/('v'+a.version+'_reference'),'--phase','reference')
run('audit_reference.py','--out',out/('v'+a.version+'_reference'),
    '--prior',prior/('v'+a.prior_version+'_reference'))
audit=json.loads((out/('v'+a.version+'_reference/reference_audit.json')).read_text())
if audit['saving_s']<=0: raise RuntimeError('No measured improvement; not accepted')
run('verify_port.py','--out',out/('v'+a.version+'_matrix'),
    '--prior',prior/('v'+a.prior_version+'_matrix'))
print('FINITE CANDIDATE ACCEPTANCE COMPLETE',flush=True)
