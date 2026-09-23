-- Narrow correction service, separate from the read-only support validator.
-- A rigid pose is retained: no mesh edits, scale changes or per-piece sinking.
local SBM=rawget(_G,"SuperBigMap")
local Global=SBM.Engine.Global
local Seating={}
-- These library bindings are immutable primitives, not cached engine state.
-- Avoid the mod sandbox's global fallback for every planner vertex/candidate.
local math,table=math,table
local type,tostring,ipairs,pairs,pcall=type,tostring,ipairs,pairs,pcall

-- Native contacts partition a prefab into rigid support islands. Only roots
-- need terrain contact; the remaining components retain their object supports.
-- This is construction planning, not a diagnostic pass, and never moves objects.
function Seating.PlanSupportIsland(components,height)
	local low,high=-math.huge,math.huge
	local roots=0
	for _,component in ipairs(components) do
		if type(component.visible)~="number" then
			return nil,"support-island geometry unavailable"
		end
		local bottom,top=math.huge,-math.huge
		if component.clearance then
			-- The placement transform can measure these exact extrema while it
			-- already visits EVERY vertex. Retaining millions of transformed XYZ
			-- tables just to revisit them here adds no support evidence.
			bottom,top=component.clearance[1],component.clearance[2]
			if type(bottom)~="number" or type(top)~="number" or not (bottom<=top)
				or bottom<=-math.huge or top>=math.huge then return nil,"support-island geometry unavailable" end
		else
			if not component.vertices or #component.vertices==0 then return nil,"support-island geometry unavailable" end
			for _,p in ipairs(component.vertices) do
				local h=component.flat_height or height(p[1],p[2])
				if type(h)~="number" then return nil,"support-island terrain unavailable" end
				bottom=math.min(bottom,p[3]-h);top=math.max(top,p[3]-h)
			end
		end
		low=math.max(low,component.visible-top)
		if component.terrain then roots=roots+1;high=math.min(high,-bottom) end
	end
	if roots==0 then return nil,"support island has no verified terrain root" end
	if low>math.floor(high) then return nil,"support island cannot retain contact and visibility" end
	local dz=math.floor(math.min(0,high))
	if dz<low then dz=math.ceil(low) end
	return dz
end

-- Pure planner: every component/LOD must contact terrain AND retain visible
-- height. Relocation is explicit and bounded by the caller. Native floating
-- assemblies first try a vertical correction, then a small local rigid search.
-- No geometry is changed by planning.
function Seating.Plan(components,height,options)
	if #components==0 then return nil,"no rendered components" end
	local tile=options.tile
	local visibility={}
	local extrema={}
	for i,component in ipairs(components) do
		local extent=component.height
		if options.retain_existing_visibility and not component.required_visibility then
			local exposed=component.clearance and component.clearance[2] or -math.huge
			for _,p in ipairs(component.clearance and {} or component.vertices) do
				local h=height(p[1],p[2])
				if type(h)~="number" then return nil,"original terrain unavailable" end
				exposed=math.max(exposed,p[3]-h)
			end
			-- A rock's authored foundation may already be buried. Retain the
			-- visible formation rather than demanding that foundation be exposed.
			-- Snapshot this BEFORE searching; a candidate cannot lower its own bar.
			extent=math.min(extent,math.max(0,exposed))
		end
		visibility[i]=component.required_visibility or math.max(2,extent*(options.visible_fraction or 0.5))
		if options.flat_height then
			local b={math.huge,math.huge,math.huge,-math.huge,-math.huge,-math.huge}
			for _,p in ipairs(component.vertices) do
				for axis=1,3 do b[axis]=math.min(b[axis],p[axis]);b[axis+3]=math.max(b[axis+3],p[axis]) end
			end
			extrema[i]=b
		end
	end
	local function candidate(dx,dy)
		local lo,hi=-math.huge,math.huge
		for i,component in ipairs(components) do
			local low,high=math.huge,-math.huge
			if component.clearance and dx==0 and dy==0 then low,high=component.clearance[1],component.clearance[2] end
			local b=extrema[i]
			local flat=low==math.huge and b and options.flat_height(b,dx,dy)
			if type(flat)=="number" and flat>-math.huge and flat<math.huge then low,high=b[3]-flat,b[6]-flat end
			for _,p in ipairs(low~=math.huge and {} or component.vertices) do
				local h=height(p[1]+dx,p[2]+dy)
				if type(h)~="number" then return nil end
				local clearance=p[3]-h
				low=math.min(low,clearance);high=math.max(high,clearance)
			end
			-- Every component keeps its independently measured visible minimum.
			-- Never bury a grounded piece to fix another detached stone.
			local visible=visibility[i]
			lo=math.max(lo,visible-high);hi=math.min(hi,-low)
			if lo>hi then return nil end
		end
		local dz=math.floor(math.min(0,hi))
		if dz<lo then dz=math.ceil(lo) end
		if dz>hi then return nil end
		local proposal={dx=dx,dy=dy,dz=dz}
		if options.allowed and not options.allowed(dx,dy,dz) then return nil,proposal end
		return proposal
	end
	local at_origin,origin_proposal=candidate(0,0)
	if at_origin then return at_origin end
	-- Preserve the terrain-only proposal when collision vetoes it. The rigid
	-- tilt caller used to repeat this entire identical vertex/terrain calculation
	-- without the collision callback just to decide whether to queue an XY search.
	if not options.allow_xy then return nil,"no safe rigid vertical seating",origin_proposal end
	-- Deterministic expanding square rings; the caller explicitly authorizes
	-- relocation and bounds it to the appropriate playable-map neighbourhood.
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

-- On a certified flat search rectangle, translating XY cannot change any
-- component's clearance. Prove an empty rigid-Z interval once instead of
-- repeating identical height queries for every local search point.
function Seating.FlatTranslationImpossible(components,height)
	local low,high=-math.huge,math.huge
	for _,c in ipairs(components) do
		local bottom,top=math.huge,-math.huge
		for _,p in ipairs(c.vertices) do bottom=math.min(bottom,p[3]-height);top=math.max(top,p[3]-height) end
		local exposed=c.clearance and c.clearance[2] or top
		local visible=c.required_visibility or math.max(2,math.min(c.height,math.max(0,exposed))*.5)
		low=math.max(low,visible-top);high=math.min(high,-bottom)
	end
	return math.ceil(low)>math.floor(high)
end

function Seating.MaximumVisibleDrop(components,height)
	local distance=math.huge
	for _,c in ipairs(components) do
		local top=c.clearance and c.clearance[2] or -math.huge
		for _,p in ipairs(c.clearance and {} or c.vertices) do
			local h=height(p[1],p[2]);if type(h)~="number" then return nil end
			top=math.max(top,p[3]-h)
		end
		local visible=c.required_visibility or math.max(2,math.min(c.height,math.max(0,top))*.5)
		distance=math.min(distance,top-visible)
	end
	return distance<math.huge and math.floor(distance) or nil
end

local function RestoreSurface(row,report)
	local errors={};local obj=row.obj
	if row.axis then
		local good,why=pcall(obj.SetAxisAngle,obj,row.axis,row.angle)
		if not good then errors[#errors+1]=tostring(why) end
	end
	local ok,why=pcall(obj.SetPos,obj,row.old)
	if not ok then errors[#errors+1]=tostring(why) end
	obj.SuperBigMapSupportRepair=row.repair
	ok,why=pcall(function()return obj:GetPos()==row.old end)
	if not ok or not why then errors[#errors+1]="restored surface position differs from snapshot" end
	if row.axis and (obj:GetAxis()~=row.axis or obj:GetAngle()~=row.angle) then errors[#errors+1]="restored surface rotation differs from snapshot" end
	row.rolled_back=true;row.row.rolled_back=true
	if #errors>0 then report.error="surface rollback failed: "..table.concat(errors,"; ") end
end

local function RunSurface(map)
	if SBM.Engine.MapDataEnvironment(map.mapdata)~="Surface" then return nil end
	local validator=SBM.DecorationValidation
	if not validator or not validator.SeatingEvidence then return nil end
	local terrain,point_fn=Global("terrain"),Global("point")
	local tile=Global("const").HeightTileSize;local width,height=map:GetMapSize()
	local report={corrected=0,rejected=0,records={},rejections={}}
	map.SuperBigMapDecorationSeating=report
	local pending={}
	local start=Global("GetPreciseTicks")()
	local prepared,prepare_error=pcall(function()
	for _,entry in ipairs(validator.SeatingEvidence(map)) do
		local obj=entry.obj;local pos=obj:GetVisualPos();local x,y,z=pos:xyz()
		local topup=obj.SuperBigMapDecorEnginePass==true
		local terrain_type=terrain.GetTerrainType(map,point_fn(x,y))
		local swept_support_dz,native_relocation,native_rotation
		-- Candidate poses never mutate the world. Reuse only unchanged source
		-- pair proofs and a blocker-order hint until this object's plan is chosen.
		local placement_search={}
		local function allowed(dx,dy,dz)
			-- This entry has already failed the rendered support proof. A zero
			-- displacement from the coarser vertex-height planner cannot fix it;
			-- reject that no-op so face refinement/local search can run instead.
			if dx==0 and dy==0 and dz==0 and not native_rotation then return false end
			if not topup and (dx~=0 or dy~=0) and not native_relocation then return false end
			if native_relocation and (x+dx<0 or y+dy<0 or x+dx>=width or y+dy>=height
				or terrain.GetTerrainType(map,point_fn(x+dx,y+dy))~=terrain_type) then return false end
			-- Preserve the existing top-up inner-band and terrain-type rules.
			if topup and (x+dx<width/10.0 or x+dx>=width-width/10.0
				or y+dy<height/10.0 or y+dy>=height-height/10.0
				or terrain.GetTerrainType(map,point_fn(x+dx,y+dy))~=terrain_type) then return false end
			local b=native_rotation and native_rotation.bounds or entry.bounds
			local target={b[1]+dx,b[2]+dy,b[3]+dz,b[4]+dx,b[5]+dy,b[6]+dz}
			if swept_support_dz and dx==0 and dy==0 and dz==swept_support_dz then return true end
			return validator.SeatingPlacementClear(map,obj,target,native_rotation,placement_search)
		end
		local function height_at(px,py)
			if px<0 or py<0 or px>=width or py>=height then return nil end
			return terrain.GetHeight(map,point_fn(px,py))
		end
		-- Terrain cannot change during this synchronous proposal transaction.
		-- Snapshot the original vertex clearances once: visibility, the initial
		-- vertical proposal and later retries otherwise query those same points.
		-- Exact face refinement may still replace these coarse extrema below.
		for _,component in ipairs(entry.components) do if not component.clearance then
			local low,high=math.huge,-math.huge;local complete=true
			for _,p in ipairs(component.vertices) do
				local h=height_at(p[1],p[2]);if type(h)~="number" then complete=false;break end
				local d=p[3]-h;low=math.min(low,d);high=math.max(high,d)
			end
			if complete and low<=high then component.clearance={low,high} end
		end end
		local function flat_height(b,dx,dy)
			if not validator.SeatingFlatSearchHeight then return nil end
			return validator.SeatingFlatSearchHeight(map,{b[1]+dx,b[2]+dy,b[3],b[4]+dx,b[5]+dy,b[6]},0)
		end
		local plan,why=Seating.Plan(entry.components,height_at,{tile=5*tile,allow_xy=topup,rings=32,allowed=allowed,
			visible_fraction=0.5,retain_existing_visibility=true})
		if not plan and not topup and validator.RefineSeatingComponents and validator.RefineSeatingComponents(map,entry) then
			plan,why=Seating.Plan(entry.components,height_at,{tile=5*tile,allowed=allowed,
				visible_fraction=0.5,retain_existing_visibility=true})
		end
		if not plan and not topup and entry.confirmed and validator.SeatingVerticalContact then
			local terrain_plan=Seating.Plan(entry.components,height_at,{tile=5*tile,
				visible_fraction=0.5,retain_existing_visibility=true})
			local maximum=terrain_plan and -terrain_plan.dz or Seating.MaximumVisibleDrop(entry.components,height_at)
			if maximum and maximum>0 then
				-- The terrain-only plan already proves per-component visibility.
				-- An earlier contact lowers less, preserving that visibility bound.
				swept_support_dz,why=validator.SeatingVerticalContact(map,obj,entry.bounds,maximum)
				if not swept_support_dz and terrain_plan and why=="no rendered support along vertical move" then
					-- Open cliffs do not define a closed containment volume. A complete
					-- rendered-face sweep with no crossing permits the vertical terrain
					-- proposal. Independent positive validation still gates its commit.
					swept_support_dz=terrain_plan.dz
				end
				if swept_support_dz and swept_support_dz>=-maximum and allowed(0,0,swept_support_dz) then
					plan={dx=0,dy=0,dz=swept_support_dz,support="rendered rock"}
				end
			end
		end
		if not plan and not topup and entry.confirmed then
			-- A rigid native assembly can have a floating chip beside a shallowly
			-- buried root: straight lowering would erase the root. The no-floating
			-- rule also covers vanilla gaps. Search only a small local neighbourhood
			-- before accepting a failure; unchanged meshes/scale/orientation, original
			-- visible-height thresholds and exact collision checks still apply.
			native_relocation=true
			local flat=validator.SeatingFlatSearchHeight and validator.SeatingFlatSearchHeight(map,entry.bounds,16*tile)
			if flat==nil or not Seating.FlatTranslationImpossible(entry.components,flat) then
				-- Probe a coarse lattice within the SAME inspected sixteen-tile
				-- neighbourhood first. These are cosmetic repairs, not the entrance
				-- nearest-hex search: any independently verified safe rigid pose is
				-- usable. Narrow pockets still get the complete fine-grid fallback.
				plan,why=Seating.Plan(entry.components,height_at,{tile=4*tile,allow_xy=true,rings=4,allowed=allowed,flat_height=flat_height,
					visible_fraction=0.5,retain_existing_visibility=true})
				if not plan then
					plan,why=Seating.Plan(entry.components,height_at,{tile=tile,allow_xy=true,rings=16,allowed=allowed,flat_height=flat_height,
						visible_fraction=0.5,retain_existing_visibility=true})
				end
			end
			if plan then plan.support="local rigid terrain seating" end
		end
		if not plan and not topup and entry.confirmed and validator.RotationSeatingEvidence then
			native_relocation=false;swept_support_dz=nil
			local relocations={}
			-- Prefer keeping the authored XY. Do not exhaust a thousand local
			-- collision queries at each tiny tilt before trying the next in-place
			-- orientation. Every proposal still uses the identical clearance,
			-- visibility, collision and independent actual-pose support gates.
			for degrees=1,30 do
				for direction=0,7 do
					native_rotation=validator.RotationSeatingEvidence(map,entry,degrees,direction)
					if native_rotation then
						local terrain_proposal
						plan,why,terrain_proposal=Seating.Plan(native_rotation.components,height_at,{tile=tile,allowed=allowed,flat_height=flat_height,
							visible_fraction=0.5,retain_existing_visibility=true})
						if not plan and terrain_proposal then
							relocations[#relocations+1]={degrees,direction}
						end
						if plan then plan.support="local rigid tilted seating";break end
					end
				end
				if plan then break end
			end
			if not plan then for _,choice in ipairs(relocations) do
				native_rotation=validator.RotationSeatingEvidence(map,entry,choice[1],choice[2])
				if native_rotation then
					native_relocation=true
					plan,why=Seating.Plan(native_rotation.components,height_at,{tile=tile/2,allow_xy=true,rings=16,allowed=allowed,flat_height=flat_height,
						visible_fraction=0.5,retain_existing_visibility=true})
					native_relocation=false
					if plan then plan.support="local rigid tilted seating";break end
				end
			end end
			if not plan then native_rotation=nil end
		end
		-- Sparse misses and inconclusive geometry never authorize movement.
		if not entry.confirmed then plan=nil;why="separation is unconfirmed" end
		if plan and (plan.dx~=0 or plan.dy~=0 or plan.dz~=0 or native_rotation) then
			local old=obj:GetPos()
			local previous_repair=obj.SuperBigMapSupportRepair
			local detail={entity=obj:GetEntity(),from={x,y,z},to={x+plan.dx,y+plan.dy,z+plan.dz},topup=topup,confirmed=entry.confirmed,support=plan.support}
			local row={obj=obj,old=old,repair=previous_repair,row=detail}
			if native_rotation then
				row.axis,row.angle=obj:GetAxis(),obj:GetAngle()
				detail.tilt_degrees=native_rotation.degrees
				detail.rotation_from={row.axis:xyz()};detail.rotation_from[4]=row.angle
				detail.rotation_to={native_rotation.axis:xyz()};detail.rotation_to[4]=native_rotation.angle
			end
			pending[#pending+1]=row;report.records[#report.records+1]=detail
			local good,accepted=pcall(function()
				if native_rotation then obj:SetAxisAngle(native_rotation.axis,native_rotation.angle) end
				obj:SetPos(point_fn(table.unpack(detail.to)))
				local ax,ay,az=obj:GetPosXYZ()
				if ax~=detail.to[1] or ay~=detail.to[2] or az~=detail.to[3] then return false end
				if native_rotation then
					detail.native_transform_verified=validator.SeatingRotationMatches
						and validator.SeatingRotationMatches(map,obj,native_rotation,detail.from,detail.to) or false
					if not detail.native_transform_verified then return false end
				end
				if native_rotation or plan.dx~=0 or plan.dy~=0 then
					if not validator.SeatingCurrentPoseClear or not validator.SeatingCurrentPoseClear(map,obj,detail.from) then return false end
				end
				return validator.RecordSeating(map,obj,detail.from,detail.to)==true
			end)
			if not good or not accepted then
				RestoreSurface(row,report);report.rejected=report.rejected+1
				report.rejections[#report.rejections+1]={entity=obj:GetEntity(),reason=good and "correction evidence was refused" or tostring(accepted)}
			else
				report.corrected=report.corrected+1
			end
		else report.rejected=report.rejected+1;report.rejections[#report.rejections+1]={entity=obj:GetEntity(),position={x,y,z},reason=why} end
	end
	end)
	if not prepared then
		for _,row in ipairs(pending) do if not row.rolled_back then
			RestoreSurface(row,report);report.corrected=report.corrected-1;report.rejected=report.rejected+1
		end end
		report.error=(report.error and report.error.."; " or "").."surface correction preparation failed: "..tostring(prepare_error)
		report.ms=Global("GetPreciseTicks")()-start
		return report
	end
	if #pending>0 then
		-- Check the actual rendered placement independently of the planner. A
		-- missing/failed check rolls back, including the annotation; never commit a
		-- guessed correction just because SetPos accepted its coordinates.
		local verify=validator.VerifyCorrection or function(m,p,r)return validator.Run("CheckPlacements",m,p,r)end
		local check_ok,verification=pcall(verify,map,pending,"surface corrected placement")
		local rolled_back=false
		for _,change in ipairs(pending) do
		if not change.rolled_back then
			local result=change.obj.SuperBigMapSupportValidation
			if not check_ok or not verification or verification.error or not result or result.current_geometry_status~="valid" or not result.placement_repaired then
				RestoreSurface(change,report);rolled_back=true
				report.corrected=report.corrected-1;report.rejected=report.rejected+1
				report.rejections[#report.rejections+1]={entity=change.obj:GetEntity(),reason="independent rendered-placement verification failed"}
			end
		end
		end
		if rolled_back then
			local ok,r=pcall(verify,map,pending,"surface correction rollback")
			if not ok or not r or r.error then report.validation_error="rollback diagnostic refresh failed: "..tostring(r) end
		end
	end
	local support,why=validator.SurfaceSupportSummary(map)
	report.support=support
	if not support or support.unresolved>0 then
		report.error=report.error or why or (tostring(support.unresolved).." surface rocks have unresolved support")
	end
	report.ms=Global("GetPreciseTicks")()-start
	map.SuperBigMapDecorationSeating=report
	return report
end

function Seating.Run(map)
	if SBM.Engine.MapDataEnvironment(map.mapdata)~="Surface" then return nil end
	local validator=SBM.DecorationValidation
	if validator and validator.WithCorrectionEvidence then
		return validator.WithCorrectionEvidence(map,"Surface",RunSurface)
	end
	return RunSurface(map)
end

SBM.DecorationSeating=Seating

local function ShapeKey(obj)
	local shape={};for _,p in ipairs(obj:GetShapePoints()) do shape[#shape+1]=tostring(p) end
	return table.concat(shape,";")
end

local function NativeBlockerDescriptor(geometry,obj)
	local native=geometry.Entity(obj:GetEntity(),obj:GetState())
	local actual=geometry.Instance(obj)
	if not native.complete or not actual.complete or #native.parts~=#actual.parts then return false end
	for i,part in ipairs(native.parts) do
		local rendered=actual.parts[i]
		if rendered.lod~=part.lod or rendered.material~=part.material or rendered.mesh.path~=part.mesh.path then return false end
	end
	return true
end

-- Each restore step is attempted even if another native call fails. A failed
-- restore is a visible pipeline error, not an accepted correction or silent skip.
local function RestoreBlocker(row,report)
	local obj=row.obj;local errors={}
	local function attempt(fn)
		local ok,why=pcall(fn);if not ok then errors[#errors+1]=tostring(why) end
	end
	attempt(function()if obj.grids_applied then obj:RemoveFromGrids() end end)
	attempt(function()obj:SetPos(row.old)end)
	attempt(function()obj:SetForcedLOD(row.forced or Global("const").InvalidLODIndex)end)
	obj.SuperBigMapSupportRepair=row.repair
	attempt(function()if row.grids and not obj.grids_applied then obj:ApplyToGrids() end end)
	attempt(function()
		local forced=obj:GetForcedLOD()
		if obj:GetPos()~=row.old or forced~=row.forced or obj.grids_applied~=row.grids
			or obj.remaining_work_to_clear~=row.work or ShapeKey(obj)~=row.shape then
			errors[#errors+1]="restored blocker state differs from transaction snapshot"
		end
	end)
	row.rolled_back=true
	if #errors>0 then report.error="blocker rollback failed: "..table.concat(errors,"; ") end
end

-- The shipped static blocker has two small floor gaps in LOD0 and additional
-- disconnected pieces in LOD1. Keep the untouched native detailed mesh at every
-- distance, seating ONLY this one building by less than half a metre at 133%.
-- No terrain/surface, shared resource, GPU buffer or animated mesh is modified.
local function RunUnderground(map)
	local validator,geometry=SBM.DecorationValidation,SBM.DecorationGeometry
	if SBM.Engine.MapDataEnvironment(map.mapdata)~="Underground" or not validator or not geometry then return nil end
	local report={corrected=0,rejected=0,records={},rejections={},ms=0};local start=Global("GetPreciseTicks")()
	map.SuperBigMapUndergroundDecorationSeating=report
	local read_ok,resource=pcall(geometry.ReadMesh,"Meshes/CaveIn_TunnelBlocker_1_mesh.sub_0.hgrm")
	local mesh=read_ok and resource and resource.geometry
	-- Fail closed on a changed asset. Component indices are not an identity check.
	local expected={-78.83563232421875,-112.61820220947266,-4.167948246002197,71.57398223876953,102.43913269042969,63.287967681884766}
	local signature=mesh and not mesh.animated and mesh.vertex_count==7791 and mesh.index_count==28215 and #mesh.components==99
	if signature then for i=1,6 do if math.abs(mesh.bounds[i]-expected[i])>1e-6 then signature=false end end end
	if not signature then report.reason="native blocker signature not verified";return report end
	local pending={};local surfaces=Global("EntitySurfaces");local rollback=false
	for _,obj in ipairs(map:MapGet("map","TunnelBlockerRubble")) do
		local row
		local ok,why=pcall(function()
		local before=obj.SuperBigMapSupportValidation;local forced=obj:GetForcedLOD()
		if obj:GetEntity()=="CaveIn_TunnelBlocker_1" and not obj:GetParent() and not obj.SuperBigMapSupportRepair
			and before and before.geometry_complete and before.current_geometry_status~="valid"
			and not obj.clear_request and obj.remaining_work_to_clear==obj.required_work_to_clear
			and forced==nil and not obj:GetMirrored() and not obj:GetWarped()
			and obj:GetSkewX()==0 and obj:GetSkewY()==0
			and NativeBlockerDescriptor(geometry,obj)
			and not Global("HasAnySurfaces")(obj,surfaces.Height+surfaces.Terrain+surfaces.TerrainHole,true) then
			local p=obj:GetVisualPos();local x,y,z=p:xyz();local old=obj:GetPos()
			local scale=obj:GetWorldScale()
			local shift=math.ceil(math.max(mesh.components[26].bottom[3],mesh.components[29].bottom[3])*Global("guim")*scale/100.0)
			row={obj=obj,old=old,forced=forced,repair=obj.SuperBigMapSupportRepair,shape=ShapeKey(obj),
				work=obj.remaining_work_to_clear,from={x,y,z},to={x,y,z-shift},grids=obj.grids_applied}
			pending[#pending+1]=row
			if row.grids then obj:RemoveFromGrids() end
			obj:SetPos(Global("point")(x,y,z-shift));obj:SetForcedLOD(0)
			if row.grids then obj:ApplyToGrids() end
			if not validator.RecordRubbleSeating(map,obj,row.from,row.to) then return false,"correction evidence was refused" end
		end
		return true
		end)
		-- pcall's success does not imply an accepted evidence record.
		if not ok or why==false then
			if row then RestoreBlocker(row,report);rollback=true end
			report.rejected=report.rejected+1
			report.rejections[#report.rejections+1]={handle=obj.handle,reason=not ok and tostring(why) or "correction evidence was refused"}
		end
	end
	if #pending>0 then
		local verify=validator.VerifyCorrection or function(m,p,r)return validator.Run("CheckPlacements",m,p,r)end
		local call_ok,verified=pcall(verify,map,pending,"underground detailed rubble seating")
		for _,row in ipairs(pending) do
		if not row.rolled_back then
			local obj=row.obj;local v=obj.SuperBigMapSupportValidation
			local check_ok,good=pcall(function()return call_ok and verified and not verified.error
				and v and v.current_geometry_status=="valid" and v.placement_repaired
				and obj:GetForcedLOD()==0 and obj.remaining_work_to_clear==row.work
				and obj.grids_applied==row.grids and ShapeKey(obj)==row.shape end)
			if check_ok and good then
				report.corrected=report.corrected+1
				report.records[#report.records+1]={handle=obj.handle,entity=obj:GetEntity(),from=row.from,to=row.to,
					forced_lod=0,footprint_unchanged=true,work_unchanged=true}
			else
				RestoreBlocker(row,report)
				report.rejected=report.rejected+1;rollback=true
				report.rejections[#report.rejections+1]={handle=obj.handle,reason="independent rendered-placement verification failed"}
			end
		end
		end
		if rollback then
			local ok,r=pcall(verify,map,pending,"underground rubble seating rollback")
			if not ok or not r or r.error then report.validation_error="rollback diagnostic refresh failed: "..tostring(r) end
		end
	end
	report.ms=Global("GetPreciseTicks")()-start
	return report
end

function Seating.RunUnderground(map)
	if SBM.Engine.MapDataEnvironment(map.mapdata)~="Underground" then return nil end
	local validator=SBM.DecorationValidation
	if validator and validator.WithCorrectionEvidence then
		return validator.WithCorrectionEvidence(map,"Underground",RunUnderground)
	end
	return RunUnderground(map)
end
