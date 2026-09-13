-- PRIVATE integration verification. Load one generated function, not a module.
-- This removes the shadow's duplicate scalar raster but preserves full rules checks.
local result={status='setup',calls={}}
rawset(_G,'SBM_OUTER_INTEGRATED_DIAGNOSTIC',result)
local function fail(why)result.status='fail';result.error=result.error or tostring(why)end
local env,sbm
for _,mod in ipairs(ModsLoaded or {})do
    local value=mod.env and rawget(mod.env,'SuperBigMap')
    if value and value.Config then env,sbm=mod.env,value;break end
end
if not sbm then fail('mod missing');return end
local original=sbm.TerrainCopy.PrepareOuterResourceTerrain
local cells,names={},{}
for i=1,200 do
    local name=debug.getupvalue(original,i)
    if not name then break end
    cells[name]=i;if name~='_ENV' then names[#names+1]=name end
end
local path='D:/PROJS/SMR/super-big-map/_ralph/runs/under80-20260912/artifacts/native_outer_integration_research/sbm_terrain_copy.lua'
local err,source=AsyncFileToString(path)
if err or type(source)~='string' then fail('draft source missing');return end
source=source:gsub('\r\n','\n')
local first=source:find('local function PrepareOuterResourceTerrain(',1,true)
local last=first and source:find('local function RebuildOuterResourceTerrainRegions(',first,true)
if not first or not last then fail('function boundaries');return end
source=source:sub(first,last-1)
local anchor='                if native_coarse then\n'
local a,b=source:find(anchor,1,true)
if not a or source:find(anchor,b+1,true) then fail('path census anchor');return end
source=source:sub(1,a-1)..'                probe_mask_path(native_coarse, mask_stats, mask_error)\n'..source:sub(a)
local active
local function probe(grid,stats,problem)
    if not active then fail('mask outside active call');return end
    active.masks[#active.masks+1]={native=grid~=nil,stats=stats,reason=problem}
    if not grid and stats.domain_qualified then fail(problem or 'qualified mask failure') end
end
local prefix='local probe_mask_path=...\n'
if #names>0 then prefix=prefix..'local '..table.concat(names,',')..'\n' end
local chunk,why=load(prefix..source..'\nreturn PrepareOuterResourceTerrain','@private-native-mask-integration','t',env)
if not chunk then fail(why);return end
local candidate=chunk(probe)
for i=1,200 do
    local name=debug.getupvalue(candidate,i)
    if not name then break end
    if cells[name] then debug.upvaluejoin(candidate,i,original,cells[name])
    elseif name~='probe_mask_path' then fail('unjoined cell '..name);return end
end
sbm.TerrainCopy.PrepareOuterResourceTerrain=function(map,...)
    if active then fail('recursive integration');return original(map,...) end
    active={masks={},environment=map.mapdata.Environment}
    local row=active
    local values=table.pack(candidate(map,...))
    active=nil;row.report=values[2];result.calls[#result.calls+1]=row
    local count,native_count=0,0
    for _,entry in ipairs(row.masks)do
        count=count+entry.stats.samples
        if entry.native then native_count=native_count+1 end
    end
    row.native_patches=native_count
    if type(row.report)~='table' or row.report.error~='' or #row.masks==0
        or count~=row.report.native_mask_samples or native_count==0 then fail('integrated census/report') end
    if not result.error then result.status='pass' end
    return table.unpack(values,1,values.n)
end
result.status='ready'
return 'OUTER_NATIVE_INTEGRATION_READY'
