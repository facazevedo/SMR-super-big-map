"""Characterize the captured expected-failure run without changing its failed verdict."""
import json
from pathlib import Path

root = Path(__file__).resolve().parents[3]
out = root / '_ralph/runs/under80-20260912/artifacts/native_outer_integrated_rejection'
diagnostic = json.loads((out / 'diagnostic_state.json').read_text())
rules = json.loads((out / 'rules_report.json').read_text())
parity = json.loads((out / 'predecessor_parity.json').read_text())
snapshot = json.loads((out / 'post_rules_snapshot.json').read_text())
log = (out / 'engine_flushed.log').read_text(errors='replace')
assert diagnostic['status'] == 'pass' and diagnostic['calls']
for call in diagnostic['calls']:
    assert call['before'] == call['after'] and call['install_calls'] == 0
    assert call['allocations'] == call['freed'] > 0 and call['all_freed']
    assert call['injected'] == call['new_failures'] == 1
    assert call['report']['error'] == 'native outer root residual'
assert parity['verdict'] == 'fail' and parity['full_snapshot_differences']
assert len(snapshot['optimization_failures']) == len(diagnostic['calls'])
assert '[OptimizationFailure]' in log and '[LUA ERROR]' in log and 'Debug::Done()' in log
record = {'status': 'partial_evidence_not_original_test_pass',
    'transaction_contract': 'pass', 'calls': len(diagnostic['calls']),
    'freed_per_call': [c['freed'] for c in diagnostic['calls']],
    'installed_height_unchanged_per_call': True, 'install_calls': 0,
    'failure_visible_in_log_and_state': True, 'full_verifier_rejected': True,
    'rules_status': rules['status'], 'early_startup_abort_proved': False,
    'original_expected_failure_driver': 'failed; assumptions engine_error and single call were false',
    'cold_acceptance': False}
target = out / 'transaction_evidence_audit.json'
assert not target.exists(), 'Preserve evidence'
target.write_text(json.dumps(record, indent=2))
print(json.dumps(record, indent=2))
