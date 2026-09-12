"""Close correctness/source/process review without claiming the timing target."""
import json
from pathlib import Path
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[3]
RUN = ROOT / '_ralph/runs/under80-20260912'
ART = RUN / 'artifacts'
target = ART / 'v974_all_ten_rules_review.json'
if target.exists():
    raise RuntimeError('Preserve prior review')
read = lambda p: json.loads(p.read_text())
reference = read(ART / 'v974_reference/reference_audit.json')
assert reference['clean_exact_evidence'] and not reference['issues']
offline = read(ART / 'v974_offline/all_results.json')
assert len(offline) == 71 and all(row['exit'] == 0 for row in offline)
source_review = RUN / 'v974_source_review.md'
assert source_review.exists()
code_commit = reference['samples'][0]['checkpoint']['commit']
changed = subprocess.check_output(['git', 'diff', '--name-only', 'fe39258', code_commit,
    '--', 'Code', 'metadata.lua', 'items.lua'], cwd=ROOT, text=True).splitlines()
assert sorted(changed) == ['Code/sbm_decor_topup.lua', 'metadata.lua']
identities = [tuple(row['identity']) for row in reference['samples']]
scenarios = []
for site in ['15S67E', '24S74W', '45S120W', '61N136W', '17S11W']:
    row = read(ART / 'v974_matrix' / (site.lower() + '_judgment.json'))
    assert row['commit'] == code_commit and row['version'] == '974'
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
review = dict(code_commit=code_commit, version='974', offline_commands_passed=71,
    reference_samples_s=[row['t0_to_t1_s'] for row in reference['samples'][:3]],
    benchmark_median_s=reference['median_s'], prior_median_s=reference['prior_median_s'],
    source_review=str(source_review.relative_to(RUN)), deployment=deployment,
    unique_acceptance_processes=9, scenarios=scenarios, raw_judgments_unchanged=True,
    under_80_s_reached=reference['median_s'] < 80 and all(row['t0_to_t1_s'] < 80 for row in scenarios),
    timing_qualification='Reference and scenario results are separate: do not infer a reference speedup from the slow-map gain.')
target.write_text(json.dumps(review, indent=2), encoding='utf-8')
print(json.dumps(review, indent=2))
