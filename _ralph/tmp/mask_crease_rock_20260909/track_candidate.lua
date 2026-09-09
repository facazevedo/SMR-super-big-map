-- Batched translation of independent rows within ONE already-selected track.
-- No feather/refinement/track reordering. Caller feathers these rows immediately.
local function TranslateHeightTrack(api, grid, axis, before_edge, rows, maximum)
	if #rows==0 then return 0 end
	for _,name in ipairs({'NewComputeGrid','GridRepack',
		'GridFill','GridMulDivAdd','GridAdd','GridMask','GridClamp','box','point','IsComputeGrid'}) do
		if type(api[name])~='function' then return nil,'missing track translation API: '..name end
	end
	local format,bits=api.IsComputeGrid(grid)
	if tostring(format):lower()~='u' or bits~=16 then return nil,'track translation requires U16' end
	if (axis~='x' and axis~='y') or maximum<0 or maximum>65535 or maximum~=math.floor(maximum) then
		return nil,'invalid track translation axis or clamp'
	end
	local w,h=grid:size();local pn,an=axis=='x' and w or h,axis=='x' and h or w
	local p0,p1,a0,a1,modified=pn,0,an,0,0
	local last=-1
	for _,row in ipairs(rows) do
		if row.along<=last or row.along<0 or row.along>=an or row.lo<0 or row.hi>=pn
			or row.lo>row.hi or row.offset<=0 or row.offset>65535
			or row.along~=math.floor(row.along) or row.lo~=math.floor(row.lo)
			or row.hi~=math.floor(row.hi) or row.offset~=math.floor(row.offset)
			or (before_edge and row.lo~=0) or (not before_edge and row.hi~=pn-1) then
			return nil,'invalid or dependent track translation rows'
		end
		last=row.along;p0=math.min(p0,row.lo);p1=math.max(p1,row.hi)
		a0=math.min(a0,row.along);a1=math.max(a1,row.along)
		modified=modified+row.hi-row.lo+1
	end
	-- A qualified physical-edge track has many rows and a nontrivial edge strip.
	-- Pad singleton axes within the grid so native interpolation has two endpoints.
	if p1==p0 then if p1<pn-1 then p1=p1+1 else p0=p0-1 end end
	if a1==a0 then if a1<an-1 then a1=a1+1 else a0=a0-1 end end
	local owned={}
	local function own(value)
		if value then owned[#owned+1]=value end
		return value
	end
	local function work()
		local pw,ah=p1-p0+1,a1-a0+1
		local lw,lh=axis=='x' and pw or ah,axis=='x' and ah or pw
		local x0,y0=axis=='x' and p0 or a0,axis=='x' and a0 or p0
		local raw=own(grid:new_instance(lw,lh))
		local boundary=own(api.NewComputeGrid(axis=='x' and 1 or ah,axis=='x' and ah or 1,'f',32))
		local offsets=own(api.NewComputeGrid(axis=='x' and 1 or ah,axis=='x' and ah or 1,'f',32))
		local ramp=own(api.NewComputeGrid(axis=='x' and pw or 1,axis=='x' and 1 or pw,'f',32))
		if not raw or not boundary or not offsets or not ramp then return nil,'track allocation failed' end
		raw:copyrect(grid,api.box(x0,y0,x0+lw,y0+lh),api.point(0,0))
		api.GridFill(boundary,131072);api.GridFill(offsets,0);api.GridFill(ramp,0)
		for p=0,pw-1 do ramp:set(axis=='x' and p or 0,axis=='x' and 0 or p,2*p) end
		for _,row in ipairs(rows) do
			local a=row.along-a0;local x,y=axis=='x' and 0 or a,axis=='x' and a or 0
			local bound=before_edge and (2*(row.hi-p0)+1) or (2*(row.lo-p0)-1)
			boundary:set(x,y,131072+bound);offsets:set(x,y,row.offset)
		end
		-- Replicate integer rows/columns by non-overlapping native copies, never
		-- resample the along-axis. Even nominally identity resampling can alter
		-- a large row's offset through native coordinate quantization.
		local function replicate(seed)
			local sw,sh=seed:size()
			local target=own(api.NewComputeGrid(lw,lh,'f',32))
			if not target then return nil end
			target:copyrect(seed,api.box(0,0,sw,sh),api.point(0,0))
			while sw<lw do
				local count=math.min(sw,lw-sw)
				target:copyrect(target,api.box(0,0,count,sh),api.point(sw,0));sw=sw+count
			end
			while sh<lh do
				local count=math.min(sh,lh-sh)
				target:copyrect(target,api.box(0,0,sw,count),api.point(0,sh));sh=sh+count
			end
			return target
		end
		local source=own(api.GridRepack(raw,'f',32,true))
		local margin=replicate(boundary)
		local delta=replicate(offsets)
		local coordinate=replicate(ramp)
		local mask=own(api.NewComputeGrid(lw,lh,'f',32))
		if not source or not margin or not delta or not coordinate or not mask then return nil,'track conversion failed' end
		if before_edge then
			api.GridMulDivAdd(coordinate,-1,1,0);api.GridAdd(margin,coordinate)
		else
			api.GridMulDivAdd(margin,-1,1,262144);api.GridAdd(margin,coordinate)
		end
		api.GridMask(margin,mask,131072,2147483647)
		api.GridMulDivAdd(delta,mask,1,0);api.GridAdd(source,delta)
		api.GridClamp(source,0,maximum)
		local result=own(api.GridRepack(source,format,bits,true))
		if not result then return nil,'track result conversion failed' end
		local rw,rh=result:size()
		if rw~=lw or rh~=lh then return nil,'track result dimensions changed' end
		grid:copyrect(result,api.box(0,0,lw,lh),api.point(x0,y0))
		return modified
	end
	local ok,value,err=pcall(work)
	for i=#owned,1,-1 do local freed,why=pcall(owned[i].free,owned[i]);if not freed then ok=false;value=why end end
	if not ok then return nil,tostring(value) end
	return value,err
end
return TranslateHeightTrack
