-- Preserve EVERY original case, comparator, output/reduction/census assertion.
-- Extend only coefficient instrumentation for the new shared local error field.
local f=assert(io.open('_ralph/tools/parity/precision_coordinate_test.lua','rb'))
local source=f:read('*a'):gsub('\r\n','\n');f:close()
local function once(old,new)
 local i=assert(source:find(old,1,true),'legacy anchor missing')
 assert(not source:find(old,i+#old,true),'legacy anchor duplicated')
 source=source:sub(1,i-1)..new..source:sub(i+#old)
end
once('local calls={upper=0,sensitivity=0}', 'local calls={upper=0,sensitivity=0};local local_field')
once('  instrumented.GridMulDivAdd=function(g,mul,div,add)', [[  instrumented.GridAddMulDiv=function(g,field,mul,div)
   if mul==1 and div==3 then
    assert(not local_field,'duplicate local upper field')
    assert(core>=.2 and core<=.75,'local field outside qualified core')
    local_field=field
    local w,h=field:size()
    for y=0,h-1 do for x=0,w-1 do
     local value=field:get(x,y)
     assert(value>=240 and value<=3618,'local field escaped proved domain')
    end end
    calls.upper=calls.upper+1
   end
   return api.GridAddMulDiv(g,field,mul,div)
  end
  instrumented.GridMulDivAdd=function(g,mul,div,add)
   if local_field and mul==local_field then
    assert(div==16777216 and add==0,'local cubic field coefficient mismatch')
    calls.sensitivity=calls.sensitivity+1
   end]])
assert(load(source,'@precision-coordinate-local-field-contract'))()
print('PASS every legacy assertion/case retained; same local field used for both error terms, scalar coefficients unchanged')
