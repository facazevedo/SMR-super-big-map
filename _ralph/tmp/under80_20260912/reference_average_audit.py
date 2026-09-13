"""Arithmetic-mean supplement; never overwrites or weakens the full reference audit."""
import argparse
import json
from pathlib import Path
import statistics


def summarize(samples, prior):
    if len(samples) != 3 or len(prior) != 3:
        raise ValueError('Exactly three scheduled reference samples are required')
    if any(type(v) not in (int, float) or not 0 < v < 3600 for v in samples + prior):
        raise ValueError('Invalid reference clock')
    current_mean, previous_mean = statistics.fmean(samples), statistics.fmean(prior)
    return dict(reference_samples_s=samples, prior_reference_samples_s=prior,
                average_s=current_mean, prior_average_s=previous_mean,
                saving_s=previous_mean-current_mean, target_seconds=85,
                target_scope='reference_arithmetic_mean',
                under_target_reached=current_mean < 85,
                reference_improved=current_mean < previous_mean)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--out', type=Path, required=True)
    parser.add_argument('--prior', type=Path, required=True)
    args = parser.parse_args()
    target = args.out / 'reference_average_audit.json'
    if target.exists():
        raise RuntimeError('Preserve prior average audit')
    read = lambda p: json.loads(p.read_text())
    full = read(args.out / 'reference_audit.json')
    if not full['clean_exact_evidence'] or full['issues'] or len(full['samples']) != 4:
        raise RuntimeError('Complete full reference/control preservation audit is required')
    samples, prior = [], []
    for index, suffix in enumerate(('a', 'b', 'c', 'control')):
        audited = full['samples'][index]
        current = read(args.out / ('14n134w_' + suffix) / 'rules_report.json')
        before = read(args.prior / ('14n134w_' + suffix) / 'rules_report.json')
        if audited['sample'] != suffix or audited['issues'] or current['status'] != 'complete' or current.get('error'):
            raise RuntimeError('Scheduled sample/audit mismatch')
        seconds = current['rules']['t0_to_t1_ms'] / 1000
        previous = before['rules']['t0_to_t1_ms'] / 1000
        if audited['t0_to_t1_s'] != seconds or audited['prior_t0_to_t1_s'] != previous:
            raise RuntimeError('Audit clocks differ from raw reports')
        if suffix != 'control':
            samples.append(seconds)
            prior.append(previous)
    result = summarize(samples, prior)
    result.update(clean_exact_evidence=True, full_preservation_audit='reference_audit.json',
                  control_s=full['samples'][3]['t0_to_t1_s'],
                  prior_control_s=full['samples'][3]['prior_t0_to_t1_s'],
                  median_s=full['median_s'], prior_median_s=full['prior_median_s'],
                  qualification='All three scheduled runs retained. Mean requested explicitly by user; no replacement samples or claim of causal/statistical significance.')
    with target.open('x', encoding='utf-8') as stream:
        json.dump(result, stream, indent=2)
    print(json.dumps(result, indent=2))


if __name__ == '__main__':
    main()
