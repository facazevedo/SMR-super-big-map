local result={status='running',checks=0,max_code_error=0,cases={}}
rawset(_G,'SBM_NATIVE_STEP_CERT_PROBE',result)
PauseInfiniteLoopDetection('SBMNativeMaskProbe')
local owned={}
local function free_all()
    for i=#owned,1,-1 do owned[i]:free();owned[i]=nil end
end
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
    local native=compile(read('_ralph/tmp/under80_20260912/native_apron_mask.lua'),'@native-mask')
    local source=read('Code/sbm_terrain_copy.lua')
    local raster=source:find('local function RasterNaturalMountainBaseAprons(',1,true)
    local first=source:find('local function weight(',raster,true)
    local last=source:find('\n\tfor index,candidate',first,true)
    local scalar=compile('return function(policy) local sqrt=math.sqrt; local stats={mask_fast_zero=0,mask_fast_one=0}; '
        ..'local core_radius2=(policy.core_fraction*0.90)*(policy.core_fraction*0.90); '
        ..source:sub(first,last-1)..'\nreturn weight end','@scalar-mask')
    local api={}
    for _,name in ipairs({'NewComputeGrid','GridMulDivAdd','GridAddMulDiv','GridAdd','GridPow',
        'GridClamp','GridResample','GridRound','GridCount','box','point'}) do api[name]=sbm.Engine.Global(name) end
    local function own(g) owned[#owned+1]=g;return g end
    for case=1,24 do
        local w,h=97,91
        local angle=case*0.371
        local candidate={x=48.125,y=45.375,mountain_x=math.cos(angle),mountain_y=math.sin(angle)}
        local policy={core_fraction=({0.20,1.0/3,0.58,0.75})[(case-1)%4+1]}
        local short=16+case*0.73;local long=short*1.35
        local start=GetPreciseTicks()
        local mask=native(api,own,candidate,policy,short,long,0,0,w,h)
        local native_ms=GetPreciseTicks()-start
        local weight=scalar(policy)
        local max_error,nonzero=0,0
        start=GetPreciseTicks()
        for y=0,h-1 do for x=0,w-1 do
            local expected=math.floor(weight(candidate,short,long,x-candidate.x,y-candidate.y)*16777216+0.5)
            local actual=mask:get(x,y)
            local difference=math.abs(actual-expected)
            max_error=math.max(max_error,difference)
            if difference~=0 then nonzero=nonzero+1 end
            result.checks=result.checks+1
        end end
        result.max_code_error=math.max(result.max_code_error,max_error)
        result.cases[#result.cases+1]={case=case,max_code_error=max_error,nonzero=nonzero,
            native_ms=native_ms,scalar_oracle_ms=GetPreciseTicks()-start}
        free_all()
    end
end)
free_all()
ResumeInfiniteLoopDetection('SBMNativeMaskProbe')
result.status,result.error=ok and 'pass' or 'fail',ok and '' or tostring(why)
print('SBM_NATIVE_MASK_PROBE',result.status,result.checks,result.max_code_error,result.error)
