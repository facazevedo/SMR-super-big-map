-- Rechecks may yield. A new cave-in event must not disappear while one is active,
-- and a synchronous diagnostic caller must not race that shared per-map context.
local tasks={};local map={slot=2,mapdata={},SuperBigMapUndergroundPrepared=true}
local globals={Maps={[2]=map},point=function()end,IsValid=function()return true end,
 GetPreciseTicks=function()return 0 end,print=function()end,
 CurrentThread=function()return coroutine.running()end,CanYield=coroutine.isyieldable,
 Sleep=function()coroutine.yield()end,CreateRealTimeThread=function(f)
  local co=coroutine.create(f);tasks[#tasks+1]=co;return co
 end}
SuperBigMap={Config={},DecorationGeometry={},Engine={Global=function(k)return globals[k]end,
 MapDataEnvironment=function()return 'Underground'end}}
dofile('Code/sbm_decoration_validation.lua')
local V=SuperBigMap.DecorationValidation
local reasons={}
V.Recheck=function(_,reason)
 reasons[#reasons+1]=reason
 if #reasons==1 then V.Schedule(map,'new cave-in settled')end
 return {}
end
V.Schedule(map,'map switch')
for step=1,20 do
 local live=false
 for _,co in ipairs(tasks)do if coroutine.status(co)~='dead' then
  live=true;local ok,why=coroutine.resume(co);assert(ok,why)
 end end
 if not live then break end
end
assert(#reasons==2 and reasons[2]=='new cave-in settled','event during active validation was dropped')
local busy,overlap,entered=false,0,0
V.Recheck=function()
 if busy then overlap=overlap+1 end;busy=true;entered=entered+1
 coroutine.yield();busy=false;return {}
end
local a=coroutine.create(function()assert(V.Run('Recheck',map,'one'))end)
local b=coroutine.create(function()assert(V.Run('Recheck',map,'two'))end)
assert(coroutine.resume(a));assert(coroutine.resume(b));assert(coroutine.resume(a))
for i=1,4 do if coroutine.status(b)~='dead' then assert(coroutine.resume(b))end end
assert(entered==2 and overlap==0,'concurrent rechecks raced the same context')
assert(coroutine.status(a)=='dead' and coroutine.status(b)=='dead')
print('decoration lifecycle: queued cave-in events and serialized map rechecks passed')
