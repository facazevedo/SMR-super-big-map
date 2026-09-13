-- Same observable check as the native storage probe, using a positive bias so
-- no assertion depends on the engine's unsigned negative-value get() readback.
local api=dofile('_ralph/tools/parity/native_grid_double.lua')
for _,divisor in ipairs({1,8})do
 local from,to=api.NewComputeGrid(3,2,'f',32),api.NewComputeGrid(3,2,'f',32)
 for y=0,1 do for x=0,2 do from:set(x,y,65535-x-y)end end
 api.GridMulDivAdd(from,-1,divisor,0)
 to:copyrect(from,api.box(0,0,3,2),api.point(0,0))
 api.GridMulDivAdd(to,1,1,65536/divisor)
 api.GridMulDivAdd(to,divisor,1,0)
 for y=0,1 do for x=0,2 do assert(to:get(x,y)==1+x+y,'f32 copy routed through unsigned setter')end end
 from:free();to:free()
end
print('PASS 12 signed/fractional f32 copy/bias values; fractional native check accompanies reverse shadow')
