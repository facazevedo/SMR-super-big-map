"""Conditional local-quintic certificate; exact rational bounds, not sampled proof.

Inherits the accepted Q22/root/reciprocal/domain contracts and v990's checked
propagation. This is a private hypothesis until actual native and cold gates pass.
"""
from fractions import Fraction as F
from pathlib import Path
import runpy

prior = runpy.run_path(str(Path(__file__).with_name('apron_tight_bound_test.py')))
u, u64 = prior['u'], prior['u64']
W = 2**24
poly = prior['complement_error'] + u/2 + 513*u64
assert poly < 64*u
assert prior['argument_error'] < 6*u

# Runtime d=floor(((5.6e-6+1.8e-6/c)/(1-c))*W+6)+2.
# Positive arithmetic, c in [.2,.75]; denominator >=.25. Decimal conversions
# and seven rounded CPU operations fit this deliberately generous relative bound.
cpu_relative = (1+u64)**16/(1-u64)**16-1
assert 600*cpu_relative < F(1,1000000)
def normalized(c):
    return (F(56,10**7)+F(18,10**7)/c)/(1-c)
endpoints = [F(1,5), F.from_float(.2), F(3,4)]
# Positive reciprocal decomposition is convex, so endpoints bound the domain.
assert max(normalized(c)*W for c in endpoints)*(1+cpu_relative)+8 < 600
# Floor(x+6)+2 >= x+7: the extra whole unit covers CPU error, including +6.
assert 1 > 600*cpu_relative+6*u64

# q=t(1-t) is 1-Lipschitz on [0,1]. The two native regular operations yield
# qhat with absolute error <=.25*((1+u)^2-1) <1 U24 unit.
q_error = F(1,4)*((1+u)**2-1)*W
assert q_error < 1
# Q=clamp(fl(qhat*W+d+2),0,W/4). Dyadic scaling is exact; extra2 units
# dominate q error and final addition roundoff. Clamp retains the true q<=.25.
q_add_round = (F(W,4)+q_error+600+2)*u
assert q_error+q_add_round < 2

# E3=fl(fl(Q*Q/W)*(90*d)/W+240), i.e. three times the local weight allowance
# with80 U24 units reserved for polynomial/cubic arithmetic. All scalar API
# arguments fit exact f32 integers. Two products round; dyadic divisions exact.
assert 90*600 < W
max_variable = F(90*600,16)
field_round = max_variable*((1+u)**2-1)+(max_variable*(1+u)**2+240)*u
assert field_round < F(1,1000)
# E3/3 >= 30*qmax^2*d +80 - field_round/3. Native/scalar polynomial remainder
# needs <64 units: retain more than15 additional units for downstream rounding.
assert 80-field_round/3-64 > 15
assert (max_variable+240+field_round)/3 < 1206

# Upper weight: GridAddMulDiv(mask,E3,1,3) allows divide OR rounded reciprocal
# and product, then addition (the native implementation need not fuse them).
# Its absolute downward error is below2 U24 units, well within the >15 padding.
upper_round = 1206*((1+u)**2-1)+(W+1206*(1+u)**2)*u
assert upper_round < 2
# Clamped upper weight therefore encloses min(1,w+e), where e is the analytic
# local error. Square + displacement product + E3 product lose <=3 relative u.
# Extra coefficient padding alone encloses those losses (even ignoring the
# additional upper-weight padding). Native dyadic divisions add no rounding.
assert (F(1206)+15)*(1-u)**3 > 1206
# Tiny underflow/FTZ cases and any additional bracket-application arithmetic
# receive ONE NEW H unit, not presumed slack in the inherited four-H reserve.
# These added operations are nonnegative with E3/W<1, so an underflowed term
# cannot be amplified; intermediate upper-weight square is >=80^2/W >2^-126.
assert F(80**2,W) > F(1,2**126)
assert 8*F(1,2**126) < 1
print('PASS conditional local bound: polynomial remainder',float(poly/u),
      '<64 U24; q padding2; E3 rounding',float(field_round),
      '<.001 U24; downstream padding>15 U24; separate +1 H reserve')
