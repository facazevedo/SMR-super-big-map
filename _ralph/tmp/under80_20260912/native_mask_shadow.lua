-- Fresh-process shadow experiment: both algorithms receive the same input.
-- Only continue with the accepted output if any comparison fails.
local result={status='setup',calls={}}
rawset(_G,'SBM_NATIVE_MASK_DIAGNOSTIC',result)
local env,sbm
for _,mod in ipairs(ModsLoaded or {}) do
    local value=mod.env and rawget(mod.env,'SuperBigMap')
    if value and value.Config then env,sbm=mod.env,value;break end
end
if not sbm then result.status='fail';error('native mask shadow: mod missing');return end
local err,source=AsyncFileToString('D:/PROJS/SMR/super-big-map/_ralph/runs/under80-20260912/artifacts/native_mask_research/terrain_candidate.lua')
if err or not source then result.status='fail';error('native mask source missing');return end
source=source:gsub('\r\n','\n')
local a=source:find('local function RasterNaturalMountainBaseAprons(',1,true)
local b=source:find('local function CreateNaturalMountainBaseBuildableAprons(',a,true)
local fn,compile_error=load(source:sub(a,b-1)..'\nreturn RasterNaturalMountainBaseAprons','@native-mask-shadow','t',env)
if not fn then result.status='fail';error(tostring(compile_error));return end
local candidate=fn()
local installed=0
for i=1,200 do
    local name,create=debug.getupvalue(sbm.TerrainCopy.StretchSourceToFull,i)
    if not name then break end
    if name=='CreateNaturalMountainBaseBuildableAprons' then
        for j=1,200 do
            local inner,original=debug.getupvalue(create,j)
            if not inner then break end
            if inner=='RasterNaturalMountainBaseAprons' then
                local wrapper=function(api,grid,selected,policy)
                    local previous=grid:clone()
                    local new_api={};for key,value in pairs(api) do new_api[key]=value end
                    new_api.GridPow=sbm.Engine.Global('GridPow')
                    local started=GetPreciseTicks()
                    local token=sbm.Diagnostics.LoadingBegin('split native mask candidate')
                    local new_ok,new_stats,new_error=candidate(new_api,grid,selected,policy)
                    sbm.Diagnostics.LoadingEnd(token)
                    local new_ms=GetPreciseTicks()-started
                    started=GetPreciseTicks()
                    token=sbm.Diagnostics.LoadingBegin('split accepted mask shadow')
                    local old_ok,old_stats,old_error=original(api,previous,selected,policy)
                    sbm.Diagnostics.LoadingEnd(token)
                    local old_ms=GetPreciseTicks()-started
                    local delta=api.GridRepack(grid,'f',32,true)
                    local expected=api.GridRepack(previous,'f',32,true)
                    api.GridAddMulDiv(delta,expected,-1);api.GridAbs(delta)
                    api.GridMulDivAdd(delta,2,1,0)
                    local different=api.GridCount(delta,1,2147483647)
                    result.calls[#result.calls+1]={native_ms=new_ms,accepted_ms=old_ms,different=different,
                        native_stats=new_stats,accepted_stats=old_stats,native_ok=new_ok,accepted_ok=old_ok,
                        native_error=new_error or '',accepted_error=old_error or ''}
                    local good=new_ok and old_ok and not new_error and not old_error and different==0
                        and new_stats.modified==old_stats.modified and new_stats.shaped==old_stats.shaped
                    if not good then
                        grid:copy(previous)
                        result.status='fail'
                    elseif result.status~='fail' then result.status='pass' end
                    delta:free();expected:free();previous:free()
                    -- Preserve predecessor reporting; experiment counters are captured separately.
                    return old_ok,old_stats,old_error
                end
                if debug.setupvalue(create,j,wrapper)==inner then installed=installed+1 end
            end
        end
    end
end
if installed~=1 then result.status='fail';error('native mask shadow upvalue missing');return end
sbm.Config.DEBUG_LOGGING_ENABLED=true
sbm.Config.DEBUG_LOADING_TIMINGS=true
result.status='ready'
return 'NATIVE_MASK_SHADOW_READY'
