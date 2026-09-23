"""Verify the post-test local checkpoint without rewriting historical verdicts.

The cold runs preceded this checkpoint. Exact payload identity, not a claim of
retroactive commit-before-launch compliance, connects them to this commit.
Archive content hashes are verified by archive_verified_history_460.ps1; this
audit checks its retained manifest, file inventory, and the remaining size cap.
"""
import csv
import hashlib
import importlib.util
import json
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[3]
BASE = ROOT / '_ralph/runs/rules-parity/strict-460-20260923'
ARCHIVE = ROOT.parent / 'super-big-map-test-archive/checkpoint-460-20260923'


def git(*args):
    return subprocess.check_output(['git', '-C', str(ROOT), *args], text=True).strip()


def sha(path):
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def audit():
    baseline = json.loads((BASE / 'failed_sites/17s11w_a/payload_manifest.json').read_text())
    spec = importlib.util.spec_from_file_location('lifecycle_audit', ROOT / '_ralph/tmp/audit_460_lifecycle.py')
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    lifecycle = module.audit()
    checks = {'runtime_and_lifecycle': lifecycle['runtime_and_lifecycle_pass'],
              'clean_worktree': not git('status', '--porcelain'),
              'new_local_checkpoint': git('rev-parse', '--short', 'HEAD') != baseline['head']}
    mismatches = []
    for relative, (size, digest) in baseline['files'].items():
        path = ROOT / relative
        if path.stat().st_size != size or sha(path) != digest:
            mismatches.append(relative + ': differs from measured payload')
        # Git may normalize line endings; apply exactly its clean filter here.
        if git('hash-object', '--path=' + relative, str(path)) != git('rev-parse', 'HEAD:' + relative):
            mismatches.append(relative + ': not the committed content')
    checks['measured_payload_committed_unchanged'] = not mismatches and len(baseline['files']) == 43
    deploy = subprocess.run(['python', str(ROOT / '_ralph/tools/deploy.py'), 'audit'],
                            capture_output=True, text=True, cwd=ROOT)
    checks['deployment'] = deploy.returncode == 0 and json.loads(deploy.stdout)['ok']
    manifest = ARCHIVE / 'manifest.csv'
    with manifest.open(encoding='utf-8-sig', newline='') as stream:
        records = list(csv.DictReader(stream))
    archive_errors = []
    for record in records:
        relative = Path(record['RelativePath'])
        destination = (ARCHIVE / relative).resolve()
        if not destination.is_relative_to(ARCHIVE.resolve()):
            archive_errors.append(str(relative) + ': invalid destination')
        elif not destination.is_file() or destination.stat().st_size != int(record['Bytes']):
            archive_errors.append(str(relative) + ': missing or wrong size')
        if (ROOT / relative).exists():
            archive_errors.append(str(relative) + ': still in workspace')
    checks['archive_inventory'] = bool(records) and not archive_errors
    remaining = sum(path.stat().st_size for path in (ROOT / '_ralph').rglob('*') if path.is_file())
    checks['artifact_size_below_2GB'] = remaining < 2_000_000_000
    return {
        'checkpoint_followup_pass': all(checks.values()),
        'checkpoint': git('rev-parse', 'HEAD'), 'metadata_version': 1091, 'generator_guard': 460,
        'checks': checks, 'payload_mismatches': mismatches, 'archive_errors': archive_errors,
        'archive': str(ARCHIVE), 'archive_manifest_sha256': sha(manifest),
        'archived_files': len(records), 'archived_bytes': sum(int(r['Bytes']) for r in records),
        'remaining_ralph_bytes': remaining,
        'historical_note': 'Cold runs preceded this checkpoint; their recorded head/verdicts are preserved. '
                           'The measured 43-file payload is unchanged. No new game, push, or deletion.',
    }


if __name__ == '__main__':
    result = audit()
    (BASE / 'checkpoint_followup_audit.json').write_text(json.dumps(result, indent=2) + '\n')
    print(json.dumps(result, indent=2))
    raise SystemExit(0 if result['checkpoint_followup_pass'] else 1)
