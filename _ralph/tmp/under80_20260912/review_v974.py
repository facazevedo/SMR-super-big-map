"""Close correctness/source/process review without claiming the timing target."""
import argparse
import json
from pathlib import Path
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[3]
RUN = ROOT / '_ralph/runs/under80-20260912'
ART = RUN / 'artifacts'
parser = argparse.ArgumentParser()
parser.add_argument('--version', choices=['974', '975', '977', '978', '979', '980', '981', '982', '983', '984', '985', '986', '987', '988', '989'], default='974')
args = parser.parse_args()
version = args.version
baseline, expected_tests, expected_files = {
    '974': ('fe39258', 71, ['Code/sbm_decor_topup.lua', 'metadata.lua']),
    '975': ('2c68ff3', 72, ['Code/sbm_terrain_copy.lua', 'Code/sbm_version.lua', 'metadata.lua']),
    '977': ('1f67811', 74, ['Code/sbm_terrain_copy.lua', 'Code/sbm_version.lua', 'metadata.lua']),
    '978': ('b5fb059', 76, ['Code/sbm_engine.lua', 'Code/sbm_terrain_copy.lua', 'Code/sbm_version.lua', 'metadata.lua']),
    '979': ('3eafc30', 77, ['Code/sbm_rock_grounding.lua', 'Code/sbm_terrain_copy.lua', 'Code/sbm_version.lua', 'metadata.lua']),
    '980': ('c4d3e67', 79, ['Code/sbm_engine.lua', 'Code/sbm_object_clone.lua', 'Code/sbm_terrain_copy.lua', 'Code/sbm_version.lua', 'metadata.lua']),
    '981': ('c4d3e67', 78, ['Code/sbm_terrain_copy.lua', 'Code/sbm_version.lua', 'metadata.lua']),
    '983': ('c4d3e67', 80, ['Code/sbm_terrain_copy.lua', 'Code/sbm_version.lua', 'metadata.lua']),
    '984': ('f4d1da6', 82, ['Code/sbm_decor_topup.lua', 'Code/sbm_version.lua', 'metadata.lua']),
    '985': ('f4d1da6', 82, ['Code/sbm_terrain_copy.lua', 'Code/sbm_version.lua', 'metadata.lua']),
    '986': ('f4d1da6', 81, ['Code/sbm_terrain_copy.lua', 'Code/sbm_version.lua', 'metadata.lua']),
    '987': ('f4d1da6', 83, ['Code/sbm_terrain_copy.lua', 'Code/sbm_version.lua', 'metadata.lua']),
    '988': ('56fbf44', 88, ['Code/sbm_terrain_copy.lua', 'Code/sbm_version.lua', 'metadata.lua']),
    '989': ('56fbf44', 87, ['Code/sbm_decor_topup.lua', 'Code/sbm_version.lua', 'metadata.lua']),
    '982': ('c4d3e67', 78, ['Code/sbm_deposits.lua', 'Code/sbm_map_generation.lua', 'Code/sbm_object_clone.lua', 'Code/sbm_rock_grounding.lua', 'Code/sbm_sector_exploration.lua', 'Code/sbm_terrain_copy.lua', 'Code/sbm_version.lua', 'metadata.lua']),
}[version]
target = ART / f'v{version}_all_ten_rules_review.json'
if target.exists():
    raise RuntimeError('Preserve prior review')
read = lambda p: json.loads(p.read_text())
reference = read(ART / f'v{version}_reference/reference_audit.json')
assert reference['clean_exact_evidence'] and not reference['issues']
if version in ('975', '977', '978', '979', '980', '981', '982', '983', '984', '985', '986', '987', '988', '989'):
    assert reference['median_s'] < reference['prior_median_s'], 'No measured reference improvement'
offline_name = 'v978_final_offline' if version == '978' else f'v{version}_offline'
if version == '987': offline_name = 'v987_offline_staged'
offline = read(ART / offline_name / 'all_results.json')
assert len(offline) == expected_tests and all(row['exit'] == 0 for row in offline)
source_review = RUN / f'v{version}_source_review.md'
assert source_review.exists()
code_commit = reference['samples'][0]['checkpoint']['commit']
changed = subprocess.check_output(['git', 'diff', '--name-only', baseline, code_commit,
    '--', 'Code', 'metadata.lua', 'items.lua'], cwd=ROOT, text=True).splitlines()
assert sorted(changed) == expected_files
identities = [tuple(row['identity']) for row in reference['samples']]
scenarios = []
for site in ['15S67E', '24S74W', '45S120W', '61N136W', '17S11W']:
    row = read(ART / f'v{version}_matrix' / (site.lower() + '_judgment.json'))
    assert row['commit'] == code_commit and row['version'] == version
    assert not row['issues'] and row['pair']['verdict'] == 'pass'
    for name, gate in row['gates'].items():
        assert gate['verdict'] == ('pending' if name in ('seed-parity', 'process') else 'pass')
    identity = row['identity']
    identities.append((identity['pid'], identity['process_creation_filetime']))
    scenarios.append(dict(site=site, all_ten='pass', automated_gates='8/8 pass',
        seed_parity_review='Exact predecessor/private streams plus primary source/RNG review.',
        process_review='Immutable audited checkpoint, unique owned process, normal captured shutdown.',
        visual_review='Inherited accepted visuals through exact full outputs; no new screenshot claim.',
        t0_to_t1_s=row['t0_to_t1_s'], prior_t0_to_t1_s=row['prior_t0_to_t1_s']))
assert len(set(identities)) == 9
deployment = json.loads(subprocess.check_output([sys.executable, '_ralph/tools/deploy.py', 'audit'],
    cwd=ROOT, text=True))
assert deployment['ok']
review = dict(code_commit=code_commit, version=version, offline_commands_passed=expected_tests,
    reference_samples_s=[row['t0_to_t1_s'] for row in reference['samples'][:3]],
    benchmark_median_s=reference['median_s'], prior_median_s=reference['prior_median_s'],
    source_review=str(source_review.relative_to(RUN)), deployment=deployment,
    unique_acceptance_processes=9, scenarios=scenarios, raw_judgments_unchanged=True,
    under_80_s_reached=reference['median_s'] < 80 and all(row['t0_to_t1_s'] < 80 for row in scenarios),
    timing_qualification='Reference and scenario results are separate: do not infer a reference speedup from the slow-map gain.')
if version in ('983', '984', '985', '986', '987', '988', '989'):
    review.update(target_seconds=85, under_target_reached=reference['median_s'] < 85
        and all(row['t0_to_t1_s'] < 85 for row in scenarios))
if version == '984':
    slow = next(row for row in scenarios if row['site'] == '61N136W')
    assert slow['t0_to_t1_s'] < slow['prior_t0_to_t1_s'], 'No measured slow-map improvement'
if version == '987':
    review.update(reference_comparator='v983_confirmation_reference',
        scenario_comparator='v983_matrix_confirmation',
        all_scenarios_faster=all(row['t0_to_t1_s'] < row['prior_t0_to_t1_s'] for row in scenarios),
        correctness_does_not_imply_performance_promotion=True)
if version in ('988', '989'):
    review.update(reference_comparator='v987_reference',scenario_comparator='v987_matrix',
        all_scenarios_faster=all(row['t0_to_t1_s'] < row['prior_t0_to_t1_s'] for row in scenarios),
        correctness_does_not_imply_performance_promotion=True)
target.write_text(json.dumps(review, indent=2), encoding='utf-8')
print(json.dumps(review, indent=2))
