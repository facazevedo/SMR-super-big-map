"""Profile one fresh accepted scenario and preserve full output/process evidence."""
import argparse
import json
from pathlib import Path
import subprocess
import sys
import time

ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT / '_ralph/tmp/historical_ports_20260909'))
import measure_port

suite = measure_port.suite
parser = argparse.ArgumentParser()
parser.add_argument('--name', required=True)
parser.add_argument('--prior', required=True)
parser.add_argument('--function-profile', action='store_true')
args = parser.parse_args()
out = ROOT / '_ralph/runs/under80-20260912/artifacts' / args.name
if out.exists():
    raise RuntimeError('Preserve previous evidence')
prior = suite.read_run(ROOT / args.prior)
report = prior['report']
suite.run_cold_matrix.fresh_game_check()
subprocess.run([sys.executable, '_ralph/tools/deploy.py', 'audit'], cwd=ROOT, check=True)
head = suite.command('git', 'rev-parse', 'HEAD')
out.mkdir(parents=True)
setup_name = 'function_profile_setup.lua' if args.function_profile else 'profile_setup.lua'
setup = out / 'diagnostic_setup.lua'
setup.write_text(Path(__file__).with_name(setup_name).read_text().replace(
    '__PROFILE_OUTPUT__', out.as_posix()), encoding='utf-8')
started = time.time()
proc = subprocess.run([sys.executable, '-u', '_ralph/tools/rules/run_rules.py',
    '--out', str(out), '--site', report['site'], '--lat', str(report['lat']),
    '--lon', str(report['lon']), '--pin-game-seed', report['pin_game_seed'],
    '--pin-ug-seed', str(report['rules']['ug_placement_seed']),
    '--setup-probe', str(setup),
    '--keep-alive'], cwd=ROOT)
identity = suite.HARNESS / '.daemon.json'
if not identity.exists() or identity.stat().st_mtime < started:
    raise RuntimeError('No fresh owned process')
metadata = json.loads(identity.read_text())
suite.capture(out, metadata['pid'], failed=proc.returncode != 0)
if proc.returncode:
    raise RuntimeError('Diagnostic failed')
if suite.command('git', 'rev-parse', 'HEAD') != head:
    raise RuntimeError('Checkpoint changed')
comparison = suite.exact_pair(prior, suite.read_run(out))
(out / 'predecessor_parity.json').write_text(json.dumps(comparison, indent=2))
(out / 'checkpoint.json').write_text(json.dumps(dict(commit=head, diagnostic_only=True), indent=2))
log = (out / 'engine_flushed.log').read_text(errors='replace')
stages = [line for line in log.splitlines() if '[LoadingTiming]' in line]
(out / 'stages.json').write_text(json.dumps(stages, indent=2))
summary = [line for line in stages if 'SUMMARY ' in line and 'environment=Surface' in line]
print(json.dumps(dict(parity=comparison, stages=summary[:35]), indent=2), flush=True)
instrumented = (len(list(out.glob('function_*.txt'))) >= 4 if args.function_profile
                else any('split rocket planning' in line for line in stages))
if comparison['verdict'] != 'pass' or not instrumented:
    raise RuntimeError('Diagnostic parity or instrumentation failed')
