-- Narrow correction service, separate from the read-only support validator.
-- A rigid pose is retained: no mesh edits, scale changes or per-piece sinking.
local SBM=rawget(_G,"SuperBigMap")
local Global=SBM.Engine.Global
local Seating={}

-- Pure planner: every component/LOD must contact terrain AND retain visible
-- height. A partly supported top-up may search nearby terrain; native objects
-- never change XY. No geometry is changed by planning.
function Seating.Plan(components,height,options)
	if #components==0 then return nil,"no rendered components" end
	local tile=options.tile
	local function candidate(dx,dy)
		local lo,hi=-math.huge,math.huge
		for _,component in ipairs(components) do
			local low,high=math.huge,-math.huge
			for _,p in ipairs(component.vertices) do
				local h=height(p[1]+dx,p[2]+dy)
				if type(h)~="number" then return nil end
				local clearance=p[3]-h
				low=math.min(low,clearance);high=math.max(high,clearance)
			end
			-- Retain at least half the component's vertical extent above terrain.
			-- This forbids fixing the detached stone by burying the rest of a cluster.
			local visible=math.max(2,component.height*(options.visible_fraction or 0.5))
			lo=math.max(lo,visible-high);hi=math.min(hi,-low)
			if lo>hi then return nil end
		end
		local dz=math.min(0,hi)
		if dz<lo then dz=lo end
		dz=math.floor(dz)
		if dz<lo or (options.allowed and not options.allowed(dx,dy,dz)) then return nil end
		return {dx=dx,dy=dy,dz=dz}
	end
	local at_origin=candidate(0,0)
	if at_origin then return at_origin end
	if not options.allow_xy then return nil,"no safe rigid vertical seating" end
	-- Deterministic expanding square rings; only extra top-up decorations may
	-- move horizontally, and an explicit caller bound protects the playable map.
	for ring=1,options.rings or 16 do
		for x=-ring,ring do
			local found=candidate(x*tile,-ring*tile) or candidate(x*tile,ring*tile)
			if found then return found end
		end
		for y=-ring+1,ring-1 do
			local found=candidate(-ring*tile,y*tile) or candidate(ring*tile,y*tile)
			if found then return found end
		end
	end
	return nil,"no safe nearby rigid seating"
end

function Seating.Run(map)
	if SBM.Engine.MapDataEnvironment(map.mapdata)~="Surface" then return nil end
	local validator=SBM.DecorationValidation
	if not validator or not validator.SeatingEvidence then return nil end
	local terrain,point_fn=Global("terrain"),Global("point")
	local tile=Global("const").HeightTileSize;local width,height=map:GetMapSize()
	local report={corrected=0,rejected=0,records={},rejections={}}
	local placed_bounds,pending={},{}
	local start=Global("GetPreciseTicks")()
	for _,entry in ipairs(validator.SeatingEvidence(map)) do
		local obj=entry.obj;local pos=obj:GetVisualPos();local x,y,z=pos:xyz()
		local topup=obj.SuperBigMapDecorEnginePass==true
		local terrain_type=terrain.GetTerrainType(map,point_fn(x,y))
		local function allowed(dx,dy,dz)
			if not topup and (dx~=0 or dy~=0) then return false end
			-- Preserve the existing top-up inner-band and terrain-type rules.
			if topup and (x+dx<width/10.0 or x+dx>=width-width/10.0
				or y+dy<height/10.0 or y+dy>=height-height/10.0
				or terrain.GetTerrainType(map,point_fn(x+dx,y+dy))~=terrain_type) then return false end
			local b=entry.bounds
			local target={b[1]+dx,b[2]+dy,b[3]+dz,b[4]+dx,b[5]+dy,b[6]+dz}
			for _,prior in ipairs(placed_bounds) do
				if target[1]<=prior[4]+2 and target[4]>=prior[1]-2 and target[2]<=prior[5]+2
					and target[5]>=prior[2]-2 and target[3]<=prior[6]+2 and target[6]>=prior[3]-2 then return false end
			end
			return validator.SeatingPlacementClear(map,obj,target)
		end
		local function height_at(px,py)
			if px<0 or py<0 or px>=width or py>=height then return nil end
			return terrain.GetHeight(map,point_fn(px,py))
		end
		local plan,why=Seating.Plan(entry.components,height_at,{tile=5*tile,allow_xy=topup,rings=32,allowed=allowed,
			visible_fraction=topup and 0.5 or 0.05})
		-- Sparse misses and inconclusive geometry never authorize movement.
		if not entry.confirmed then plan=nil;why="separation is unconfirmed" end
		if plan and (plan.dx~=0 or plan.dy~=0 or plan.dz~=0) then
			local old=obj:GetPos()
			local previous_repair=obj.SuperBigMapSupportRepair
			obj:SetPos(point_fn(x+plan.dx,y+plan.dy,z+plan.dz))
			local ax,ay,az=obj:GetPosXYZ()
			if ax~=x+plan.dx or ay~=y+plan.dy or az~=z+plan.dz then
				obj:SetPos(old);report.rejected=report.rejected+1
			else
				validator.RecordSeating(map,obj,{x,y,z},{ax,ay,az})
				report.corrected=report.corrected+1
				report.records[#report.records+1]={entity=obj:GetEntity(),from={x,y,z},to={ax,ay,az},topup=topup,confirmed=entry.confirmed}
				pending[#pending+1]={obj=obj,old=old,repair=previous_repair,row=report.records[#report.records]}
				local b=entry.bounds
				placed_bounds[#placed_bounds+1]={b[1]+plan.dx,b[2]+plan.dy,b[3]+plan.dz,b[4]+plan.dx,b[5]+plan.dy,b[6]+plan.dz}
			end
		else report.rejected=report.rejected+1;report.rejections[#report.rejections+1]={entity=obj:GetEntity(),position={x,y,z},reason=why} end
	end
	if #pending>0 then
		-- Check the actual rendered placement independently of the planner. A
		-- missing/failed check rolls back, including the annotation; never commit a
		-- guessed correction just because SetPos accepted its coordinates.
		local verification=validator.Run("CheckPlacements",map,pending,"surface corrected placement")
		local rolled_back=false
		for _,change in ipairs(pending) do
			local result=change.obj.SuperBigMapSupportValidation
			if not verification or not result or result.current_geometry_status~="valid" or not result.placement_repaired then
				change.obj:SetPos(change.old);change.obj.SuperBigMapSupportRepair=change.repair
				change.row.rolled_back=true;rolled_back=true
				report.corrected=report.corrected-1;report.rejected=report.rejected+1
				report.rejections[#report.rejections+1]={entity=change.obj:GetEntity(),reason="independent rendered-placement verification failed"}
			end
		end
		if rolled_back then validator.Run("CheckPlacements",map,pending,"surface correction rollback") end
	end
	report.ms=Global("GetPreciseTicks")()-start
	map.SuperBigMapDecorationSeating=report
	return report
end

SBM.DecorationSeating=Seating
