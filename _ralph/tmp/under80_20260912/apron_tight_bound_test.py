"""Conditional rational proof for a tighter unchanged-Q22 apron certificate.

No measured error is used as an accuracy guarantee. Premises are the accepted
coordinate/domain, root/reciprocal residual, lobe, regular-f32 and scalar-f64
contracts. Native validation and exact full-raster shadowing remain mandatory.
"""
from fractions import Fraction as F
u,u64=F(1,2**24),F(1,2**53)
coord=F(1,2**21)
norm_error=F(3,2)*coord
low=(F(17,100)-norm_error)*(1-u)
high=(F(6,5)+norm_error)*(1+u)
A,B=F(1,2**20)+4*u,2*u
assert A+B/low**2 < 1-F(99,100)**2
native_root_error=max((A*z+B/z)/F(199,100) for z in (low,high))
radial=norm_error+u*(F(6,5)+norm_error)+native_root_error
delta=F(16,10**7)
assert radial<delta
rho=(16*u+u)/(1-u)
eta=(1+rho)*(1+u)-1
axis_constant=(F(17,100)+coord)/(F(17,100)-delta)*eta
assert axis_constant<F(11,10**7)
# c/(.85*c-delta) decreases for c>0; use c=.20.
c=F(1,5)
axis_coefficient=c*(coord+delta)/(F(85,100)*c-delta)
assert axis_coefficient<F(25,10**7)
inverse_error=(F(6,5)+delta)/F(9,10)*eta
assert inverse_error<F(15,10**7)
# Inherit .47 direction derivative and1e-6 boundary arithmetic/second-order
# reserve: new direction errors are strictly inside the accepted old domain.
normal_constant=delta/F(9,10)+F(6,5)/F(9,10)**2*(F(47,100)*F(11,10**7)+F(1,10**6))+F(15,10**7)
normal_coefficient=F(6,5)/F(9,10)**2*F(47,100)*F(25,10**7)
assert normal_constant<F(56,10**7)
assert normal_coefficient<F(18,10**7)

# Quantized C=floor(c*2^24+.5), cq=C/2^24. Scaling is dyadic;
# reserve2u64 for the CPU half-integer addition. Denominator1-cq>=.25-q.
# Difference of clamped affine ramps is bounded at their segment endpoints.
q=u/2+2*u64
core_error=q/(F(1,4)-q)
# One subtraction and up to two divide/reciprocal-product roundings; multiplying
# by2^24, multiplying by1 and adding0 are exact. Clamping is nonexpansive.
affine_error=(1+u)**3-1
argument_error=core_error+affine_error
assert argument_error<6*u

# Unchanged quintic arithmetic. Exact intermediates on t in[0,1]:
# |(6t-15)t|<=9, 1<=((6t-15)t+10)<=10, 0<=P(t)<=1.
p1_error=6*u+u*(15+6*u)
p2_product_error=p1_error+u*(9+p1_error)
p2_error=p2_product_error+u*(10+p2_product_error)
cube_error=(1+u)**2-1
pre_last_error=p2_error*(1+cube_error)+10*cube_error
polynomial_error=pre_last_error+u*(1+pre_last_error)
complement_error=polynomial_error+u*(1+polynomial_error)
# Also check, rather than merely assign, the generous scalar-f64 reserve.
# The two positive subtractions are monotone, so the scalar ratio remains[0,1].
scalar_argument=(1+u64)**2/(1-u64)-1
sp1=6*u64+u64*(15+6*u64)
sp2_product=sp1+u64*(9+sp1)
sp2=sp2_product+u64*(10+sp2_product)
scube=(1+u64)**2-1
spre=sp2*(1+scube)+10*scube
spoly=spre+u64*(1+spre)
scomplement=spoly+u64*(1+spoly)
assert F(15,8)*scalar_argument+scomplement<512*u64
# U24 integer rounding adds at most.5u.512u64 encloses the literal scalar
# quintic arithmetic; tiny underflow/FTZ terms are dominated by another u64.
remainder=F(15,8)*argument_error+complement_error+u/2+513*u64
assert remainder<76*u

def weight_error(c):
    return F(15,8)*(F(56,10**7)+F(18,10**7)/c)/(1-c)+76*u
# (5.6+1.8/c)/(1-c)=1.8/c+7.4/(1-c) is convex on(0,1).
# Include the actual binary64 branch endpoints as well as exact decimals.
for c in (F(1,5),F.from_float(.2),F(3,5),F.from_float(.6)):
    assert weight_error(c)<F(3,65536)
for c in (F(3,5),F.from_float(.6),F(3,4)):
    assert weight_error(c)<F(5,65536)
assert 3*256==768 and 5*256==1280
print('PASS conditional unchanged-operation bounds: radial',float(radial),
      'axis',float(axis_constant),'+',float(axis_coefficient),'/c')
print('normalized',float(normal_constant),'+',float(normal_coefficient),
      '/c; polynomial/core/rounding remainder',float(remainder/u),'u <76u')
print('weight endpoint maxima',float(max(weight_error(F(1,5)),weight_error(F(3,5)))),
      float(weight_error(F(3,4))),'fit3/65536 and5/65536')
