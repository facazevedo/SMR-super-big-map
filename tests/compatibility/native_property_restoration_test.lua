local f=assert(io.open('Code/sbm_deposits.lua'));local source=f:read('*a');f:close()
local block=assert(source:match('(local function RestoreNativeMarkerProperties.-)\nlocal function NativeRecordBaseGeometry'))
local portable=assert(source:match('local function NativePropertyIsPortable.-\nend\n'))
local function equal(a,b)
 if type(a)~='table' or type(b)~='table'then return a==b end
 for k,v in pairs(a)do if not equal(v,b[k])then return false end end
 for k in pairs(b)do if a[k]==nil then return false end end
 return true
end
local function clone(_,v)
 if type(v)~='table'then return v end
 local copy={};for k,x in pairs(v)do copy[k]=clone(nil,x)end;return copy
end
local env=setmetatable({NativePropertyValuesEqual=equal,CloneNativePropertyValue=clone},{__index=_G})
local restore,is_portable=assert(load(block..portable..'\nreturn RestoreNativeMarkerProperties,NativePropertyIsPortable','production native properties','t',env))()
assert(not is_portable({id='Pos',editor='point'}))
assert(not is_portable({id='readonly',read_only=true}))
assert(not is_portable({id='owner',editor='object'}))
for _,fault in ipairs({'none','getter','setter','ignored','mutating'})do
 -- The native 33-mod failure reset DetailClass on all 383 recreated markers.
 local captured={resource='Metals',DetailClass='Essential',enabled=false,config={value=17}}
 local engine={resource='Metals',DetailClass='From Entity',enabled=true,config={value=3}}
 local calls=0;local position={1,2,3}
 local marker={class='SubsurfaceDepositMarker',pos=position,
  GetProperty=function(_,id)if fault=='getter'then error('injected getter')end;return engine[id]end,
  SetProperty=function(_,id,v)
   calls=calls+1
   if fault=='setter'then error('injected setter')end
   if fault=='ignored'then return end
   if fault=='mutating' and type(v)=='table'then v.value=999 end
   engine[id]=v
  end}
 local ok,count=restore(marker,captured)
 assert(ok==(fault=='none'),'wrong property restoration outcome: '..fault)
 assert(marker.pos==position and captured.config.value==17,'restoration mutated immutable capture or geometry')
 if ok then
  assert(equal(engine,captured) and count==3 and calls==3)
  local again,n=restore(marker,captured);assert(again and n==0 and calls==3,'correct fields rewritten')
 end
end
print('native property restoration: native setters, immutable capture, idempotence, unchanged geometry and failed/ignored setter rejection passed')
