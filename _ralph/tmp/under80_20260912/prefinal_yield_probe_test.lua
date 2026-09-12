-- Validate observation/control flow, not native scheduler equivalence.
local file=assert(io.open('_ralph/tmp/under80_20260912/prefinal_yield_probe.lua','r'))
local source=file:read('*a');file:close()
local calls,sleeps={},0
local surface={mapdata={Environment='Surface'},SuspendPassEditsReasons={}}
local underground={mapdata={Environment='Underground'}}
local aggregate='initial'
local original=function(map,stage)
    calls[#calls+1]={map=map,stage=stage}
    aggregate='rebuilt'
    return true
end
local sbm={GenerationGrids={RebuildFinal=original}}
local env={ModsLoaded={{env={SuperBigMap=sbm}}},
    Sleep=function(ms)assert(ms==1);sleeps=sleeps+1;aggregate='yielded'end,
    RealTime=function()return sleeps end,GameTime=function()return 0 end,
    GridWriteStr=function(grid)return grid end,xxhash=function(blob)return blob end,
    terrain={HashPassability=function()return aggregate end,
        GetPassGridsCount=function()return 2 end,
        GetPassGrid=function(_,index)return 'unchanged:'..index end}}
env._G=env;setmetatable(env,{__index=_G})
assert(load(source,'@prefinal-probe-fixture','t',env))()
assert(env.SBM_PREFINAL_YIELD_DIAGNOSTIC.status=='armed')
assert(sbm.GenerationGrids.RebuildFinal(underground,'other')==true)
assert(sleeps==0 and #calls==1)
assert(sbm.GenerationGrids.RebuildFinal(surface,'after last object-grid transaction')==true,
    'probe must preserve the production return value')
assert(sleeps==1 and #calls==2)
assert(sbm.GenerationGrids.RebuildFinal(surface,'post-pipeline scheduled revalidation')==true,
    'scheduled probe must preserve the production return value')
assert(sleeps==1 and #calls==3)
assert(sbm.GenerationGrids.RebuildFinal==original,'wrapper not restored')
local result=env.SBM_PREFINAL_YIELD_DIAGNOSTIC
assert(result.status=='pass' and #result.calls==5 and #result.comparisons==5)
for _,comparison in ipairs(result.comparisons) do assert(comparison.exact_exposed_grids) end
assert(result.comparisons[1].aggregate_equal==false,'yield difference hidden')
assert(result.comparisons[2].aggregate_equal==false,'immediate difference hidden')
assert(result.comparisons[5].aggregate_equal==true,'stable final comparison failed')
print('PASS: every rebuild retained, one yield, exact comparisons, returns and wrapper restored')
