"""Exact rational subdomain proof; no native accuracy assumption added."""
from fractions import Fraction as F

def envelope(c):
    return F(15,8)*(F(12,10**6)+F(7,10**6)/c)/(1-c)+F(16,10**6)

# (12+7/c)/(1-c) = 7/c + 19/(1-c). Each reciprocal is convex;
# their positive sum is convex throughout (0,1). Endpoints bound each interval.
for c in (F(1,4),F(11,20),F.from_float(0.55)):
    assert (12+7/c)/(1-c)==7/c+19/(1-c)
    assert envelope(c)<F(1,8192)
    print('narrow core',str(c),'error',float(envelope(c)))
for c in (F(1,5),F(3,4)):
    assert envelope(c)<F(1,4096)
assert F(16777216,8192)==2048
assert F(16777216,4096)==4096
print('PASS: same proved envelope, narrower closed subdomain, exact integer API constants')
