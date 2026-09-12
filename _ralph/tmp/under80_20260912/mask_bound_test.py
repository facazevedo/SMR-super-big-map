"""Exact rational checks of conservative scalar error-envelope arithmetic."""
from fractions import Fraction as F

coord = F(1, 2**19)
radial_bound = F(55, 10**7)
for radius in [F(17,100),F(12,10)]:
    radial_error = F(1414214,1000000)*coord + radius*coord + F(1,2**24)/radius
    assert radial_error < radial_bound

# Each expression below is convex on the stated closed interval, hence checking
# the endpoints bounds the interval. Positive reciprocal terms supply convexity.
for core in [F(1,5),F(3,4)]:
    axis = (coord+radial_bound)/(F(85,100)*core-radial_bound)+F(2,10**6)
    axis_envelope = F(88,10**7)/core+F(2,10**6)
    assert axis < axis_envelope
    boundary = F(47,100)*axis_envelope+F(1,10**6)
    normalized = (radial_bound+F(4,3)*boundary)/F(9,10)+F(2,10**6)
    normalized_envelope = F(12,10**6)+F(7,10**6)/core
    assert normalized < normalized_envelope
    weight = F(15,8)*normalized_envelope/(1-core)+F(16,10**6)
    assert weight < F(1,4096)
    print('core',float(core),'mask error envelope',float(weight),'limit',float(F(1,4096)))
print('PASS exact-rational envelope checks (native residual and domain checks required at runtime)')
