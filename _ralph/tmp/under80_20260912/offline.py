"""Replay the accepted v972 regression set plus the decor index oracle."""
import argparse
import json
from pathlib import Path
import subprocess
import time

ROOT = Path(__file__).resolve().parents[3]
parser = argparse.ArgumentParser()
parser.add_argument('--name', required=True)
parser.add_argument('--extra', action='append', default=[])
parser.add_argument('--extra-python', action='append', default=[])
args = parser.parse_args()
out = ROOT / '_ralph/runs/under80-20260912/artifacts' / args.name
out.mkdir(parents=True, exist_ok=False)
baseline = ROOT / '_ralph/runs/manual-rocket-crease-transactions/artifacts/v972_final_restored_offline/all_results.json'
commands = json.loads(baseline.read_text())
commands.append(dict(name='decor_circle_index', command=['lua', '_ralph/tools/parity/decor_circle_index_test.lua']))
for name in args.extra:
    commands.append(dict(name=name, command=['lua', '_ralph/tools/parity/' + name + '_test.lua']))
for name in args.extra_python:
    commands.append(dict(name=name, command=['python', '_ralph/tools/parity/' + name + '_test.py']))
results = []
for row in commands:
    start = time.monotonic()
    proc = subprocess.run(row['command'], cwd=ROOT, capture_output=True, text=True, timeout=300)
    (out / (row['name'] + '.log')).write_text(proc.stdout + proc.stderr, encoding='utf-8')
    results.append(dict(name=row['name'], command=row['command'], exit=proc.returncode,
                        seconds=round(time.monotonic() - start, 3)))
    (out / 'all_results.json').write_text(json.dumps(results, indent=2), encoding='utf-8')
    print(row['name'], proc.returncode, flush=True)
if any(row['exit'] for row in results):
    raise RuntimeError('Offline regression failed')
