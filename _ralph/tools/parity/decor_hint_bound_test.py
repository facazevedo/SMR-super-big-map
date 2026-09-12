"""Exact-rational safety reserve for the conservative positive circle hint.

IEEE double basic operations plus native signed64 integers, finite qualified
inputs. Integer products fit signed64. Each double difference has relative error
u; two squares and their sum place computed distance^2 above (1-u)^4 times the
exact squared norm, apart from negligible underflow. A generous 1e-6 norm reserve
dominates all subnormal errors. No approximate sqrt is used by production.
"""
from fractions import Fraction as F

u = F(1, 2**53)
limit, max_radius = 2**26, 2**16
assert 2*(2*limit)**2 < 2**63
assert (limit+max_radius)**2 < 2**63
# Computed shrunken reach <= (R*(1+u)-1)*(1+u).
# Positive test implies D < shrunken*(1+u)/(1-u)^2 + underflow reserve.
# The excess over R-1 is affine increasing in R, so maximize at largest reach.
factor = (1+u)**2/(1-u)**2
reach = F(limit+max_radius)
excess = (reach*(1+u)-1)*factor - (reach-1) + F(1, 10**6)
assert excess < F(2, 10**6)
# Both query and circle bounding-box endpoint calculations are <=2*limit in
# magnitude. Allow two rounded operations for each of the two opposing edges.
endpoint_error = 4*u*(2*limit)
assert excess+endpoint_error < F(1, 2)
# Thus the exact axis intervals overlap by >1-excess, and rounded intervals
# retain >1/2 unit overlap. Positive power-of-two scaling and floor are monotone:
# their inclusive cell-index ranges overlap, so the old index must visit c.
print('PASS hint one-unit margin: norm excess', float(excess),
      'plus bounding endpoint error', float(endpoint_error), '< 0.5')
