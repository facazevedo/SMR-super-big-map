"""One audited accepted-v966 run from an immutable detached worktree."""
import argparse
import json
from pathlib import Path
import subprocess
import sys
import time

p=argparse.ArgumentParser();p.add_argument('--workspace',required=True);p.add_argument('--out',required=True)
a=p.parse_args();workspace=Path(a.workspace).resolve();out=Path(a.out).resolve()
sys.path.insert(0,str(workspace/'_ralph/tools/rules'))
import run_cold_matrix as cold

head=subprocess.check_output(['git','rev-parse','HEAD'],cwd=workspace,text=True).strip()
assert head.startswith('56b8a1f')
assert not subprocess.check_output(['git','status','--porcelain','--','Code','metadata.lua','items.lua'],cwd=workspace,text=True).strip()
cold.fresh_game_check()
subprocess.run([sys.executable,str(workspace/'_ralph/tools/deploy.py'),'sync'],cwd=workspace,check=True)
started=time.time()
try:
    cold.run_one(out,{'site':'45S120W','lat_minutes':2700,'lon_minutes':-7200},
        'v932_sweep_14134_45s120w',6126103855836633687)
except BaseException:
    identity=cold.HARNESS/'.daemon.json'
    if identity.exists() and identity.stat().st_mtime>=started and not (out/'engine_flushed.log').exists():
        cold.capture(out,json.loads(identity.read_text())['pid'],failed=True)
    raise
assert subprocess.check_output(['git','rev-parse','HEAD'],cwd=workspace,text=True).strip()==head
(out/'checkpoint.json').write_text(json.dumps(dict(commit=head,version='966',
    source_workspace=str(workspace),payload_audited_before_launch=True,expanded='on'),indent=2))
