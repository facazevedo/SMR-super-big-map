"""Fresh hidden engine, scratch grids only, captured identity and normal quit."""
import json
import argparse
from pathlib import Path
import subprocess
import sys
import time

ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT / '_ralph/tmp/historical_ports_20260909'))
import measure_port
suite = measure_port.suite
parser = argparse.ArgumentParser()
parser.add_argument('--name', default='certificate_native')
args = parser.parse_args()
out = ROOT / '_ralph/runs/under80-20260912/artifacts' / args.name
assert not out.exists(), 'Preserve evidence'
suite.run_cold_matrix.fresh_game_check()
subprocess.run([sys.executable, '_ralph/tools/deploy.py', 'audit'], cwd=ROOT, check=True)
out.mkdir(parents=True)
started = time.time()
proc = suite.cli('daemon', 'start', '--hidden', '--timeout', '300', timeout=330)
assert proc.returncode == 0, proc.stdout + proc.stderr
identity = suite.HARNESS / '.daemon.json'
assert identity.exists() and identity.stat().st_mtime >= started
pid = json.loads(identity.read_text())['pid']
try:
    probe = suite.cli('run-file', str(Path(__file__).with_suffix('.lua')), '--json', timeout=180)
    (out / 'probe_cli.log').write_text(probe.stdout + probe.stderr)
finally:
    # No map exists: skip the post-T1 snapshot, but always capture/quit owned process.
    suite.capture(out, pid, failed=True, diagnostic_query='SBM_NATIVE_STEP_CERT_PROBE')
result = json.loads((out / 'diagnostic_state.json').read_text())
assert result['status'] == 'pass', result
log = (out / 'engine_flushed.log').read_text(errors='replace')
assert 'Debug::Done()' in log and '[LUA ERROR]' not in log and 'Assertion failed' not in log
print(json.dumps(result, indent=2))
