local file=assert(io.open('Code/sbm_decoration_validation.lua','r'))
local source=file:read('*a');file:close()
local first=assert(source:find('local function refined(rect)',1,true))
local last=assert(source:find('separated=Geometry.TrianglesAboveTerrain(triangles,refined,error_bound)',first,true))
local environment={math=math,type=type,width=100,height=100,error_bound=3,height_at=function()end}
local coarse,exact,calls
environment.upper=function()return coarse end
environment.integer_upper=function(rect,padding,budget)
 calls=calls+1;assert(padding==2 and budget==1024)
 return exact
end
local refined=assert(load(source:sub(first,last-1)..'return refined','production refinement','t',environment))()
calls=0;coarse=10;exact=9
assert(refined({0,0,14,1,1,20})==10 and calls==0,'already proven triangle did redundant exhaustive work')
assert(refined({0,0,13,1,1,20})==9 and calls==1,'strict boundary was incorrectly skipped')
exact=nil
assert(refined({0,0,12,1,1,20})==10 and calls==2,'exhausted refinement lost conservative fallback')
for _,bad in ipairs({false,0/0,math.huge,-math.huge}) do
 coarse=bad;exact=8;calls=0
 assert(refined({0,0,20,1,1,25})==8 and calls==1,'invalid coarse bound bypassed exact proof')
end
print('terrain refinement: strict complete-bound shortcut, unchanged fallback and invalid-bound safety')
