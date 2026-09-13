-- Test actual integrated production block, not a separately retyped helper.
local f=assert(io.open('Code/sbm_decor_topup.lua','rb'))
local source=f:read('*a'):gsub('\r\n','\n');f:close()
local block=assert(source:match('%-%- DECOR_POSITIVE_CELL_BEGIN\n(.-)\n%-%- DECOR_POSITIVE_CELL_END'))
local query=assert(load(block..'\nreturn circle_hits'))()
return function(_)return query end
