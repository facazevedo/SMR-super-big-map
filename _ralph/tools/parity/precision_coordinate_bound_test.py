"""Exact-rational propagation for proposed adaptively biased Q22 coordinates.

Premises: exact positive encoding and signed native decode; inherited root/reciprocal
residual checks and regular f32 arithmetic; inherited lobe/polynomial lemmas.
This does not replace native endpoint/domain and complete raster comparisons.
"""
from fractions import Fraction as F

u = F(1, 2**24)
coord = F(1, 2**21)
norm_error = F(3, 2) * coord  # sqrt(2) < 3/2
root_relative = F(1, 2**20) + 4 * u
root_absolute = 2 * u
root_lower_ratio = F(99, 100)
low = (F(17, 100) - norm_error) * (1 - u)
high = (F(6, 5) + norm_error) * (1 + u)
assert root_relative + root_absolute / low**2 < 1 - root_lower_ratio**2
# a*z+b/z is convex on z>0, so the interval maximum is at an endpoint.
native_root_error = max((root_relative*z + root_absolute/z)/(1+root_lower_ratio)
                        for z in (low, high))
radial = norm_error + u * (F(6, 5) + norm_error) + native_root_error
assert radial < F(2, 10**6)
delta = F(2, 10**6)
rho = (F(16, 2**24) + u) / (1 - u)
eta = (1 + rho) * (1 + u) - 1
assert (F(17, 100)+coord)/(F(17, 100)-delta)*eta < F(2, 10**6)
# c/(.85*c-delta) decreases with c, hence evaluate its lowest c.
c = F(1, 5)
assert c*(coord+delta)/(F(85,100)*c-delta) < F(4,10**6)
assert (F(6,5)+delta)/F(9,10)*eta < F(15,10**7)
# Inherited lobe coefficient derivative .47 and arithmetic/second-order 1e-6.
# Normalize by boundaries >=.90; keep c symbolic as constant+coefficient/c.
normal_constant = delta/F(9,10) + F(6,5)/F(9,10)**2 * (F(47,100)*F(2,10**6)+F(1,10**6)) + F(15,10**7)
normal_coefficient = F(6,5)/F(9,10)**2 * F(47,100)*F(4,10**6)
assert normal_constant < F(7,10**6)
assert normal_coefficient < F(3,10**6)

def weight_error(c):
    return F(15,8)*(F(7,10**6)+F(3,10**6)/c)/(1-c)+F(16,10**6)

for c in (F(1,5),F.from_float(.2),F(3,5),F.from_float(.6)):
    assert (7+3/c)/(1-c)==3/c+10/(1-c)
    assert weight_error(c) < F(5,65536)
for c in (F(3,5),F.from_float(.6),F(3,4)):
    assert weight_error(c) < F(7,65536)
for numerator in (5,7):
    assert F(2**24)*F(numerator,65536)==numerator*256
print('PASS rational propagation: radial',float(radial),'normalized',
      float(normal_constant),'+',float(normal_coefficient),'/c; integer U24 allowances1280/1792')
