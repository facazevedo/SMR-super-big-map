local f=assert(io.open('Code/sbm_lifecycle.lua','r'))
local source=f:read('*a');f:close()
local register=assert(source:match('(local function RegisterOnce%(message_name, handler%).-\nend)\n'))
local handlers={}
local epoch=function() end
local proxy={} -- sandbox proxy survives a full engine Lua reload
local sbm={State={}}
local env=setmetatable({SuperBigMap=sbm,Global=function(name)
  if name=='GetStaticMsgNames' then return epoch end
  if name=='OnMsg' then return proxy end
end,Engine={ChainOnMsg=function(name,handler)
  handlers[name]=handlers[name] or {};table.insert(handlers[name],handler)
end}},{__index=_G})
local function reload_module()
  return assert(load(register..'\nreturn RegisterOnce','production registration','t',env))()
end
local calls=0
local add=reload_module()
add('CurrentMapChangeDone',function() calls=calls+1 end)
assert(#handlers.CurrentMapChangeDone==1)
add=reload_module()
add('CurrentMapChangeDone',function() calls=calls+10 end)
assert(#handlers.CurrentMapChangeDone==1)
handlers.CurrentMapChangeDone[1]()
assert(calls==10,'existing wrapper did not delegate to the live body')
-- Full reload: native registry replaced; mod State and sandbox proxy retained.
handlers={};epoch=function() end
add=reload_module()
add('CurrentMapChangeDone',function() calls=calls+100 end)
add('LoadGame',function() calls=calls+1000 end)
assert(#handlers.CurrentMapChangeDone==1 and #handlers.LoadGame==1)
handlers.CurrentMapChangeDone[1]();handlers.LoadGame[1]()
assert(calls==1110)
add('LoadGame',function() calls=calls+10000 end)
assert(#handlers.LoadGame==1)
handlers.LoadGame[1]()
assert(calls==11110)
print('PASS: lifecycle re-registers after native registry replacement without stacking on module-only reload')
