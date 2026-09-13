-- Private full-map shadow: compare every U12 cell before using any candidate mask.
local native_first = true
local result={status='setup',calls={},native_first=native_first}
rawset(_G,'SBM_OUTER_MASK_SHADOW',result)
local function fail(why) result.status='fail';result.error=result.error or tostring(why) end
local root='D:/PROJS/SMR/super-big-map/'
local function read(path)
    local err,value=AsyncFileToString(root..path)
    if err or type(value)~='string' then fail('read '..path);return nil end
    return value:gsub('\r\n','\n')
end
local env,sbm
for _,mod in ipairs(ModsLoaded or {})do
    local value=mod.env and rawget(mod.env,'SuperBigMap')
    if value and value.Config then env,sbm=mod.env,value;break end
end
if not sbm then fail('mod absent');return end
local kernel_source=read('_ralph/tmp/under80_20260912/native_outer_mask.lua')
if not kernel_source then return end
local chunk,why=load(kernel_source,'@private-native-mask','t',_G)
if not chunk then fail(why);return end
local kernel=chunk()
local api={}
for _,name in ipairs({'NewComputeGrid','GridMulDivAdd','GridAdd','GridAddMulDiv',
    'GridPow','GridAbs','GridMask','GridClamp','GridRound','GridCount','GridForeach','point','box'})do
    api[name]=rawget(_G,name)
    if type(api[name])~='function' then fail('missing '..name);return end
end
local original=sbm.TerrainCopy.PrepareOuterResourceTerrain
local cells,names={},{}
for i=1,200 do
    local name=debug.getupvalue(original,i)
    if not name then break end
    cells[name]=i;if name~='_ENV' then names[#names+1]=name end
end
local source=read('Code/sbm_terrain_copy.lua')
if not source then return end
local first=source:find('local function PrepareOuterResourceTerrain(',1,true)
local last=first and source:find('local function RebuildOuterResourceTerrainRegions(',first,true)
if not first or not last then fail('function boundaries');return end
source=source:sub(first,last-1)
local apply=source:find('local function apply_native_patch',1,true)
local body_first=apply and source:find('local dx, dy = x - patch.cx, y - patch.cy',apply,true)
local body_last=body_first and source:find('coarse:set(coarse_x, coarse_y,',body_first,true)
if not body_first or not body_last then fail('scalar boundaries');return end
local body=source:sub(body_first,body_last-1)..'return math.floor(weight * native_weight_scale + 0.5)\n'
local function inject(anchor,text,before)
    local a,b=source:find(anchor,1,true)
    if not a or source:find(anchor,b+1,true) then fail('ambiguous anchor '..anchor);return false end
    source=source:sub(1,before and a-1 or b)..text..source:sub(before and a or b+1)
    return true
end
local start=[[
                local function probe_scalar(cx,cy)
                    local x,y=x0+cx*sample_step,y0+cy*sample_step
]]..body..[[
                end
                local probe_state=probe_begin({patch=patch,guards=protection_blends,
                    base_transition=base_transition,irregularity=transition_irregularity,
                    radius=radius,x0=x0,y0=y0,sample_step=sample_step,
                    width=coarse_width,height=coarse_height,atan2_present=math.atan2~=nil},probe_scalar)
                local probe_scalar_start=probe_clock()
]]
if not inject('\t\t\t\tlocal cached_zero_sine, cached_zero_harmonic\n',start,false) then return end
local finish=[[
                local probe_scalar_ms=probe_clock()-probe_scalar_start
                local probe_grid=probe_finish(probe_state,coarse,probe_scalar_ms)
                if probe_grid~=coarse then coarse=own(probe_grid) end
]]
if not inject('\t\t\t\tsamples = coarse_width * coarse_height',finish,true) then return end
local active
local function execute(state)
    local before=GetPreciseTicks()
    local grid,stats,problem=kernel(api,state.geometry,state.scalar)
    state.grid=grid;state.entry.kernel_ms=GetPreciseTicks()-before
    state.entry.stats=stats
    if not grid then fail('native mask refused: '..tostring(problem));state.entry.error=problem end
end
local function begin(geometry,scalar)
    local entry={samples=geometry.width*geometry.height,guards=#geometry.guards,checked=0}
    if not active then fail('shadow outside active call');return {geometry=geometry,scalar=scalar,entry=entry} end
    active.patches[#active.patches+1]=entry
    local state={geometry=geometry,scalar=scalar,entry=entry}
    if native_first then execute(state) end
    return state
end
local function finish(state,coarse,scalar_ms)
    state.entry.scalar_ms=scalar_ms
    if not native_first then execute(state) end
    local grid=state.grid
    if not grid then return coarse end
    local row=state.geometry
    for cy=0,row.height-1 do for cx=0,row.width-1 do
        local a,b=grid:get(cx,cy),coarse:get(cx,cy)
        if a~=b then
            state.entry.difference={x=cx,y=cy,native=a,scalar=b}
            grid:free();fail('coarse mask mismatch');return coarse
        end
        state.entry.checked=state.entry.checked+1
    end end
    state.entry.used_candidate=true
    return grid
end
local prefix='local probe_begin,probe_finish,probe_clock=...\n'
if #names>0 then prefix=prefix..'local '..table.concat(names,',')..'\n' end
local compiled,why=load(prefix..source..'\nreturn PrepareOuterResourceTerrain','@native-mask-shadow','t',env)
if not compiled then fail(why);return end
local candidate=compiled(begin,finish,GetPreciseTicks)
for i=1,200 do
    local name=debug.getupvalue(candidate,i)
    if not name then break end
    if cells[name] then debug.upvaluejoin(candidate,i,original,cells[name])
    elseif name~='probe_begin' and name~='probe_finish' and name~='probe_clock' then fail('unjoined '..name);return end
end
sbm.TerrainCopy.PrepareOuterResourceTerrain=function(map,...)
    if active then fail('recursive shadow');return original(map,...) end
    active={patches={},environment=map.mapdata.Environment}
    local row=active
    local values=table.pack(candidate(map,...))
    active=nil;row.report=values[2]
    result.calls[#result.calls+1]=row
    local count=0
    for _,entry in ipairs(row.patches)do
        count=count+entry.checked
        if not entry.used_candidate then fail('candidate not used for patch') end
    end
    if type(row.report)~='table' or row.report.error~='' or #row.patches==0
        or count~=row.report.native_mask_samples then fail('shadow census/report') end
    if not result.error then result.status='pass' end
    return table.unpack(values,1,values.n)
end
result.status='ready'
return 'OUTER_MASK_SHADOW_READY'
