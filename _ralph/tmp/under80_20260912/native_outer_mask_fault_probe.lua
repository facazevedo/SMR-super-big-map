-- Expected native residual failures, using only private scratch grids/API wrappers.
local result={status='running',calls={}}
rawset(_G,'SBM_NATIVE_STEP_CERT_PROBE',result)
local root='D:/PROJS/SMR/super-big-map/'
local function read(path)
    local err,value=AsyncFileToString(root..path)
    if err or type(value)~='string' then return nil,tostring(err) end
    return value
end
local source,why=read('_ralph/tmp/under80_20260912/native_outer_mask.lua')
local geometry=read('_ralph/runs/under80-20260912/artifacts/outer_mask_world_coordinate_study_reference/geometry.lua')
if not source or not geometry then result.status='fail';result.error=why or 'missing geometry';return end
local kernel_chunk,why=load(source,'@native-outer-fault-test','t',_G)
local geometry_chunk=load(geometry,'@geometry','t',_G)
if not kernel_chunk or not geometry_chunk then result.status='fail';result.error=tostring(why);return end
local kernel,row=kernel_chunk(),geometry_chunk()[1]
local base={}
for _,name in ipairs({'NewComputeGrid','GridMulDivAdd','GridAdd','GridAddMulDiv',
    'GridPow','GridAbs','GridMask','GridClamp','GridRound','GridCount','GridForeach','point','box'}) do
    base[name]=rawget(_G,name)
    if type(base[name])~='function' then result.status='fail';result.error='missing '..name;return end
end
for _,case in ipairs({
    {name='large root',power=1,divisor=2,mul=1000,div=1,reason='root residual'},
    {name='small root perturbation',power=1,divisor=2,mul=1000001,div=1000000,reason='root residual'},
    {name='large reciprocal',power=-1,divisor=1,mul=1000,div=1,reason='reciprocal residual'},
    {name='small reciprocal perturbation',power=-1,divisor=1,mul=1000001,div=1000000,reason='reciprocal residual'},
}) do
    local api={};for k,v in pairs(base)do api[k]=v end
    api.GridPow=function(grid,m,d)
        base.GridPow(grid,m,d)
        if m==case.power and d==case.divisor then base.GridMulDivAdd(grid,case.mul,case.div,0) end
    end
    local output,stats,problem=kernel(api,row,function()return 0 end)
    local expected=not output and type(problem)=='string' and problem:find(case.reason,1,true)~=nil
    if output then output:free() end
    result.calls[#result.calls+1]={name=case.name,rejected=expected,reason=problem}
    if not expected then result.status='fail';result.error='fault was not rejected: '..case.name;return end
end
result.status='pass'
return 'NATIVE_OUTER_RESIDUAL_FAULTS_REJECTED'
