-- Compare the complete engine helper module, including failures and live engine
-- rebinding. Only Lua's type/pcall primitives are snapshotted at module load.
local function read(path)
    local f=assert(io.open(path,'r'));local value=f:read('*a'):gsub('\r\n','\n');f:close();return value
end
local source=read('Code/sbm_engine.lua')
local declaration='local type, pcall = type, pcall\n'
local current=source
-- The separately tested FirstKindOf helper adds module-load qualification only.
-- Strip that exact block for the inherited-method source invariant, but execute
-- the complete module below; class_batch_test covers qualification and fallbacks.
local helper_first=assert(source:find('-- Native list negatives',1,true))
local helper_last=assert(source:find('-- Best-effort world position',helper_first,true))
local inherited=source:sub(1,helper_first-1)..source:sub(helper_last)
assert(source:find(declaration,1,true),'primitive binding missing')
local p=assert(io.popen('git show b5fb059:Code/sbm_engine.lua','r'))
local previous=p:read('*a'):gsub('\r\n','\n');assert(p:close())
local first,last=assert(inherited:find(declaration,1,true))
assert(inherited:sub(1,first-1)..inherited:sub(last+1)==previous,'unexpected inherited engine helper change')
local function compile(text)
    local reads,trace={},{}
    local function record(...) trace[#trace+1]=table.pack(...) end
    local env={SuperBigMap={}}
    env._G=env
    local primitives={
        type=function(value) record('type',type(value));return type(value) end,
        pcall=function(fn,...) record('pcall',select('#',...));return pcall(fn,...) end,
    }
    setmetatable(env,{__index=function(_,key)
        reads[key]=(reads[key] or 0)+1
        return primitives[key] or _G[key]
    end})
    assert(load(text,'@engine-primitives-oracle','t',env))()
    return env.SuperBigMap.Engine,env,reads,trace
end
local old,a,old_reads,old_trace=compile(previous)
local new,b,new_reads,new_trace=compile(current)
-- New helper metadata probes are intentional initialization, not hot-method
-- calls. Keep all runtime traces and primitive global-lookup counts intact.
for i=#old_trace,1,-1 do old_trace[i]=nil end
for i=#new_trace,1,-1 do new_trace[i]=nil end
local checks=0
local function check(ok,why) assert(ok,why);checks=checks+1 end
local function same(x,y)
    check(type(x)==type(y),'type differs')
    if type(x)=='table' then
        for key,value in pairs(x) do same(value,y[key]) end
        for key in pairs(y) do check(x[key]~=nil,'extra key') end
    else check(x==y,'value differs') end
end
local function compare(name,...)
    same(table.pack(old[name](...)),table.pack(new[name](...)))
end
local function install(name,value) a[name]=value;b[name]=value end
local callbacks={function(...) return ... end,function() return nil,2,false,4 end,
    function() error('fixture failure',0) end,function() return false end,
    function() return true end}
for round=1,100 do
    for _,fn in ipairs(callbacks) do
        compare('SafeCall',fn,1,nil,3,false)
        compare('TryCall',fn,1,nil,3,false)
    end
    compare('SafeCall',false);compare('TryCall',{})
    install('IsKindOf',function(_,class) return class=='Match' end)
    compare('IsKindOf',{},'Match');compare('IsKindOf',{},'Other')
    install('IsKindOf',function() return 1 end);compare('IsKindOf',{},'Match')
    install('IsKindOf',callbacks[3]);compare('IsKindOf',{},'Match')
    install('IsKindOf',nil)
    compare('IsKindOf',{IsKindOf=function(_,class) return class=='Match' end},'Match')
    compare('IsKindOf',{IsKindOf=callbacks[3]},'Match')
    compare('IsKindOf',{},'Match');compare('IsKindOf',nil,'Match')
    compare('IsLiveMap',{mapdata={},IsValid=callbacks[5]})
    compare('IsLiveMap',{mapdata={},IsValid=callbacks[4]})
    compare('IsLiveMap',{mapdata={},IsValid=callbacks[3]})
    compare('TerrainSize',{mapdata={},Width=12,Height=15})
    install('terrain',{GetMapSize=function() return 30,40 end})
    compare('TerrainSize',{mapdata={}})
    install('terrain',nil)
    compare('TerrainSize',{mapdata={},GetMapSize=function() return 50,60 end})
    compare('TerrainSize',{mapdata={},GetMapSize=callbacks[3]})
    compare('ObjectPos',{GetPos=function() return 'pos' end})
    compare('ObjectPos',{GetPos=callbacks[3],GetVisualPos=function() return 'visual' end})
    install('point',function(x,y,z) return {x,y,z} end)
    compare('ObjectPos',{GetPos=callbacks[3],GetVisualPosXYZ=function() return 2,3,nil end})
    install('point',nil);compare('ObjectPos',{})
    install('const',{HeightTileSize=100})
    compare('MapWorldSize',{mapdata={Width=13,Height=17}})
    install('const',nil);compare('MapWorldSize',{mapdata={Width=13,Height=17}})
    install('AsyncRand',function(n) return n-1 end);compare('RandInt',10)
    install('AsyncRand',callbacks[3]);compare('RandInt',10)
    install('AsyncRand',function(n) return n end);compare('RandInt',10)
    install('AsyncRand',nil);compare('RandInt',10);compare('RandInt',0)
    install('Clamp',function() return round end);compare('ClampNumber',3,1,5)
    install('Clamp',nil);compare('ClampNumber',3,1,5)
    local class={test=round};install('FixtureClass',class)
    compare('ClassTable','FixtureClass');compare('Global','FixtureClass')
    install('FixtureClass',nil);install('g_Classes',{FixtureClass=class})
    compare('ClassTable','FixtureClass')
end
same(old_trace,new_trace)
check(new_reads.type==2 and new_reads.pcall==1,'primitive lookup is not module-scoped')
check(old_reads.type>1000 and old_reads.pcall>1000,'fixture did not exercise hot helpers')
print('engine primitives: '..checks..' exact result/call-trace checks; type/pcall lookups '
    ..old_reads.type..'/'..old_reads.pcall..' -> '..new_reads.type..'/'..new_reads.pcall)
