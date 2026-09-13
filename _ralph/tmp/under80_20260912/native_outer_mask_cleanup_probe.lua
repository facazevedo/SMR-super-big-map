-- Private scratch-only failure/ownership tests. No global native API replacement.
local result={status='running',calls={}}
rawset(_G,'SBM_NATIVE_STEP_CERT_PROBE',result)
local err,source=AsyncFileToString('D:/PROJS/SMR/super-big-map/_ralph/tmp/under80_20260912/native_outer_mask.lua')
if err or type(source)~='string' then result.status='fail';result.error='source unavailable';return end
local chunk,why=load(source,'@native-outer-cleanup','t',_G)
if not chunk then result.status='fail';result.error=tostring(why);return end
local kernel=chunk()
local row={width=37,height=39,sample_step=1,x0=0,y0=0,radius=15.5,base_transition=10,
    irregularity=0,atan2_present=false,cached_zero_harmonic=0,
    patch={cx=18,cy=19,core_cells=2,relief_x=1,relief_y=0,phase=0},
    guards={{cx=27,cy=19,radius=3,transition=.38}}}
local names={'NewComputeGrid','GridMulDivAdd','GridAdd','GridAddMulDiv','GridPow',
    'GridAbs','GridMask','GridClamp','GridRound','GridCount','GridForeach','point','box'}
local base={}
for _,name in ipairs(names) do
    base[name]=rawget(_G,name)
    if type(base[name])~='function' then result.status='fail';result.error='missing '..name;return end
end
local function run(mode,fail_at)
    local owned,allocations,freed,duplicate_free={},0,0,false
    local function unwrap(v) if type(v)=='table' and v.native then return v.native end;return v end
    local function args(...) local a=table.pack(...);for i=1,a.n do a[i]=unwrap(a[i]) end;return a end
    local function register(g)
        if not g then return nil end
        local proxy={native=g,freed=false}
        owned[#owned+1]=proxy
        function proxy:clone()
            allocations=allocations+1
            if mode=='allocation' and allocations==fail_at then return nil end
            return register(self.native:clone())
        end
        function proxy:free()
            if self.freed then duplicate_free=true;return end
            self.native:free();self.freed=true;freed=freed+1
        end
        for _,method in ipairs({'set','get','copyrect'}) do
            proxy[method]=function(self,...)
                local a=args(...)
                return self.native[method](self.native,table.unpack(a,1,a.n))
            end
        end
        return proxy
    end
    local api={}
    for _,name in ipairs(names) do
        api[name]=function(...)
            local a=args(...)
            return base[name](table.unpack(a,1,a.n))
        end
    end
    api.NewComputeGrid=function(...)
        allocations=allocations+1
        if mode=='allocation' and allocations==fail_at then return nil end
        return register(base.NewComputeGrid(...))
    end
    api.GridForeach=function(grid,fn,lo,hi)
        if mode=='census' then return end
        if mode=='duplicate' then return base.GridForeach(unwrap(grid),function(v,x,y)fn(v,x,y);fn(v,x,y)end,lo,hi) end
        if mode=='coordinate' then return base.GridForeach(unwrap(grid),function(v,x,y)fn(v,-1,y)end,lo,hi) end
        return base.GridForeach(unwrap(grid),fn,lo,hi)
    end
    local output,stats,problem=kernel(api,row,function()
        if mode=='scalar' then return 4097 end
        return 0
    end)
    local accepted=output~=nil
    local freed_before=freed
    if output then output:free() end
    local all_freed=freed==#owned and not duplicate_free
    -- Emergency cleanup preserves the evidence of a leak before releasing it.
    for _,g in ipairs(owned) do if not g.freed then g:free() end end
    local pass=all_freed and (mode=='normal' and accepted and freed_before==#owned-1
        or mode~='normal' and not accepted and type(problem)=='string')
    result.calls[#result.calls+1]={mode=mode,fail_at=fail_at,pass=pass,accepted=accepted,
        allocations=allocations,owned=#owned,freed_before=freed_before,all_freed=all_freed,reason=problem,
        corrections=stats.corrected}
    return pass,allocations
end
local pass,total=run('normal')
if not pass then result.status='fail';result.error='normal ownership';return end
for i=1,total do
    if not run('allocation',i) then result.status='fail';result.error='allocation '..i;return end
end
for _,mode in ipairs({'census','duplicate','coordinate','scalar'}) do
    if not run(mode) then result.status='fail';result.error=mode;return end
end
result.status='pass'
result.allocation_failure_points=total
return 'NATIVE_OUTER_CLEANUP_PASS'
