"""Two predeclared fresh repeats of the slow 45S sample; retain every result."""
from pathlib import Path
import subprocess
import sys

ROOT=Path(__file__).resolve().parents[3]
for label in ('b','c'):
    subprocess.run([sys.executable,'-u',
        str(ROOT/'_ralph/tmp/historical_ports_20260909/verify_port.py'),
        '--out',str(ROOT/('_ralph/runs/manual-mask-crease-rock/artifacts/v967_45_repeat_'+label)),
        '--prior',str(ROOT/'_ralph/runs/manual-mask-crease-rock/artifacts/v966_matrix'),
        '--site','45S120W'],cwd=ROOT,check=True)
print('BOTH PREDECLARED REPEATS COMPLETE',flush=True)
