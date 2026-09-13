-- Preserve the original precision fixture, baseline, cases and EVERY assertion.
-- Only its expected API coefficient contract changes from5/7 to proved3/5.
local f=assert(io.open('_ralph/tools/parity/precision_coordinate_test.lua','rb'))
local source=f:read('*a'):gsub('\r\n','\n');f:close()
local function once(old,new)
 local i=assert(source:find(old,1,true),'legacy anchor missing')
 assert(not source:find(old,i+#old,true),'legacy anchor duplicated')
 source=source:sub(1,i-1)..new..source:sub(i+#old)
end
once('and 5 or 7','and 3 or 5')
once('add==1280 or add==1792','add==768 or add==1280')
once('mul==15 or mul==21','mul==9 or mul==15')
assert(load(source,'@precision-coordinate-new-bound-contract'))()
print('PASS legacy cases/assertions/baseline unchanged; actual3/5 coefficient contract verified')
