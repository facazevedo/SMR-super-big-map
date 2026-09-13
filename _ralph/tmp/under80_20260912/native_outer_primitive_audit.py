"""Check engine f32 exports against exact rational operation-error bounds.

This is implementation conformance evidence over explicit fixtures, not a proof
over every possible f32 operand. Nonlinear precision is checked at runtime too.
"""
from fractions import Fraction as F
import argparse
import json
from pathlib import Path
import struct

root = Path(__file__).resolve().parents[3]
out = root / '_ralph/runs/under80-20260912/artifacts/native_outer_primitives'
parser = argparse.ArgumentParser()
parser.add_argument('--rounding-model', choices=('ties_up', 'ties_even'), default='ties_even')
args = parser.parse_args()
capture = json.loads((out / 'diagnostic_state.json').read_text())
assert capture['status'] == 'pass'
values = {}
for entry in capture['calls']:
    data = (out / (entry['name'] + '.f32')).read_bytes()
    assert len(data) == 4096, (entry['name'], len(data))
    values[entry['name']] = [F(v[0]) for v in struct.iter_unpack('<f', data)]
u = F(1, 2**24)
summary = {}
failures = []
for name, actual in values.items():
    worst = F(0)
    checked = 0
    for i, value in enumerate(actual):
        a, b, square = values['x'][i], values['y'][i], values['square'][i]
        if name in ('x', 'y', 'square'):
            continue
        if name == 'mul_grid':
            exact, bound = a*b, u*abs(a*b)
        elif name == 'fma_grid':
            exact = a*b-1
            bound = u*abs(a*b)*(1+u)+u*abs(exact)
        elif name == 'scale_ratio':
            exact = a*F(24, 100)
            bound = ((1+u)**2-1)*abs(exact)
        elif name == 'polynomial_a':
            exact = a*6-15
            bound = u*abs(a*6)*(1+u)+u*abs(exact)
        elif name == 'add_grid':
            exact = a+b
            bound = u*abs(exact)
        elif name == 'add_scaled_grid':
            term = b*F(-2, 16777216)
            exact = a+term
            bound = abs(term)*((1+u)**3-1)+u*abs(exact)
        elif name == 'encoded_add':
            exact = a+F(14763950, 16777216)
            bound = u*abs(exact)
        elif name == 'clamp':
            exact, bound = min(F(1), max(F(0), a)), F(0)
        elif name == 'abs':
            exact, bound = abs(a), F(0)
        elif name == 'round_positive':
            scaled = abs(a)*4096
            lower = scaled.__floor__()
            fraction = scaled-lower
            up = fraction > F(1, 2) or (fraction == F(1, 2)
                and (args.rounding_model == 'ties_up' or lower % 2 == 1))
            exact, bound = F(lower+int(up)), F(0)
        elif name == 'root':
            assert value > 0 and square*(1-2*u)**2 < value*value < square*(1+2*u)**2, (name, i)
            checked += 1
            continue
        elif name == 'inverse':
            exact, bound = F(1, square), 6*u/square
        else:
            raise AssertionError(name)
        error = abs(value-exact)
        if error > bound:
            failures.append({'operation': name, 'index': i, 'actual': float(value),
                'expected': float(exact), 'error': float(error), 'bound': float(bound)})
        if bound:
            worst = max(worst, error/bound)
        checked += 1
    if checked:
        summary[name] = {'checked': checked, 'max_fraction_of_bound': float(worst)}
result = {'status': 'fail' if failures else 'pass', 'checks': sum(v['checked'] for v in summary.values()),
          'operations': summary, 'failures': failures, 'rounding_model': args.rounding_model,
          'scope': 'fixture conformance, not exhaustive proof'}
target = out / ('arithmetic_audit_' + args.rounding_model + '.json')
assert not target.exists(), 'Preserve evidence'
target.write_text(json.dumps(result, indent=2))
print(json.dumps(result, indent=2))
assert not failures, 'Native primitive conformance failed; evidence preserved'
