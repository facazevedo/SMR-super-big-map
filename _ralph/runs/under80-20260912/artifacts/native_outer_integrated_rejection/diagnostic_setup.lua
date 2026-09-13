-- Expected-failure integration test. Private compiled function/API wrappers only.
local result={status='setup',calls={}}
rawset(_G,'SBM_OUTER_INTEGRATED_FAILURE',result)
local function fail(why)result.status='fail';result.error=result.error or tostring(why)end
local env,sbm
for _,mod in ipairs(ModsLoaded or {})do
    local value=mod.env and rawget(mod.env,'SuperBigMap')
    if value and value.Config then env,sbm=mod.env,value;break end
end
if not sbm then fail('mod missing');return end
local original=sbm.TerrainCopy.PrepareOuterResourceTerrain
local cells,names,values={},{},{}
for i=1,200 do
    local name,value=debug.getupvalue(original,i)
    if not name then break end
    cells[name]=i;values[name]=value
    if name~='_ENV' then names[#names+1]=name end
end
if type(values.Global)~='function' then fail('Global cell absent');return end
local base_global=values.Global
local terrain_api=base_global('terrain')
local active
local probe={}
function probe.owned(grid,role)
    if not active then fail('allocation outside call');return end
    if not active.owned[grid] then
        active.owned[grid]={role=role,freed=false}
        active.allocations=active.allocations+1
    end
end
function probe.freed(grid,ok)
    local record=active and active.owned[grid]
    if not record or record.freed or not ok then fail('untracked, duplicate or failed free');return end
    record.freed=true;active.freed=active.freed+1
end
function probe.corrupt(api)
    local pow,mda=api.GridPow,api.GridMulDivAdd
    api.GridPow=function(grid,m,d)
        pow(grid,m,d)
        if active and active.injected==0 and m==1 and d==2 then
            mda(grid,1000,1,0);active.injected=1
        end
    end
end
local wrapped_terrain=setmetatable({SetHeightGrid=function(...)
    if active then active.install_calls=active.install_calls+1 end
    return terrain_api.SetHeightGrid(...)
end},{__index=terrain_api})
local function wrapped_global(name)
    if name=='terrain' then return wrapped_terrain end
    return base_global(name)
end
local path='D:/PROJS/SMR/super-big-map/_ralph/runs/under80-20260912/artifacts/native_outer_integration_research/sbm_terrain_copy.lua'
local err,source=AsyncFileToString(path)
if err or type(source)~='string' then fail('draft unavailable');return end
source=source:gsub('\r\n','\n')
local first=source:find('local function PrepareOuterResourceTerrain(',1,true)
local last=first and source:find('local function RebuildOuterResourceTerrainRegions(',first,true)
if not first or not last then fail('function boundaries');return end
source=source:sub(first,last-1)
local function replace(old,new)
    local a,b=source:find(old,1,true)
    if not a or source:find(old,b+1,true) then fail('ambiguous injection '..old);return false end
    source=source:sub(1,a-1)..new..source:sub(b+1);return true
end
if not replace('if grid and not lookup[grid] then lookup[grid]=true;owned[#owned+1]=grid end',
    'if grid and not lookup[grid] then lookup[grid]=true;owned[#owned+1]=grid;failure_probe.owned(grid,"mask") end') then return end
if not replace('owned[#owned + 1] = value',
    'owned[#owned + 1] = value;failure_probe.owned(value,"patch")') then return end
if not replace('local freed,err=pcall(owned[i].free,owned[i])',
    'local freed,err=pcall(owned[i].free,owned[i]);failure_probe.freed(owned[i],freed)') then return end
if not replace('if value and type(value.free) == "function" then pcall(value.free, value) end',
    'if value and type(value.free) == "function" then local freed=pcall(value.free,value);failure_probe.freed(value,freed) end') then return end
if not replace('local grid = raw and grid_to_compute(raw) or nil',
    'local grid = raw and grid_to_compute(raw) or nil\n if grid and grid~=raw then failure_probe.owned(grid,"working") end') then return end
if not replace('\t\t\t\tgrid = working\n',
    '\t\t\t\tgrid = working;failure_probe.owned(grid,"working")\n') then return end
if not replace('if grid and grid ~= raw and type(grid.free) == "function" then pcall(grid.free, grid) end',
    'if grid and grid ~= raw and type(grid.free) == "function" then local freed=pcall(grid.free,grid);failure_probe.freed(grid,freed) end') then return end
if not replace('\tlocal box_fn = Global("box")\n',
    '\tfailure_probe.corrupt(mask_api)\n\tlocal box_fn = Global("box")\n') then return end
local prefix='local failure_probe=...\n'
if #names>0 then prefix=prefix..'local '..table.concat(names,',')..'\n' end
local chunk,why=load(prefix..source..'\nreturn PrepareOuterResourceTerrain','@integrated-mask-expected-failure','t',env)
if not chunk then fail(why);return end
local candidate=chunk(probe)
for i=1,200 do
    local name=debug.getupvalue(candidate,i)
    if not name then break end
    if name=='Global' then debug.setupvalue(candidate,i,wrapped_global)
    elseif cells[name] then debug.upvaluejoin(candidate,i,original,cells[name])
    elseif name~='failure_probe' then fail('unjoined '..name);return end
end
local function hash_height(map)
    local grid=terrain_api.GetHeightGrid(map)
    local blob,why=GridWriteStr(grid)
    if type(blob)~='string' or why then fail('height serialization');return nil end
    local w,h=grid:size()
    return {hash=tostring(xxhash(blob)),bytes=#blob,width=w,height=h}
end
sbm.TerrainCopy.PrepareOuterResourceTerrain=function(map,...)
    if active then fail('recursive failure test');return false,{error='recursive failure test'} end
    local before=hash_height(map)
    active={owned={},allocations=0,freed=0,install_calls=0,injected=0}
    local context=active
    local before_failures=#((sbm.State or {}).optimization_failures or {})
    local returned=table.pack(candidate(map,...))
    local after=hash_height(map)
    local after_failures=#((sbm.State or {}).optimization_failures or {})
    local all_freed=true
    for _,record in pairs(context.owned)do if not record.freed then all_freed=false end end
    active=nil
    local report=returned[2]
    local entry={before=before,after=after,report=report,allocations=context.allocations,
        freed=context.freed,all_freed=all_freed,install_calls=context.install_calls,
        injected=context.injected,new_failures=after_failures-before_failures}
    result.calls[#result.calls+1]=entry
    if not before or not after or before.hash~=after.hash or before.bytes~=after.bytes
        or before.width~=after.width or before.height~=after.height or not all_freed
        or context.allocations==0 or context.freed~=context.allocations or context.install_calls~=0
        or context.injected~=1 or after_failures~=before_failures+1 or returned[1]~=false
        or type(report)~='table' or type(report.error)~='string'
        or not report.error:find('native outer root residual',1,true) then fail('transaction failure contract') end
    if not result.error then result.status='pass' end
    return table.unpack(returned,1,returned.n)
end
result.status='ready'
return 'OUTER_INTEGRATED_EXPECTED_FAILURE_READY'
