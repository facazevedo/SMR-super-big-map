"""Expected-failure integration run; preserve normal runner rejection as evidence."""
import json
from pathlib import Path
import subprocess
import sys

root = Path(__file__).resolve().parents[3]
name = 'native_outer_integrated_rejection'
out = root / '_ralph/runs/under80-20260912/artifacts' / name
assert not out.exists(), 'Preserve previous evidence'
head = subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=root, text=True).strip()
proc = subprocess.run([sys.executable, '-u', '_ralph/tmp/under80_20260912/profile.py',
    '--name', name,
    '--prior', '_ralph/runs/under80-20260912/artifacts/v983_confirmation_reference/14n134w_a',
    '--setup', '_ralph/tmp/under80_20260912/native_outer_integrated_failure_setup.lua',
    '--diagnostic-query', 'SBM_OUTER_INTEGRATED_FAILURE'], cwd=root)
assert subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=root, text=True).strip() == head
assert proc.returncode != 0, 'Ordinary rules runner must reject an OptimizationFailure'
diagnostic = json.loads((out / 'diagnostic_state.json').read_text())
report = json.loads((out / 'rules_report.json').read_text())
log = (out / 'engine_flushed.log').read_text(errors='replace')
assert diagnostic['status'] == 'pass', diagnostic
assert report['status'] == 'engine_error', report['status']
assert '[OptimizationFailure]' in log and 'native outer root residual' in log
assert 'Debug::Done()' in log, 'Normal flushed shutdown missing'
assert len(diagnostic['calls']) == 1
call = diagnostic['calls'][0]
assert call['before'] == call['after'] and call['install_calls'] == 0
assert call['allocations'] == call['freed'] > 0 and call['all_freed']
assert call['injected'] == call['new_failures'] == 1
verdict = {'status': 'pass', 'commit': head, 'expected_rules_rejection': True,
    'ordinary_runner_exit': proc.returncode, 'height_unchanged': True,
    'install_calls': call['install_calls'], 'allocations_freed': call['freed'],
    'scope': 'private integrated root-residual failure; not cold acceptance'}
(out / 'expected_failure_audit.json').write_text(json.dumps(verdict, indent=2))
print(json.dumps(verdict, indent=2))
