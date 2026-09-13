"""Audit the six unique completed shadows across preserved runner-stop artifacts."""
import hashlib
import json
from pathlib import Path

root = Path(__file__).resolve().parents[3]
art = root / '_ralph/runs/under80-20260912/artifacts'
groups = (
    ('native_outer_mask_qualified_matrix', ('14n134w',)),
    ('native_outer_mask_qualified_remaining_five', ('15s67e',)),
    ('native_outer_mask_qualified_remaining_four', ('24s74w', '45s120w', '61n136w', '17s11w')),
)
identities, results, frozen = set(), [], None
for group, sites in groups:
    batch = json.loads((art / group / 'batch.json').read_text())
    if frozen is None:
        frozen = batch['hashes']
    assert batch['hashes'] == frozen
    for site in sites:
        directory = art / group / site
        parity = json.loads((directory / 'predecessor_parity.json').read_text())
        diagnostic = json.loads((directory / 'diagnostic_state.json').read_text())
        identity = json.loads((directory / 'daemon_identity.json').read_text())
        checkpoint = json.loads((directory / 'checkpoint.json').read_text())
        log = (directory / 'engine_flushed.log').read_text(errors='replace')
        assert parity['verdict'] == diagnostic['status'] == 'pass'
        assert not parity['differences'] and not parity['full_snapshot_differences'] and not parity['rock_grounding_differences']
        assert checkpoint['commit'] == batch['commit'] and checkpoint['diagnostic_only']
        assert 'Debug::Done()' in log and '[LUA ERROR]' not in log and '[OptimizationFailure]' not in log
        token = (identity['pid'], identity['process_creation_filetime'])
        assert token not in identities and identity['window'] == 'hidden'
        identities.add(token)
        patches = [p for call in diagnostic['calls'] for p in call['patches']]
        assert patches and all(p['used_candidate'] and p['checked'] == p['samples'] for p in patches)
        results.append({'site': site, 'artifact': str(directory.relative_to(root)), 'pid': identity['pid'],
            'patches': len(patches), 'checked': sum(p['checked'] for p in patches),
            'kernel_ms': sum(p['kernel_ms'] for p in patches), 'scalar_ms': sum(p['scalar_ms'] for p in patches),
            'corrected': sum(p['stats']['corrected'] for p in patches)})
assert len(results) == len(identities) == 6
assert all(hashlib.sha256((root / path).read_bytes()).hexdigest() == digest for path, digest in frozen.items())
verdict = {'status': 'pass', 'diagnostic_only': True, 'cold_performance_verified': False,
    'unique_sites': 6, 'patches': sum(r['patches'] for r in results),
    'checked_cells': sum(r['checked'] for r in results), 'source_hashes': frozen, 'scenarios': results,
    'retained_runner_failures': [groups[0][0], groups[1][0]]}
target = art / groups[-1][0] / 'six_site_audit.json'
assert not target.exists(), 'Preserve evidence'
target.write_text(json.dumps(verdict, indent=2))
print(json.dumps({k: v for k, v in verdict.items() if k != 'source_hashes'}, indent=2))
