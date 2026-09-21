SuperBigMap={Engine={Global=function()end},DecorationGeometry={}}
dofile('Code/sbm_decoration_validation.lua')
local V=SuperBigMap.DecorationValidation
local expected={origin={0,0,0},columns={{1,0,0},{0,1,0},{0,0,1}}}
local actual={origin={0.14,0,0},columns={{1,0,0},{0,1,0},{0,0,1}}}
assert(V.AffineBoundsAgree({-10,-10,-10,10,10,10},expected,actual,2),'native sub-world-unit matrix rounding is bounded')
actual.origin[1]=2.001
assert(not V.AffineBoundsAgree({-10,-10,-10,10,10,10},expected,actual,2),'real displacement outside existing contact tolerance fails')
actual.origin[1]=0;actual.columns[1][1]=1.00001
assert(not V.AffineBoundsAgree({0,0,0,1000000,1,1},expected,actual,2),'small coefficient error at a long bone lever arm cannot pass')
assert(not V.AffineBoundsAgree(nil,expected,actual,2),'missing bounds do not pass')
actual.columns[1][1]=0/0
assert(not V.AffineBoundsAgree({0,0,0,1,1,1},expected,actual,2),'non-finite matrices fail')
print('frame precision: full affine bound, fixed world-unit tolerance, long lever arms, missing/non-finite data')
