"""Conditional exact bounds for positive whole-cell certificates, not fixture proof.

Model: binary64 ordinary arithmetic/floor/ceil, signed64 exact integer operations
when applicable, finite qualified inputs. No scalar or native sqrt is used.
"""
from fractions import Fraction as F

u=F(1,2**53)
coordinate_limit=2**24
query_radius_limit=2**16
cell=4096
# Membership division is an exact power-of-two scaling except subnormal rounding.
# Even total loss of a subnormal quotient cannot move the point by one unit.
assert F(1,2**1022)*cell<1
# Cell endpoints are exact integers. Each endpoint-center subtraction has this
# absolute error bound; ceil(rounded distance)+1 strictly encloses the true one.
corner_error=u*(2*coordinate_limit+cell+1)
assert corner_error<1
# Qualified rounded corner coordinates and their squares/sum are exactly
# representable even if the engine chooses binary64 rather than signed64.
assert 2*(2**25)**2<2**53
max_reach=coordinate_limit+query_radius_limit
assert max_reach**2<2**53
assert 2*(2*coordinate_limit)**2<2**63

# Certificate gives true D < floor(c.r)+floor(r_learned)-1 <= R-1 for any
# subsequent radius >= floor(r_learned). Old computed norm is at most
# (R-1)*(1+u)^2, computed reach norm at least R*(1-u)^2 (looser than 3/2).
# Comparing these norms is equivalent to the strict squared predicate for
# nonnegative values. Bound the difference at the largest qualified reach.
rounding_loss=max_reach*((1+u)**2-(1-u)**2)
underflow_reserve=F(1,10**6)
assert rounding_loss+underflow_reserve<F(1,2)
# The exact intervals overlap on both axes by >1. Rounded endpoints in the
# accepted index preserve this overlap; inclusive floor-cell ranges must meet.
endpoint_error=4*u*(2*coordinate_limit+query_radius_limit)
assert endpoint_error+underflow_reserve<F(1,2)
print('PASS conditional positive-cell bounds: integer squares exact; corner error',
      float(corner_error),'; predicate rounding loss',float(rounding_loss),
      '; index endpoint error',float(endpoint_error),'all below one-unit reserves')
