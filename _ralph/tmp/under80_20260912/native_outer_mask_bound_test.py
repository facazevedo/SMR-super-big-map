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
denominator_lo = (1-2*38*u)*(1-u)**2
denominator_hi = (1+2*38*u)*(1+u)**2
factor_hi = (1+u)**2*(1+6*u)/denominator_lo
factor_lo = (1-u)**2*(1-6*u)/denominator_hi
t_error = max(factor_hi*(1+8*u)-1, 1-factor_lo*(1-8*u))
base_error = F(15,8)*t_error+64*u
assert base_error < 320*u

# Soft guards: radius>=1, .25<=transition<=128. Reciprocal coefficient therefore
# has full relative-u precision under adaptive positive mantissa encoding.
coefficient_rel = (1+u)*(1+u64)-1
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
