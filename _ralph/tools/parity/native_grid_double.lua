-- Offline compute-grid double for the native apron tests. Real engine behavior is
-- separately differential-tested on scratch grids; this double is not a speed oracle.
local function f32(v) return string.unpack("f", string.pack("f", v)) end
local function cast(v,format)
	if format=="f" then return f32(v) end
	return math.max(0, math.min(65535, math.floor(v)))
end
local api={}
function api.point(x,y) return {x=x,y=y} end
function api.box(x0,y0,x1,y1) return {x0=x0,y0=y0,x1=x1,y1=y1} end
local methods={}
local function make(w,h,format,bits)
	return setmetatable({w=w,h=h,format=format:lower(),bits=bits,values={},freed=false}, {__index=methods})
end
function methods:size() assert(not self.freed);return self.w,self.h end
function methods:get(x,y)
	assert(not self.freed and x>=0 and x<self.w and y>=0 and y<self.h)
	return self.values[y*self.w+x] or 0
end
function methods:set(x,y,value)
	assert(not self.freed and x>=0 and x<self.w and y>=0 and y<self.h)
	-- The native setter accepts unsigned integers even for F32 storage.
	self.values[y*self.w+x]=cast(math.floor(value)%4294967296,self.format)
end
function methods:free() assert(not self.freed,"double free");self.freed=true end
function methods:new_instance(w,h) return make(w,h,self.format,self.bits) end
function methods:clone()
	assert(not self.freed)
	local result=self:new_instance(self.w,self.h)
	for k,v in pairs(self.values) do result.values[k]=v end
	return result
end
function methods:copyrect(source,bounds,destination)
	assert(not self.freed)
	local sw,sh=source:size()
	assert(bounds.x0>=0 and bounds.y0>=0 and bounds.x1<=sw and bounds.y1<=sh)
	for y=bounds.y0,bounds.y1-1 do for x=bounds.x0,bounds.x1-1 do
		local dx,dy=destination.x+x-bounds.x0,destination.y+y-bounds.y0
		if self.format=="f" and source.format=="f" then
			-- Native f32 copyrect preserves signed storage; it does NOT go through
			-- the unsigned Lua setter. Engine proof: crease_offer_native_reference_storage.
			assert(dx>=0 and dx<self.w and dy>=0 and dy<self.h)
			self.values[dy*self.w+dx]=source:get(x,y)
		else
			self:set(dx,dy,source:get(x,y))
		end
	end end
end
api.NewComputeGrid=make
function api.IsComputeGrid(grid) return grid.format or "u",grid.bits or 16 end
function api.GridRepack(grid,format,bits,copy)
	local w,h=grid:size()
	local result=make(w,h,format,bits)
	for y=0,h-1 do for x=0,w-1 do result.values[y*w+x]=cast(grid:get(x,y),format) end end
	return result
end
local function mutate(grid,fn)
	local w,h=grid:size()
	for y=0,h-1 do for x=0,w-1 do grid.values[y*w+x]=cast(fn(grid:get(x,y),x,y),grid.format) end end
end
function api.GridFill(grid,value) mutate(grid,function() return value end) end
function api.GridMulDivAdd(grid,mul,div,add)
	div,add=div or 1,add or 0
	mutate(grid,function(v,x,y)
		local m=type(mul)=="table" and mul:get(x,y) or mul
		return f32(f32(f32(v*m)/div)+add)
	end)
end
function api.GridAddMulDiv(grid,add,mul,div)
	mul,div=mul or 1,div or 1
	mutate(grid,function(v,x,y) return f32(v+f32(f32(add:get(x,y)*mul)/div)) end)
end
function api.GridAdd(grid,other)
	mutate(grid,function(v,x,y) return f32(v+other:get(x,y)) end)
end
function api.GridAbs(grid) mutate(grid,math.abs) end
function api.GridPow(grid,mul,div)
	local power=mul/(div or 1)
	mutate(grid,function(value) return f32(value^power) end)
end
function api.GridRound(grid) mutate(grid,function(v) return math.floor(v+0.5) end) end
function api.GridClamp(grid,lo,hi) mutate(grid,function(v) return math.max(lo,math.min(hi,v)) end) end
function api.GridMinMax(grid)
	local lo,hi
	local w,h=grid:size()
	for y=0,h-1 do for x=0,w-1 do
		local v=grid:get(x,y);lo=lo and math.min(lo,v) or v;hi=hi and math.max(hi,v) or v
	end end
	return lo,hi
end
function api.GridCount(grid,lo,hi)
	local count=0
	local w,h=grid:size()
	for y=0,h-1 do for x=0,w-1 do
		local v=grid:get(x,y);if v>lo and v<=hi then count=count+1 end
	end end
	return count
end
function api.GridForeach(grid,fn,lo,hi)
	local w,h=grid:size()
	for y=0,h-1 do for x=0,w-1 do
		local v=grid:get(x,y);if v>lo and v<=hi then fn(v,x,y) end
	end end
end
function api.GridResample(source,w,h,interpolate)
	assert(interpolate==true)
	local sw,sh=source:size()
	local result=make(w,h,source.format,source.bits)
	for y=0,h-1 do for x=0,w-1 do
		local px,py=f32(x*(sw-1)/(w-1)),f32(y*(sh-1)/(h-1))
		local x0,y0=math.floor(px),math.floor(py)
		local x1,y1=math.min(sw-1,x0+1),math.min(sh-1,y0+1)
		local fx,fy=f32(px-x0),f32(py-y0)
		local a=f32(f32(source:get(x0,y0)*(1-fx))+f32(source:get(x1,y0)*fx))
		local b=f32(f32(source:get(x0,y1)*(1-fx))+f32(source:get(x1,y1)*fx))
		result.values[y*w+x]=f32(f32(a*(1-fy))+f32(b*fy))
	end end
	return result
end
return api
