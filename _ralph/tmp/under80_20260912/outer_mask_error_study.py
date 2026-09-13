"""NONDEPLOYED numerical study, not a correctness certificate or speed oracle.

Replay captured real patch geometry with the literal scalar formula and a proposed
normalized-coordinate f32 expression. Reports observed errors and correction-budget
coverage. A small observed error NEVER proves a universal/native bound. Actual-engine
residual tests, rational bounds, failure ownership, U12/full-grid shadows remain needed.
Run only after cold benchmark processes have closed (this is CPU-heavy research).
"""
import argparse
import json
import math
from pathlib import Path
import struct

def f32(value):
    return struct.unpack('f', struct.pack('f', value))[0]

def mda(value, mul, div=1, add=0):
    return f32(f32(f32(value * mul) / div) + add)

def plus(a, b):
    return f32(a + b)

def clamp(value, lo=0, hi=1):
    return max(lo, min(hi, value))

def smooth(t):
    return t*t*t*(t*(t*6-15)+10)

def native_smooth(t):
    polynomial = mda(t, 6, 1, -15)
    polynomial = mda(polynomial, t, 1, 10)
    cube = mda(mda(t, t), t)
    return mda(polynomial, cube)

def coordinate(value):
    # Conceptual Q22 value only. Positive native storage/span qualification is
    # deliberately NOT modeled/proved by this scalar numerical experiment.
    return f32(math.floor(value * 4194304 + .5) / 4194304)

def coefficient(value):
    return f32(math.floor(value * 8388608 + .5) / 8388608)

def patch_harmonic(row):
    # Prefer the exact scalar value produced by the engine's original expression,
    # avoiding Python/Lua libm differences in the preliminary numeric study.
    if 'cached_zero_harmonic' in row:
        return row['cached_zero_harmonic']
    p = row['patch']
    return .52*math.sin(p['phase']) + .30*math.sin(-p['phase']*1.37) + .18*math.sin(p['phase']*.73)

def literal(row, x, y):
    p = row['patch']
    dx, dy = x-p['cx'], y-p['cy']
    distance = math.sqrt(dx*dx+dy*dy)
    weight = 0
    if distance <= p['core_cells']:
        weight = 1
    elif distance < row['radius']:
        ux, uy = (dx/distance, dy/distance) if distance > .0001 else (1, 0)
        along = ux*p['relief_x']+uy*p['relief_y']
        harmonic = patch_harmonic(row)
        width = clamp(1+row['irregularity']*harmonic+.12*(2*along*along-1)-.06*along, .50, 1.35)
        outer = p['core_cells']+row['base_transition']*width
        if distance < outer:
            t = clamp((distance-p['core_cells'])/max(.0001, outer-p['core_cells']))
            weight = 1-smooth(t)
    for guard in row['guards']:
        if weight == 0:
            break
        px, py = x-guard['cx'], y-guard['cy']
        d = math.sqrt(px*px+py*py)
        if d <= guard['radius']:
            factor = 0
        elif guard['transition'] <= 0 or d >= guard['radius']+guard['transition']:
            factor = 1
        else:
            factor = smooth((d-guard['radius'])/guard['transition'])
        weight *= factor
    return weight

def proposed(row, x, y, coordinates):
    world = coordinates == 'world'
    p, scale = row['patch'], 1 if world else row['radius']
    encode = f32 if world else coordinate
    dx, dy = encode((x-p['cx'])/scale), encode((y-p['cy'])/scale)
    if world:
        assert dx == x-p['cx'] and dy == y-p['cy'] and dx*dx+dy*dy <= 16777216
        assert dx == int(dx) and dy == int(dy) and p['core_cells'] >= 1
    distance = f32(math.sqrt(plus(mda(dx, dx), mda(dy, dy))))
    # Clamp below the observed minimum core ratio; qualification must be proved.
    inverse = f32(1/max(distance, 1 if world else 1/32))
    ux, uy = mda(dx, inverse), mda(dy, inverse)
    along = plus(mda(ux, coefficient(p['relief_x'])), mda(uy, coefficient(p['relief_y'])))
    harmonic = patch_harmonic(row)
    width = plus(coefficient(1+row['irregularity']*harmonic-.12), mda(mda(along, along), 24, 100))
    width = plus(width, mda(along, -6, 100))
    width = clamp(width, f32(.50), f32(1.35))
    denominator = mda(width, coefficient(row['base_transition']/scale))
    numerator = plus(distance, -coefficient(p['core_cells']/scale))
    t = clamp(mda(numerator, f32(1/denominator)))
    weight = clamp(mda(native_smooth(t), -1, 1, 1))
    for guard in row['guards']:
        gx, gy = encode((x-guard['cx'])/scale), encode((y-guard['cy'])/scale)
        if world:
            assert gx == x-guard['cx'] and gy == y-guard['cy'] and gx*gx+gy*gy <= 16777216
            assert gx == int(gx) and gy == int(gy)
        d = f32(math.sqrt(plus(mda(gx, gx), mda(gy, gy))))
        radius = coefficient(guard['radius']/scale)
        transition = coefficient(guard['transition']/scale)
        if transition <= 0:
            # A discontinuous guard needs a separate boundary certificate; this
            # comparison is only an intentionally unproved prototype behavior.
            factor = 0 if d <= radius else 1
        else:
            gt = clamp(mda(plus(d, -radius), f32(1/transition)))
            factor = clamp(native_smooth(gt))
        weight = mda(weight, factor)
    return clamp(weight)

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('capture', type=Path)
    parser.add_argument('--out', type=Path, required=True)
    parser.add_argument('--coordinates', choices=['normalized', 'world'], default='normalized')
    args = parser.parse_args()
    capture = json.loads(args.capture.read_text())
    assert capture['status'] == 'pass'
    args.out.mkdir(parents=True, exist_ok=False)
    def lua(value):
        if value is None: return 'nil'
        if isinstance(value, bool): return 'true' if value else 'false'
        if isinstance(value, (int, float)): return repr(value)
        if isinstance(value, str): return json.dumps(value)
        if isinstance(value, list): return '{' + ','.join(map(lua, value)) + '}'
        return '{' + ','.join('[' + lua(k) + ']=' + lua(v) for k, v in value.items()) + '}'
    geometry = [row for call in capture['calls'] for row in call['patches']]
    (args.out / 'geometry.lua').write_text('return ' + lua(geometry))
    results = []
    for call in capture['calls']:
        for row in call['patches']:
            assert not row['atan2_present'], 'only existing missing-atan2 behavior modeled'
            checks = changes = 0
            worst = 0
            worst_location = None
            reference_bytes = bytearray()
            budgets = {str(n): {'ambiguous': 0, 'false_certificate': 0, 'bound_exceeded': 0}
                       for n in (1, 2, 4, 8, 16)}
            for cy in range(row['height']):
                for cx in range(row['width']):
                    x = row['x0'] + cx*row['sample_step']
                    y = row['y0'] + cy*row['sample_step']
                    old, new = literal(row, x, y), proposed(row, x, y, args.coordinates)
                    a, b = math.floor(old*4096+.5), math.floor(new*4096+.5)
                    changes += a != b
                    reference_bytes.extend(struct.pack('<H', a))
                    if abs(new-old) > worst:
                        worst = abs(new-old)
                        worst_location = dict(x=x, y=y, scalar=old, proposed=new)
                    checks += 1
                    for key, count in budgets.items():
                        epsilon = int(key)/65536
                        low = math.floor(clamp(new-epsilon)*4096+.5)
                        high = math.floor(clamp(new+epsilon)*4096+.5)
                        count['ambiguous'] += low != high
                        count['false_certificate'] += low == high and a != low
                        count['bound_exceeded'] += abs(new-old) > epsilon
            results.append(dict(samples=checks, guards=len(row['guards']), raw_u12_differences=changes,
                                observed_max_weight_error=worst, worst_location=worst_location,
                                hypothetical_budgets=budgets))
            (args.out / f'patch_{len(results):03d}_scalar.u16').write_bytes(reference_bytes)
            (args.out / f'patch_{len(results):03d}.json').write_text(json.dumps(results[-1], indent=2))
            print(f'Patch {len(results)}: {checks} samples, {len(row["guards"])} guards, '
                  f'{changes} raw rounded differences, observed max error {worst:.9g}', flush=True)
    summary = dict(status='empirical_only_not_a_proof', coordinates=args.coordinates, patches=results,
                   samples=sum(r['samples'] for r in results),
                   raw_u12_differences=sum(r['raw_u12_differences'] for r in results),
                   observed_max_weight_error=max(r['observed_max_weight_error'] for r in results))
    (args.out / 'results.json').write_text(json.dumps(summary, indent=2))
    print(json.dumps({k: v for k, v in summary.items() if k != 'patches'}, indent=2))

if __name__ == '__main__':
    main()
