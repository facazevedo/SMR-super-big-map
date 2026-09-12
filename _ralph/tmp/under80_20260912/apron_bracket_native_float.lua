-- Unrun bracket research: literal scalar, accepted native blend, narrower bracket.
local result={status='running',checks=0,mismatches=0,cases={}}
rawset(_G,'SBM_NATIVE_STEP_CERT_PROBE',result)
result.numeric_semantics={negative_integer_power=2^-30,integer_division=1/3,explicit_float_division=1.0/3.0}
PauseInfiniteLoopDetection('SBMNativeApronProbe')
local grids={}
local function own(g) grids[#grids+1]=g;return g end
local function free_all() for i=#grids,1,-1 do grids[i]:free();grids[i]=nil end end
local ok,why=pcall(function()
    local env,sbm
    for _,mod in ipairs(ModsLoaded or {}) do
        local value=mod.env and rawget(mod.env,'SuperBigMap')
        if value and value.Config then env,sbm=mod.env,value;break end
    end
    if not sbm then error('mod missing') end
    local function read(path)
        local err,text=AsyncFileToString('D:/PROJS/SMR/super-big-map/'..path)
        if err or not text then error('read failed '..tostring(err)) end
        return text:gsub('\r\n','\n')
    end
    local function compile(text,name)
        local fn,err=load(text,name,'t',env)
        if not fn then error(tostring(err)) end
        return fn()
    end
    local function raster(path)
        local source=read(path)
        local a=source:find('local function RasterNaturalMountainBaseAprons(',1,true)
        local b=source:find('local function CreateNaturalMountainBaseBuildableAprons(',a,true)
        return compile(source:sub(a,b-1)..'\nreturn RasterNaturalMountainBaseAprons','@'..path)
    end
    local native=raster('_ralph/runs/under80-20260912/artifacts/apron_bracket_research/terrain_candidate.lua')
    local accepted=raster('Code/sbm_terrain_copy.lua')
    local scalar=compile(read('_ralph/tools/parity/v958_scalar_apron.lua'),'@literal-scalar')
    local api={}
    for _,name in ipairs({'NewComputeGrid','GridRepack','IsComputeGrid','GridResample',
        'GridMulDivAdd','GridAddMulDiv','GridAdd','GridClamp','GridAbs','GridCount','GridForeach',
        'GridFill','GridRound','GridMinMax','GridPow','box','point'}) do api[name]=sbm.Engine.Global(name) end
    local cores={0.2,0.25-0.000000000931322574615478515625,0.25,0.25+0.000000000931322574615478515625,0.55-0.000000000931322574615478515625,0.55,0.55+0.000000000931322574615478515625,0.75,1.0/3.0,0.4,0.6}
    for case=1,33 do
        local w,h=128,124
        local grid=own(api.NewComputeGrid(w,h,'u',16))
        for y=0,h-1 do for x=0,w-1 do
            local value=case%4==0 and 65535-(x*37+y*19)%500
                or case%4==1 and (x*37+y*19)%500
                or case%4==2 and 30000+x*11-y*5
                or (x*x*137+y*y*83+x*y*23)%65536
            grid:set(x,y,value)
        end end
        local previous,expected=own(grid:clone()),own(grid:clone())
        local selected={}
        for index=1,3 do
            local x,y=49+index*8,45+index*7
            local angle=(case*29+index*73)*0.01
            selected[index]={x=x,y=y,sector_x=case,sector_y=index,center=grid:get(x,y),
                gx=math.cos(angle)*3.7,gy=math.sin(angle)*3.7,mountain_x=math.cos(angle),
                mountain_y=math.sin(angle),requires_edit=index~=2}
        end
        local policy={outer_short=24,outer_long=32.4,core_fraction=cores[(case-1)%#cores+1]}
        local start=GetPreciseTicks()
        local old_ok,old_stats,old_error=accepted(api,previous,selected,policy)
        local old_ms=GetPreciseTicks()-start
        start=GetPreciseTicks()
        local new_ok,new_stats,new_error=native(api,grid,selected,policy)
        local native_ms=GetPreciseTicks()-start
        start=GetPreciseTicks()
        local scalar_ok,scalar_stats,scalar_error=scalar(expected,selected,policy)
        local scalar_ms=GetPreciseTicks()-start
        if not old_ok or not new_ok or not scalar_ok or old_error or new_error or scalar_error then
            error('raster failed '..tostring(old_error)..'/'..tostring(new_error)..'/'..tostring(scalar_error))
        end
        if old_stats.modified~=scalar_stats.modified or new_stats.modified~=scalar_stats.modified
            or old_stats.shaped~=new_stats.shaped then result.mismatches=result.mismatches+1 end
        local differing,old_different,new_different,old_new_different=0,0,0,0
        for y=0,h-1 do for x=0,w-1 do
            if grid:get(x,y)~=expected:get(x,y) then new_different=new_different+1 end
            if previous:get(x,y)~=expected:get(x,y) then old_different=old_different+1 end
            if grid:get(x,y)~=previous:get(x,y) then old_new_different=old_new_different+1 end
            if grid:get(x,y)~=expected:get(x,y) or previous:get(x,y)~=expected:get(x,y) then
                differing=differing+1
            end
            result.checks=result.checks+1
        end end
        result.mismatches=result.mismatches+differing
        result.cases[#result.cases+1]={case=case,differing=differing,old_ms=old_ms,native_ms=native_ms,
            scalar_ms=scalar_ms,old_exact=old_stats.exact_samples,new_exact=new_stats.exact_samples,
            cells=new_stats.raster_cells,core=policy.core_fraction,old_different=old_different,
            new_different=new_different,old_new_different=old_new_different}
        free_all()
    end
end)
free_all()
ResumeInfiniteLoopDetection('SBMNativeApronProbe')
result.status=ok and result.mismatches==0 and 'pass' or 'fail'
result.error=ok and '' or tostring(why)
print('SBM_NATIVE_APRON_PROBE',result.status,result.checks,result.mismatches,result.error)
