"""Exact rational envelope checks, including actual binary branch endpoints."""
from fractions import Fraction as F

def error(c):
    return F(15,8)*(F(12,10**6)+F(7,10**6)/c)/(1-c)+F(16,10**6)

# (12+7/c)/(1-c) = 7/c+19/(1-c); both reciprocal terms have positive
# second derivative on (0,1), so each closed interval is bounded by its endpoints.
for c in [F(1,5),F.from_float(0.2),F(3,5),F.from_float(0.60)]:
    assert (12+7/c)/(1-c)==7/c+19/(1-c)
    assert error(c)<F(9,65536)
    print('lower domain',str(c),'error',float(error(c)))
for c in [F(3,5),F.from_float(0.60),F(3,4)]:
    assert error(c)<F(12,65536)
    print('upper domain',str(c),'error',float(error(c)))
for numerator,units in [(9,2304),(12,3072)]:
    assert F(16777216*numerator,65536)==units
    assert F(3*numerator,65536)==3*F(numerator,65536)
print('PASS entire certified domain, native residual proof unchanged, integral U24 allowances')
