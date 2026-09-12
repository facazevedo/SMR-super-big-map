local path=arg[1] or 'Code/sbm_terrain_copy.lua'
local f=assert(io.open(path,'r'));local source=f:read('*a');f:close()
local a=assert(source:find('local NativeApronMask = function(',1,true))
local b=assert(source:find('\n\tlocal required =',a,true))
local native=assert(load(source:sub(a,b-1)..'\nreturn NativeApronMask'))()
local function run(candidate,w,h,x0,y0,short,long)
    local api=dofile('_ralph/tools/parity/native_grid_double.lua')
    local allocate=api.NewComputeGrid
    local allocations,owned=0,{}
    api.NewComputeGrid=function(...)allocations=allocations+1;return allocate(...)end
    local function own(g)if g then owned[#owned+1]=g end;return g end
    local mask,why=native(api,own,candidate,{core_fraction=.2},short,long,x0,y0,w,h)
    for i=#owned,1,-1 do owned[i]:free()end
    return mask,why,allocations
end
local axis={x=0,y=0,mountain_x=1,mountain_y=0}
local mask,why=run(axis,41,41,-20,-20,10,10)
assert(mask and not why,'exact 24-bit coordinate span rejected')
local mask,why,allocations=run(axis,42,41,-20,-20,10,10)
assert(not mask and not why and allocations==0,'oversize encoded axis must use scalar before allocation')
local Q=4194304
local tie={x=0,y=0,mountain_x=2-.5/Q,mountain_y=2+.5/Q}
local mask,why,allocations=run(tie,2,2,0,0,1,1)
assert(not mask and not why and allocations==0,'quantized corner sum exceeded exact f32 integer domain')
local zero_axis={x=0,y=0,mountain_x=0,mountain_y=0}
local smallest=0.00000095367431640625
local mask,why,allocations=run(zero_axis,2,2,0,0,smallest*.5,smallest)
assert(not mask and not why and allocations==0,'sub-domain radius must use the scalar path')
local mask,why=run(zero_axis,2,2,0,0,smallest,smallest)
assert(mask and not why,'radius domain endpoint rejected')
-- Reuse the complete production native allocation/clone/power-error/lifetime test
-- against production, without changing the inherited fixture.
local io_proxy=setmetatable({open=function(name,...)
    return io.open(name=='Code/sbm_terrain_copy.lua' and path or name,...)
end},{__index=io})
local env=setmetatable({io=io_proxy},{__index=_G})
assert(loadfile('_ralph/tools/parity/native_apron_mask_test.lua','t',env))()
print('PASS Q22 exact-span and rounded-corner guards; inherited native failure/ownership regression')
