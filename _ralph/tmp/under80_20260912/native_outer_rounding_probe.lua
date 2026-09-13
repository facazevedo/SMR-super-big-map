-- Exercise the actual kernel's interval/correction tail at all4096 U12 ties.
-- Replace only its private pre-interval weight grid; no global API replacement.
local result={status='running',calls={}}
rawset(_G,'SBM_NATIVE_STEP_CERT_PROBE',result)
local err,source=AsyncFileToString('D:/PROJS/SMR/super-big-map/_ralph/tmp/under80_20260912/native_outer_mask.lua')
if err or type(source)~='string' then result.status='fail';result.error='source';return end
local chunk,why=load(source,'@native-mask-halfway','t',_G)
if not chunk then result.status='fail';result.error=tostring(why);return end
local kernel=chunk()
local api={}
for _,name in ipairs({'NewComputeGrid','GridMulDivAdd','GridAdd','GridAddMulDiv',
    'GridPow','GridAbs','GridMask','GridClamp','GridRound','GridCount','GridForeach','point','box'})do
    api[name]=rawget(_G,name)
    if type(api[name])~='function' then result.status='fail';result.error='missing '..name;return end
end
local unit_clamps,injected=0,0
api.GridClamp=function(grid,lo,hi)
    GridClamp(grid,lo,hi)
    if lo==0 and hi==1 then
        unit_clamps=unit_clamps+1
        if unit_clamps==3 then
            for y=0,63 do for x=0,63 do grid:set(x,y,2*(y*64+x)+1) end end
            GridMulDivAdd(grid,1,8192,0)
            injected=injected+1
        end
    end
end
local row={width=64,height=64,sample_step=1,x0=0,y0=0,radius=14.5,base_transition=10,
    irregularity=0,atan2_present=false,cached_zero_harmonic=0,
    patch={cx=32,cy=32,core_cells=1,relief_x=0,relief_y=0,phase=0},guards={}}
local grid,stats,problem=kernel(api,row,function(x,y)return y*64+x+1 end)
if not grid then result.status='fail';result.error=tostring(problem);return end
local checked=0
for y=0,63 do for x=0,63 do
    if grid:get(x,y)~=y*64+x+1 then
        grid:free();result.status='fail';result.error='uncorrected half-way cell';return
    end
    checked=checked+1
end end
grid:free()
result.calls[1]={checked=checked,injected=injected,stats=stats}
if injected~=1 or stats.corrected~=4096 or stats.changed_by_correction~=2048 then
    result.status='fail';result.error='half-way correction census';return
end
result.status='pass'
return 'NATIVE_OUTER_HALF_WAY_CORRECTION_PASS'
