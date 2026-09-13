-- Compile/injection-anchor checks only; actual native transaction tests are separate.
local function Global(name)
    if name=='terrain' then return {} end
end
local function original()return Global('terrain'),type(nil)end
function AsyncFileToString(path)
    local f,why=io.open(path,'r')
    if not f then return why end
    local text=f:read('*a');f:close();return nil,text
end
for _,test in ipairs({
    {'native_outer_integrated_setup.lua','SBM_OUTER_INTEGRATED_DIAGNOSTIC'},
    {'native_outer_integrated_failure_setup.lua','SBM_OUTER_INTEGRATED_FAILURE'},
})do
    local sbm={Config={},TerrainCopy={PrepareOuterResourceTerrain=original}}
    local env=setmetatable({SuperBigMap=sbm},{__index=_G})
    ModsLoaded={{env=env}}
    dofile('_ralph/tmp/under80_20260912/'..test[1])
    local state=rawget(_G,test[2])
    assert(state and state.status=='ready',state and state.error or 'no state')
    assert(sbm.TerrainCopy.PrepareOuterResourceTerrain~=original,'wrapper not installed')
    print('PASS compile/anchors: '..test[1])
end
