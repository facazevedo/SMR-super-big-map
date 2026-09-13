-- Native qualification and integer-division boundary regressions, scratch only.
local result={status='running',calls={}}
rawset(_G,'SBM_NATIVE_STEP_CERT_PROBE',result)
local err,source=AsyncFileToString('D:/PROJS/SMR/super-big-map/_ralph/tmp/under80_20260912/native_outer_mask.lua')
if err or type(source)~='string' then result.status='fail';result.error='source';return end
local chunk,why=load(source,'@native-mask-domain','t',_G)
if not chunk then result.status='fail';result.error=tostring(why);return end
local kernel=chunk()
local api={}
for _,name in ipairs({'NewComputeGrid','GridMulDivAdd','GridAdd','GridAddMulDiv',
    'GridPow','GridAbs','GridMask','GridClamp','GridRound','GridCount','GridForeach','point','box'})do
    api[name]=rawget(_G,name)
    if type(api[name])~='function' then result.status='fail';result.error='missing '..name;return end
end
local allocations=0
api.NewComputeGrid=function(...)allocations=allocations+1;return NewComputeGrid(...)end
local function row()
    return {width=37,height=39,sample_step=1,x0=0,y0=0,radius=15.5,base_transition=10,
        irregularity=0,atan2_present=false,cached_zero_harmonic=0,
        patch={cx=18,cy=19,core_cells=2,relief_x=1,relief_y=0,phase=0},guards={}}
end
for _,mode in ipairs({'allowance','huge_coordinates','wrong_radius','small_budget','wrong_harmonic',
    'fractional_center','atan2','square_overflow','small_transition','large_transition'})do
    local input=row()
    local epsilon
    if mode=='allowance' then input.guards={{cx=27,cy=19,radius=213,transition=12}}
    elseif mode=='huge_coordinates' then input.x0=1e20;input.y0=1e20;input.patch.cx=1e20;input.patch.cy=1e20
    elseif mode=='wrong_radius' then input.radius=1
    elseif mode=='small_budget' then epsilon=1
    elseif mode=='wrong_harmonic' then input.cached_zero_harmonic=.5
    elseif mode=='fractional_center' then input.patch.cx=.5
    elseif mode=='atan2' then input.atan2_present=true
    elseif mode=='square_overflow' then input.patch.cx=-4096
    elseif mode=='small_transition' then input.guards={{cx=27,cy=19,radius=3,transition=.249}}
    elseif mode=='large_transition' then input.guards={{cx=27,cy=19,radius=3,transition=129}} end
    allocations=0
    local grid,stats,problem=kernel(api,input,function()return 0 end,epsilon)
    local accepted=grid~=nil
    if grid then grid:free() end
    local pass=mode=='allowance' and accepted and stats.derived_numerator==3
        or mode~='allowance' and not accepted and type(problem)=='string' and allocations==0
    result.calls[#result.calls+1]={mode=mode,pass=pass,accepted=accepted,
        allocations=allocations,derived=stats.derived_numerator,reason=problem}
    if not pass then result.status='fail';result.error=mode;return end
end
result.status='pass'
return 'NATIVE_OUTER_DOMAIN_PASS'
