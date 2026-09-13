"""Immutable sequential private shadows; new runs never overwrite prior evidence."""
import argparse
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import subprocess
import sys
import time

root = Path(__file__).resolve().parents[3]
parser = argparse.ArgumentParser()
parser.add_argument('--name', default='native_outer_mask_qualified_matrix')
parser.add_argument('--remaining-from', type=Path)
args = parser.parse_args()
name = args.name
out = root / '_ralph/runs/under80-20260912/artifacts' / name
assert not out.exists(), 'Preserve prior batch evidence; never restart this batch'
out.mkdir(parents=True)
def git(*args):
    return subprocess.check_output(['git', *args], cwd=root, text=True).strip()

head = git('rev-parse', 'HEAD')
paths = git('ls-files', 'Code', 'metadata.lua', 'items.lua',
    '_ralph/tmp/under80_20260912/native_outer_mask.lua',
    '_ralph/tmp/under80_20260912/outer_mask_shadow.lua',
    '_ralph/tmp/under80_20260912/profile.py').splitlines()
def hashes():
    return {p: hashlib.sha256((root / p).read_bytes()).hexdigest() for p in paths}

frozen = hashes()
state = {'status': 'running', 'commit': head, 'hashes': frozen,
    'started_utc': datetime.now(timezone.utc).isoformat(), 'results': [],
    'diagnostic_only': True}
manifest = out / 'batch.json'
def record():
    manifest.write_text(json.dumps(state, indent=2))

record()
scenarios = [('14n134w', 'v983_confirmation_reference/14n134w_a')]
scenarios += [(site, 'v983_matrix_confirmation/' + site + '_a')
    for site in ('15s67e', '24s74w', '45s120w', '61n136w', '17s11w')]
if args.remaining_from:
    previous = root / args.remaining_from
    prior_batch = json.loads((previous / 'batch.json').read_text())
    assert prior_batch['status'] == 'fail' and prior_batch['hashes'] == frozen
    completed = {entry['site'] for entry in prior_batch['results']}
    for site in completed:
        assert json.loads((previous / site / 'predecessor_parity.json').read_text())['verdict'] == 'pass'
    scenarios = [(site, prior) for site, prior in scenarios if site not in completed]
    # Only previously UNLAUNCHED scenarios can continue in a new artifact set.
    assert all(not (previous / site).exists() for site, _ in scenarios)
    state['retained_prior_batch'] = str(previous)
    state['retained_completed_sites'] = sorted(completed)
    record()

def wait_owned_exit(directory):
    identity = json.loads((directory / 'daemon_identity.json').read_text())
    assert 'Debug::Done()' in (directory / 'engine_flushed.log').read_text(errors='replace')
    deadline = time.monotonic()+10
    observations = 0
    query = ("Get-Process -Name MarsDebug -ErrorAction SilentlyContinue | "
        "Select-Object @{Name='ProcessId';Expression={$_.Id}},"
        "@{Name='CreationFileTime';Expression={"
        "$_.StartTime.ToUniversalTime().ToFileTimeUtc()}} | ConvertTo-Json -Compress")
    while True:
        proc = subprocess.run(['powershell', '-NoProfile', '-Command', query],
            capture_output=True, text=True, check=True)
        rows = json.loads(proc.stdout) if proc.stdout.strip() else []
        if isinstance(rows, dict):
            rows = [rows]
        observations += 1
        if not rows:
            return observations
        for row in rows:
            if row['ProcessId'] != identity['pid'] or row['CreationFileTime'] != identity['process_creation_filetime']:
                raise RuntimeError('Unexpected live game; refusing to wait on or touch it')
        if time.monotonic() >= deadline:
            raise RuntimeError('Owned game still exiting; no next scenario launched')
        time.sleep(.5)
try:
    for site, prior in scenarios:
        assert git('rev-parse', 'HEAD') == head and hashes() == frozen, 'Frozen revision changed'
        state['current_site'] = site
        record()
        print('MASK_SHADOW_BATCH_START ' + site, flush=True)
        proc = subprocess.run([sys.executable, '-u',
            '_ralph/tmp/under80_20260912/profile.py', '--name', name + '/' + site,
            '--prior', '_ralph/runs/under80-20260912/artifacts/' + prior,
            '--setup', '_ralph/tmp/under80_20260912/outer_mask_shadow.lua',
            '--diagnostic-query', 'SBM_OUTER_MASK_SHADOW'], cwd=root)
        if proc.returncode:
            raise RuntimeError(f'{site} exited {proc.returncode}; do not discard/retry')
        exit_observations = wait_owned_exit(out / site)
        assert git('rev-parse', 'HEAD') == head and hashes() == frozen, 'Frozen revision changed'
        diagnostic = json.loads((out / site / 'diagnostic_state.json').read_text())
        parity = json.loads((out / site / 'predecessor_parity.json').read_text())
        assert diagnostic['status'] == parity['verdict'] == 'pass'
        patches = [p for call in diagnostic['calls'] for p in call['patches']]
        summary = {'site': site, 'status': 'pass', 'patches': len(patches),
            'exit_observations': exit_observations,
            'checked': sum(p['checked'] for p in patches),
            'kernel_ms': sum(p['kernel_ms'] for p in patches),
            'scalar_ms': sum(p['scalar_ms'] for p in patches),
            'corrected': sum(p['stats']['corrected'] for p in patches)}
        state['results'].append(summary)
        record()
        print('MASK_SHADOW_BATCH_PASS ' + json.dumps(summary), flush=True)
    state['status'] = 'pass'
except BaseException as exc:
    state['status'] = 'fail'
    state['error'] = str(exc)
    raise
finally:
    state['finished_utc'] = datetime.now(timezone.utc).isoformat()
    record()
