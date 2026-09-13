"""Conditional exact-rational error propagation for the private outer mask.

Premises still requiring native/source audit: ordinary f32 arithmetic (unit roundoff
2^-24), exact qualified integer/dyadic fields, standard monotone scalar sqrt, and the
implemented residual/census checks. This does NOT certify a production candidate.
"""
from fractions import Fraction as F

u = F(1, 2**24)
u64 = F(1, 2**53)
amplifier = 2**30
# S >= 1 after the clamped-square construction. The original integer squared
# distance is retained independently for hard-guard classification.
residual = (2*u + 1/(amplifier*(1-u))) / (1-u)
root_upper_square = (1+residual)/(1-u)
root_lower_square = (1-residual)/(1+u)
assert root_upper_square < (1+2*u)**2
assert root_lower_square > (1-2*u)**2
# Measured |fl(fl(D*I)-1)| <= 4u. Allow both arithmetic roundings explicitly.
inverse_product = (u+4*u/(1-u))/(1-u)
assert inverse_product < 6*u

# Native unit axes, component coefficients |c|<=1, two products and their sum.
axis_error = (1+6*u)*(1+u)/(1-2*u)-1
product_error = axis_error+(1+axis_error)*u+u*(1+axis_error)*(1+u)
along_error = 2*product_error+u*2*(1+product_error)
assert along_error < 25*u

# Conservative |along| <= 2; width polynomial and clamped upper endpoint.
a = 2+along_error
square_term_error = F(24,100)*a*a*((1+u)**3-1)
linear_error = F(6,100)*a*((1+u)**2-1)
constant_error = F(133,100)*u
first_sum_magnitude = F(24,100)*a*a + square_term_error + F(133,100)+constant_error
first_sum_error = square_term_error+constant_error+u*first_sum_magnitude
last_sum_error = first_sum_error+linear_error+u*(first_sum_magnitude*(1+u)+F(6,100)*a+linear_error)
width_error = (F(48,100)*a+F(6,100))*along_error+last_sum_error+u
assert width_error < 38*u

# Quintic P(t), t in [0,1]. True intermediates: |(6t-15)t| <= 9,
# 1 <= (6t-15)t+10 <= 10, and 0 <= P(t) <= 1.
p1_error = 6*u+u*(15+6*u)
p2_product_error = p1_error+u*(9+p1_error)
p2_error = p2_product_error+u*(10+p2_product_error)
cube_error = (1+u)**2-1
pre_last_error = p2_error*(1+cube_error)+10*cube_error
polynomial_error = pre_last_error+u*(1+pre_last_error)
assert polynomial_error < 62*u
assert polynomial_error+u*(1+polynomial_error) < 64*u

# Clamped affine ramps: maximizing their difference from clamp(z) reduces to
# the affine segment endpoints. C/B <= 1 and width>=.5 imply C/(B*width)<=2.
# Adaptive integer mantissas can lie just below2^23 before rounding. Use2u,
# not u, for their relative error, including the CPU floor(v*Q+.5) boundary.
encoded_relative = 2*u
assert (u+u64)/(1-u) < encoded_relative
denominator_lo = (1-2*38*u)*(1-encoded_relative)*(1-u)
denominator_hi = (1+2*38*u)*(1+encoded_relative)*(1+u)
factor_hi = (1+u)**2*(1+6*u)/denominator_lo
factor_lo = (1-u)**2*(1-6*u)/denominator_hi
t_error = max(factor_hi*(1+10*u)-1, 1-factor_lo*(1-10*u))
base_error = F(15,8)*t_error+64*u
assert base_error < 320*u

# Soft guards: radius>=1, .25<=transition<=128. Reciprocal coefficient therefore
# has relative-2u precision under adaptive positive mantissa encoding.
coefficient_rel = (1+encoded_relative)*(1+u64)-1
guard_hi = (1+u)**2*(1+coefficient_rel)
guard_lo = (1-u)**2*(1-coefficient_rel)
for q in (F(1,128), F(615)):
    ramp_error = max(guard_hi*(1+2*u+3*u*q)-1,
                     1-guard_lo*(1-2*u-3*u*q))
    guard_error = F(15,8)*ramp_error+64*u
    assert guard_error < (80+6*q)*u
# Each branch is affine in q; endpoint inequalities cover the complete interval.
# Add <=u per ordered soft-guard product; exact 0/1 hard products add no roundoff.
# Implementation uses 324 + sum(82+6*q), then CEIL via explicit float division.
# The extra base4u/per-guard1u covers interval construction and scalar f64/underflow
# reserves. Those source/primitive premises must be audited before promotion.
print('PASS conditional rational bounds: root<2u, inverse product<6u, along<25u, width<38u')
print('base/u=', float(base_error/u), '; soft guard/u < 80+6*(radius/transition)')

# Source binary64 reserve, relative to the same real-valued clamped mask used
# above. Inputs C, B, relief components and the literal cached harmonic are
# identical binary64 values, not independently rounded decimal reconstructions.
s = u64
source_axis = (1+s)/(1-s)-1
source_product = source_axis+s*(1+source_axis)
source_along = 2*source_product+s*2*(1+source_product)
sa = 2+source_along
source_square = s*sa*sa
source_inner = 2*source_square+s*(2*sa*sa+1+2*source_square)
# Include rounding of decimal .12/.06 themselves; multiplication by 2 is exact.
source_angular = (F(24,100)*(sa+2)*source_along
    + F(12,100)*(1+s)*source_inner
    + F(12,100)*s*(2*sa*sa+1)
    + s*F(12,100)*(1+s)*(2*sa*sa+1+source_inner))
source_linear = F(6,100)*source_along+F(6,100)*sa*((1+s)**2-1)
source_sum1 = F(145,100)+F(12,100)*(2*sa*sa+1)+source_angular
source_sum2 = source_sum1*(1+s)+F(6,100)*sa+source_linear
source_width = (source_angular+source_linear+s*(source_sum1+source_sum2)
    + F(133,100)*s + F(135,100)*s)
# Last two terms: reassociating the precomputed constant and clamp endpoint.
assert source_width < 100*s
source_p_lo = (1-2*source_width)*(1-s)
source_p_hi = (1+2*source_width)*(1+s)
# D_s=fl(fl(C+fl(B*w_s))-C); C/(B*w)<=2 bounds add/sub cancellation.
source_d_lo = (source_p_lo*(1-s)-2*s)*(1-s)
source_d_hi = (source_p_hi*(1+s)+2*s)*(1+s)
assert source_d_lo > F(99,100)
source_f_hi = (1+s)**2/source_d_lo
source_f_lo = (1-s)**2/source_d_hi
source_t = max(source_f_hi*(1+3*s)-1, 1-source_f_lo*(1-3*s))
source_base = F(15,8)*source_t+64*s
assert source_base < 1000*s

# Base core/outer branches equal clamping: positive B and monotone operations
# make C+B*w_s <= the qualified C+B*maximum_width_scale exterior threshold.
# A soft guard has an additional rounded (r+T) exterior threshold. If it chooses
# 1 early, the ideal clamped ramp differs by at most 2*(1+q)*s/(1+s).
for q in (F(1,128), F(615)):
    source_guard_ramp = max((1+s)**2*(1+s*(1+q))-1,
        1-(1-s)**2*(1-s*(1+q)), 2*(1+q)*s/(1+s))
    source_guard = F(15,8)*source_guard_ramp+64*s
    assert source_guard < (100+8*q)*s
    assert source_guard+s < u/F(32)  # includes one source product rounding
assert source_base < u/F(32)

# With an unrounded allowance <=4096u, at most46 soft guards can qualify.
# FTZ/DAZ events only affect tiny axis/polynomial/product terms. Coordinate,
# root and inverse checks are normal; all downstream sensitivities are bounded.
# Even 10000 operations each losing 2^-126, amplified by 2^40, fit this reserve.
underflow_reserve = F(10000)*F(1,2**126)*F(2**40)
assert underflow_reserve < u/F(32)

# Interval endpoint construction uses exact dyadic epsilon and scaling. At most
# one addition rounding of magnitude<=u is introduced per endpoint. Base4u and
# each guard's extra1u cover source-double, interval, and underflow contributions.
for guards in range(47):
    reserves = 4*u+guards*u
    # The additional u/32 dwarfs binary64 summation/division error in the <=4096
    # allowance units (explicit float arithmetic, at most46 soft guards).
    allowance_roundoff = F(4096)*((1+s)**150-1)*u
    assert allowance_roundoff < u/F(32)
    obligations = u + source_base + guards*u/F(32) + underflow_reserve + u/F(32)
    assert obligations < reserves
print('PASS conditional source/interval reserves: width<100u64, base<1000u64; '
      'soft guard+product<u/32, endpoint<=u')

# GridRound's native half-way rule is nearest-even, while the scalar uses
# floor(x+.5). This is safe ONLY because the enclosure is strict at every
# interior true weight. For x=k+.5, any l<x<h straddles the common rounding
# discontinuity, so nearest-even(l) != nearest-even(h). Otherwise an interval
# with equal endpoint codes contains no discontinuity and all nearest rules
# agree. At clipped weights0/1, codes0/4096 are exact, not half-way values.
def nearest_even(value):
    lower = value.__floor__()
    fraction = value-lower
    return lower+int(fraction > F(1, 2) or fraction == F(1, 2) and lower % 2)

ties = 0
for lower in range(4096):
    threshold = F(2*lower+1, 2)
    for margin in (F(1, 2**40), F(1, 2**24), F(1, 8)):
        assert nearest_even(threshold-margin) != nearest_even(threshold+margin)
        ties += 1
assert nearest_even(F(0)) == 0 and nearest_even(F(4096)) == 4096
print('PASS strict rounding enclosure:', ties, 'half-way straddles require scalar correction')
