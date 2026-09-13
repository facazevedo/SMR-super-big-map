"""Fresh v992 reassessment only; never rewrites the historical v992 decision."""
import json
from pathlib import Path
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[3]
RUN = ROOT / '_ralph/runs/under80-20260912'
ART = RUN / 'artifacts'
PREFIX = 'v992_revised_target'
target = ART / (PREFIX + '_review.json')
if target.exists():
    raise RuntimeError('Preserve existing revised-target review')
read = lambda path: json.loads(path.read_text())
reference = read(ART / (PREFIX + '_reference/reference_audit.json'))
average = read(ART / (PREFIX + '_reference/reference_average_audit.json'))
assert reference['clean_exact_evidence'] and not reference['issues']
assert average['clean_exact_evidence'] and average['average_s'] < 85
assert average['reference_samples_s'] == [row['t0_to_t1_s'] for row in reference['samples'][:3]]
assert len(reference['samples']) == 4
code_commit = reference['samples'][0]['checkpoint']['commit']
assert all(row['checkpoint']['commit'] == code_commit and row['checkpoint']['version'] == '992'
           and not row['issues'] for row in reference['samples'])
expected = read(ART / 'v992_offline/all_results.json')
offline = read(ART / (PREFIX + '_offline/all_results.json'))
assert len(offline) == len(expected) == 85 and all(row['exit'] == 0 for row in offline)
assert [(row['name'], row['command']) for row in offline] == [(row['name'], row['command']) for row in expected]
payload = ['Code', 'Images', 'metadata.lua', 'items.lua']
for left, right in [('343bee6', code_commit), (code_commit, None)]:
    command = ['git', 'diff', '--exit-code', left] + ([right] if right else []) + ['--'] + payload
    subprocess.run(command, cwd=ROOT, check=True)
changed = subprocess.check_output(['git', 'diff', '--name-only', '56fbf44', code_commit, '--'] + payload,
                                  cwd=ROOT, text=True).splitlines()
assert sorted(changed) == ['Code/sbm_map_generation.lua', 'Code/sbm_version.lua', 'metadata.lua']
source_review = RUN / 'v992_revised_target_review.md'
assert source_review.exists()
native_proofs = []
for name in ('v992_filler_production_reference', 'v992_filler_production_61n'):
    proof = read(ART / name / 'private_process_audit.json')
    assert proof['status'] == 'pass' and not proof['issues'] and proof['normal_shutdown']
    assert proof['checkpoint']['commit'].startswith('343bee6')
    native_proofs.append(str((ART / name / 'private_process_audit.json').relative_to(ROOT)))
identities = [tuple(row['identity']) for row in reference['samples']]
sites = []
for site in ('15S67E', '24S74W', '45S120W', '61N136W', '17S11W'):
    row = read(ART / (PREFIX + '_matrix') / (site.lower() + '_judgment.json'))
    assert row['commit'] == code_commit and row['version'] == '992'
    assert not row['issues'] and row['pair']['verdict'] == 'pass'
    assert all(value['verdict'] == ('pending' if name in ('seed-parity', 'process') else 'pass')
               for name, value in row['gates'].items())
    identities.append((row['identity']['pid'], row['identity']['process_creation_filetime']))
    sites.append(dict(site=site, correctness='pass', t0_to_t1_s=row['t0_to_t1_s'],
                      prior_t0_to_t1_s=row['prior_t0_to_t1_s'], timing_is_acceptance_gate=False))
assert len(identities) == len(set(identities)) == 9
deployment = json.loads(subprocess.check_output([sys.executable, '_ralph/tools/deploy.py', 'audit'], cwd=ROOT, text=True))
assert deployment['ok'] and deployment['source_files'] == deployment['destination_files'] == 38
review = dict(version=992, code_commit=code_commit, exact_original_payload='343bee6',
              target_seconds=85, target_scope='reference_arithmetic_mean',
              reference_samples_s=average['reference_samples_s'], average_s=average['average_s'],
              prior_average_s=average['prior_average_s'], saving_s=average['saving_s'],
              control_s=average['control_s'], target_reached=True, correctness_preserved=True,
              offline_commands_passed=85, unique_fresh_acceptance_processes=9, scenarios=sites,
              native_proofs=native_proofs, source_review=str(source_review.relative_to(ROOT)),
              source_rng_review='Exact qualified native source and unchanged seeded consumers; see source review.',
              process_review='Nine unique fresh hidden owned identities, frozen checkpoint and complete flushed-log audits.',
              visual_review='Inherited accepted geometry through full exact grids and individual rocks; no new screenshot claim.',
              deployment=deployment, historical_rejection_unchanged=True,
              qualification='Fresh fixed confirmation under explicit user revised scope/metric; not an under80 or all-site speedup claim.')
with target.open('x', encoding='utf-8') as stream:
    json.dump(review, stream, indent=2)
print(json.dumps(review, indent=2))
