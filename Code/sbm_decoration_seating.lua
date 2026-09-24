-- Narrow correction service, separate from the read-only support validator.
-- A rigid pose is retained: no mesh edits, scale changes or per-piece sinking.
local SBM=rawget(_G,"SuperBigMap")
local Global=SBM.Engine.Global
local Seating={}
-- These library bindings are immutable primitives, not cached engine state.
-- Avoid the mod sandbox's global fallback for every planner vertex/candidate.
local math,table=math,table
local type,tostring,ipairs,pairs,pcall=type,tostring,ipairs,pairs,pcall

local offset_cache={}
-- Stable nearest-first lattice. A farther compass point must not win over a
-- nearer diagonal pocket merely because its direction happened to be tried first.
function Seating.NearbyOffsets(step,rings)
	local key=step..":"..rings;local cached=offset_cache[key]
	if cached then return cached end
	-- Order: squared distance, then x, then y (all in lattice units, which
	-- preserves the world-unit order for step>0). Packing that exact order into
	-- one integer key lets the native sort run without a Lua comparator.
	local span=2*rings+1;local keys={}
	for x=-rings,rings do for y=-rings,rings do if x~=0 or y~=0 then
		keys[#keys+1]=((x*x+y*y)*span+(x+rings))*span+(y+rings)
	end end end
	table.sort(keys)
	local result={}
	for i,k in ipairs(keys) do
		local y=k%span;local rest=math.floor((k-y)/span);local x=rest%span
		result[i]={(x-rings)*step,(y-rings)*step}
	end
	offset_cache[key]=result;return result
end

-- Intersect the translations that keep every member in its original sector.
-- Use the actual exploration areas, not a separately inferred grid origin.
function Seating.SectorTranslationLimits(map,members)
	local get=Global("GetMapSectorXY");local city=map.City
	if type(get)~="function" or not city then return nil end
	local limits={-math.huge,-math.huge,math.huge,math.huge}
	for _,member in ipairs(members) do
		local x,y=member.obj:GetVisualPos():xyz()
		local sector=get(city,x,y);local area=sector and sector.area
		if not area then return nil end
		local a,b,c,d=area:minx(),area:miny(),area:maxx(),area:maxy()
		if x<a or y<b or x>=c or y>=d then return nil end
		limits[1]=math.max(limits[1],a-x);limits[2]=math.max(limits[2],b-y)
		limits[3]=math.min(limits[3],c-x);limits[4]=math.min(limits[4],d-y)
	end
	return limits
end

-- Exact extrema with a certified terrain interval. Vertices are ordered by Z;
-- once the remaining Z range cannot improve either extremum, visiting it is
-- redundant. No sampled miss is used as a terrain bound.
function Seating.BoundedClearance(ordered,height,minimum,maximum,dx,dy)
	local low,high=math.huge,-math.huge
	local left,right=1,#ordered
	while left<=right do
		local min_done=ordered[left][3]-maximum>=low
		local max_done=ordered[right][3]-minimum<=high
		if min_done and max_done then break end
		local p
		if not min_done then p=ordered[left];left=left+1 else p=ordered[right];right=right-1 end
		local h=height(p[1]+dx,p[2]+dy);if type(h)~="number" then return nil end
		local d=p[3]-h;if d<low then low=d end;if d>high then high=d end
		if left<=right and not max_done then
			p=ordered[right];right=right-1
			h=height(p[1]+dx,p[2]+dy);if type(h)~="number" then return nil end
			d=p[3]-h;if d<low then low=d end;if d>high then high=d end
		end
	end
	return low,high
end

-- Scope this cache to one immutable-terrain planning transaction. Local and
-- wider candidate lattices overlap; neither an exact result nor a disproved
-- visibility budget needs tracing twice. A larger budget must retry a rejection.
function Seating.CachedFoundationClearance(cache,foundation,dx,dy,height,budget)
	local rows=cache[foundation];if not rows then rows={};cache[foundation]=rows end
	local column=rows[dx];if not column then column={};rows[dx]=column end
	local saved=column[dy]
	if saved then
		if saved.gap then return saved.gap<=budget and saved.gap or nil end
		if budget<=saved.rejected_budget then return nil end
	end
	local gap=SBM.DecorationGeometry.FoundationTranslationClearance(foundation,dx,dy,height,budget)
	column[dy]=gap and {gap=gap} or {rejected_budget=budget}
	return gap
end

-- Small fragments may disappear into the terrain, but never the main shape.
-- Compare geometric size per LOD: alternative views must not inflate the
-- allowance. A fragment is at most fifteen percent of the dominant component;
-- all buried fragments together are at most fifteen percent of the formation.
-- The dominant shape therefore never qualifies, even in a multi-piece mesh.
function Seating.MarkSmallFragments(components)
	local groups,owners={},{}
	for _,c in ipairs(components) do
		c.allow_burial=nil
		local owner=c.burial_owner or false;local bucket=owners[owner] or {};owners[owner]=bucket
		local lod=c.lod or 0;local g=bucket[lod]
		if not g then g={total=0,largest=0,complete=true,parts={}};bucket[lod]=g;groups[#groups+1]=g end
		g.parts[#g.parts+1]=c
		local v=c.volume
		if type(v)~="number" or not (v>0 and v<math.huge) then g.complete=false
		else g.total=g.total+v;g.largest=math.max(g.largest,v) end
	end
	for _,g in pairs(groups) do if g.complete then
		local small=0
		for _,c in ipairs(g.parts) do if c.volume<=g.largest*.15 then small=small+c.volume end end
		if small<=g.total*.15 then
			for _,c in ipairs(g.parts) do if c.volume<=g.largest*.15 then c.allow_burial=true end end
		end
	end end
end

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
			if not component.clearance then for _,p in ipairs(component.vertices) do
				local h=height(p[1],p[2])
				if type(h)~="number" then return nil,"original terrain unavailable" end
				exposed=math.max(exposed,p[3]-h)
			end end
			-- A rock's authored foundation may already be buried. Retain the
			-- visible formation rather than demanding that foundation be exposed.
			-- Snapshot this BEFORE searching; a candidate cannot lower its own bar.
			extent=math.min(extent,math.max(0,exposed))
		end
		visibility[i]=component.allow_burial and -math.huge
			or component.required_visibility or math.max(2,extent*(options.visible_fraction or 0.5))
	end
	local function candidate(dx,dy)
		if options.position_allowed and not options.position_allowed(dx,dy) then return nil end
		local lo,hi=-math.huge,math.huge
		for i,component in ipairs(components) do
			local low,high=math.huge,-math.huge
			local flat_terrain
			if component.clearance and dx==0 and dy==0 then low,high=component.clearance[1],component.clearance[2] end
			if low==math.huge and options.clearance then
				local a,b,flat=options.clearance(component,dx,dy)
				if a~=nil then low,high,flat_terrain=a,b,flat end
			end
			local b=extrema[i]
			-- The exact clearance callback usually answered already. Only build
			-- another full vertex bounding box if its flat-height fallback is needed.
			if low==math.huge and options.flat_height and not b then
				b={math.huge,math.huge,math.huge,-math.huge,-math.huge,-math.huge}
				for _,p in ipairs(component.vertices) do for axis=1,3 do
					if p[axis]<b[axis] then b[axis]=p[axis] end
					if p[axis]>b[axis+3] then b[axis+3]=p[axis] end
				end end
				extrema[i]=b
			end
			local flat=low==math.huge and b and options.flat_height(b,dx,dy)
			if type(flat)=="number" and flat>-math.huge and flat<math.huge then low,high,flat_terrain=b[3]-flat,b[6]-flat,flat end
			if low==math.huge then for _,p in ipairs(component.vertices) do
				local h=height(p[1]+dx,p[2]+dy)
				if type(h)~="number" then return nil end
				local clearance=p[3]-h
				if clearance<low then low=clearance end;if clearance>high then high=clearance end
			end end
			-- Main components retain their independently measured visible minimum.
			-- Only explicitly size-qualified small fragments may become buried.
			local visible=visibility[i]
			lo=math.max(lo,visible-high)
			if component.terrain_root~=false then hi=math.min(hi,-low) end
			local foundation=component.foundation
			if foundation then
				local gap=foundation.gap
				if dx~=0 or dy~=0 then
					if type(flat_terrain)=="number" and foundation.maximum_z then
						gap=foundation.maximum_z-flat_terrain
					elseif options.foundation_cache then
						gap=Seating.CachedFoundationClearance(options.foundation_cache,foundation,dx,dy,height,-lo-2)
					else gap=SBM.DecorationGeometry.FoundationTranslationClearance(foundation,dx,dy,height,-lo-2) end
				end
				if not gap then return nil end
				-- Cover the entire open bottom edge, not just the first point that
				-- touches ground. Retain a tiny integer/affine rounding margin.
				hi=math.min(hi,-gap-2)
			end
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
	if options.offsets then
		for _,offset in ipairs(options.offsets) do
			local found=candidate(offset[1],offset[2]);if found then return found end
		end
		return nil,"no safe bounded foundation seating"
	end
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
		local visible=c.allow_burial and -math.huge or c.required_visibility or math.max(2,math.min(c.height,math.max(0,exposed))*.5)
		low=math.max(low,visible-top);high=math.min(high,-bottom)
	end
	return math.ceil(low)>math.floor(high)
end

function Seating.MaximumVisibleDrop(components,height)
	local distance=math.huge
	for _,c in ipairs(components) do
		local top=c.clearance and c.clearance[2] or -math.huge
		if not c.clearance then for _,p in ipairs(c.vertices) do
			local h=height(p[1],p[2]);if type(h)~="number" then return nil end
			top=math.max(top,p[3]-h)
		end end
		local visible=c.allow_burial and -math.huge or c.required_visibility or math.max(2,math.min(c.height,math.max(0,top))*.5)
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
	local validator=SBM.DecorationValidation
	if validator.CancelSeating then validator.CancelSeating(row.map,obj) end
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
	-- Members already committed with an earlier rigid group keep that shared
	-- pose; their own stale evidence entry must not move them a second time.
	local group_moved={}
	local start=Global("GetPreciseTicks")()
	local prepared,prepare_error=pcall(function()
	for _,candidate in ipairs(validator.SeatingEvidence(map)) do if not group_moved[candidate.obj] then
		local entry=candidate
		if entry.foundation and validator.SeatingGroup then entry=validator.SeatingGroup(map,entry) or entry end
		Seating.MarkSmallFragments(entry.components)
		local obj=entry.obj;local pos=obj:GetVisualPos();local x,y,z=pos:xyz()
		local topup=obj.SuperBigMapDecorEnginePass==true
		local terrain_type=terrain.GetTerrainType(map,point_fn(x,y))
		local sector_limits=Seating.SectorTranslationLimits(map,entry.members or {{obj=obj}})
		local member_terrain={}
		for _,member in ipairs(entry.members or {}) do
			local mx,my=member.obj:GetVisualPos():xyz()
			member_terrain[#member_terrain+1]={mx,my,terrain.GetTerrainType(map,point_fn(mx,my))}
		end
		local function same_sector(dx,dy)
			if dx==0 and dy==0 then return true end
			return sector_limits and dx>=sector_limits[1] and dy>=sector_limits[2]
				and dx<sector_limits[3] and dy<sector_limits[4]
		end
		local function matching_site(dx,dy)
			if not same_sector(dx,dy) or x+dx<0 or y+dy<0 or x+dx>=width or y+dy>=height
				or terrain.GetTerrainType(map,point_fn(x+dx,y+dy))~=terrain_type then return false end
			for _,m in ipairs(member_terrain) do
				if terrain.GetTerrainType(map,point_fn(m[1]+dx,m[2]+dy))~=m[3] then return false end
			end
			return true
		end
		local swept_support_dz,native_relocation
		-- Candidate poses never mutate the world. Reuse only unchanged source
		-- pair proofs and a blocker-order hint until this object's plan is chosen.
		local placement_search={group_members=entry.group_members,member_search={}}
		local function allowed(dx,dy,dz)
			-- This entry has already failed the rendered support proof. A zero
			-- displacement from the coarser vertex-height planner cannot fix it;
			-- reject that no-op so face refinement/local search can run instead.
			if dx==0 and dy==0 and dz==0 then return false end
			if not matching_site(dx,dy) then return false end
			if not topup and (dx~=0 or dy~=0) and not native_relocation then return false end
			if native_relocation and (x+dx<0 or y+dy<0 or x+dx>=width or y+dy>=height
				or terrain.GetTerrainType(map,point_fn(x+dx,y+dy))~=terrain_type) then return false end
			-- Preserve the existing top-up inner-band and terrain-type rules.
			if topup and (x+dx<width/10.0 or x+dx>=width-width/10.0
				or y+dy<height/10.0 or y+dy>=height-height/10.0
				or terrain.GetTerrainType(map,point_fn(x+dx,y+dy))~=terrain_type) then return false end
			local b=entry.bounds
			local target={b[1]+dx,b[2]+dy,b[3]+dz,b[4]+dx,b[5]+dy,b[6]+dz}
			if swept_support_dz and dx==0 and dy==0 and dz==swept_support_dz then return true end
			if not validator.SeatingPlacementClear(map,obj,target,nil,placement_search) then return false end
			for i,member in ipairs(entry.members or {}) do if i>1 then
				local b=member.bounds;local t={b[1]+dx,b[2]+dy,b[3]+dz,b[4]+dx,b[5]+dy,b[6]+dz}
				local search=placement_search.member_search[member.obj] or {group_members=entry.group_members}
				placement_search.member_search[member.obj]=search
				if not validator.SeatingPlacementClear(map,member.obj,t,nil,search) then return false end
			end end
			return true
		end
		local height_cache=entry.foundation and {}
		local linear_heights=height_cache and width>0 and height>0 and width<=67108864 and height<=67108864
			and width%1==0 and height%1==0
		local height_rows=height_cache and (linear_heights and {} or height_cache)
		local function height_at(px,py)
			if px<0 or py<0 or px>=width or py>=height then return nil end
			-- Foundation edge proofs repeatedly request integer terrain corners.
			-- A cache hit needs no native point allocation/coordinate conversion.
			if linear_heights and px%1==0 and py%1==0 then
				local cached=height_cache[px+py*width];if cached~=nil then return cached end
			elseif height_rows then
				local col=height_rows[px]
				if col and col[py]~=nil then return col[py] end
			end
			local p=point_fn(px,py)
			if not height_cache then return terrain.GetHeight(map,p) end
			local ix,iy=p:xy()
			-- The engine point remains authoritative for fractional-coordinate
			-- rounding. In-range integer coordinates have an exact key below2^52;
			-- avoid one Lua table per distinct X during the large candidate search.
			-- A rounded edge coordinate outside the map uses separate row storage
			-- so x==width can never alias x==0 on the next row.
			if linear_heights and ix>=0 and iy>=0 and ix<width and iy<height then
				local key=ix+iy*width;local value=height_cache[key]
				if value==nil then value=terrain.GetHeight(map,p);height_cache[key]=value end
				return value
			end
			local col=height_rows[ix]
			if not col then col={};height_rows[ix]=col end
			if col[iy]==nil then col[iy]=terrain.GetHeight(map,p) end
			return col[iy]
		end
		local function flat_height(b,dx,dy)
			if not validator.SeatingFlatSearchHeight then return nil end
			return validator.SeatingFlatSearchHeight(map,{b[1]+dx,b[2]+dy,b[3],b[4]+dx,b[5]+dy,b[6]},0)
		end
		local clearance_cache,foundation_cache={},{}
		local function bounded_clearance(component,dx,dy)
			if type(terrain.GetMinMaxHeight)~="function" then return nil end
			-- Local and wider searches overlap. Their geometry and destination
			-- terrain are unchanged until this entry's plan commits; reuse the
			-- exact extrema, not a sampled estimate or a placement acceptance.
			local cache=clearance_cache[component]
			if not cache then cache={};clearance_cache[component]=cache end
			local column=cache[dx];if not column then column={};cache[dx]=column end
			local saved=column[dy];if saved then return saved[1],saved[2],saved[3] end
			local ordered=component.height_order;local b=component.height_bounds
			if not ordered then
				ordered={};b={math.huge,math.huge,-math.huge,-math.huge}
				for _,p in ipairs(component.vertices) do
					ordered[#ordered+1]=p;b[1]=math.min(b[1],p[1]);b[2]=math.min(b[2],p[2])
					b[3]=math.max(b[3],p[1]);b[4]=math.max(b[4],p[2])
				end
				table.sort(ordered,function(a,b)return a[3]<b[3] end)
				component.height_order,component.height_bounds=ordered,b
			end
			local a,c=math.floor(b[1]+dx)-tile,math.floor(b[2]+dy)-tile
			local d,e=math.ceil(b[3]+dx)+tile,math.ceil(b[4]+dy)+tile
			if a<0 or c<0 or d>=width or e>=height then return nil end
			local box=Global("box");if type(box)~="function" then return nil end
			local lo,hi=terrain.GetMinMaxHeight(map,box(a,c,d,e))
			if type(lo)~="number" or type(hi)~="number" or not (lo<=hi and lo>-math.huge and hi<math.huge) then return nil end
			local low,high
			if lo==hi and #ordered>0 then
				-- A certified flat enclosing rectangle determines every vertex's
				-- clearance exactly. Re-querying the same level per vertex adds no
				-- evidence; the first/last Z already give both exact extrema.
				low,high=ordered[1][3]-lo,ordered[#ordered][3]-lo
			else
				-- Pad varying native height/coordinate bounds conservatively.
				low,high=Seating.BoundedClearance(ordered,height_at,lo-2,hi+2,dx,dy)
			end
			local flat=lo==hi and lo or nil
			if low~=nil then column[dy]={low,high,flat} end
			return low,high,flat
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
		local plan,why,terrain_proposal=Seating.Plan(entry.components,height_at,{tile=5*tile,allow_xy=topup and not entry.foundation,rings=32,allowed=allowed,
			visible_fraction=0.5,retain_existing_visibility=true})
		-- A collision veto cannot be fixed by recomputing the same terrain-only
		-- vertical proposal. Retain face refinement for actual terrain gaps (and
		-- zero-displacement false contacts), not already feasible rejected poses.
		local needs_refinement=not terrain_proposal or terrain_proposal.dz==0
		if not plan and not topup and not entry.foundation and needs_refinement
			and validator.RefineSeatingComponents and validator.RefineSeatingComponents(map,entry) then
			plan,why=Seating.Plan(entry.components,height_at,{tile=5*tile,allowed=allowed,
				visible_fraction=0.5,retain_existing_visibility=true})
		end
		if not plan and not topup and not entry.foundation and entry.confirmed and validator.SeatingVerticalContact then
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
		if not plan and not topup and not entry.foundation and entry.confirmed then
			-- A rigid native assembly can have a floating chip beside a shallowly
			-- buried root: straight lowering would erase the root. The no-floating
			-- rule also covers vanilla gaps. Search only a small local neighbourhood
			-- before accepting a failure; unchanged meshes/scale/orientation, original
			-- visible-height thresholds and exact collision checks still apply.
			native_relocation=true
			local flat=validator.SeatingFlatSearchHeight and validator.SeatingFlatSearchHeight(map,entry.bounds,16*tile)
			if flat==nil or not Seating.FlatTranslationImpossible(entry.components,flat) then
				plan,why=Seating.Plan(entry.components,height_at,{tile=tile,allow_xy=true,
					offsets=Seating.NearbyOffsets(tile,16),position_allowed=same_sector,allowed=allowed,flat_height=flat_height,clearance=bounded_clearance,
					visible_fraction=0.5,retain_existing_visibility=true})
			end
			if plan then plan.support="local rigid terrain seating" end
		end
		if not plan and entry.foundation and entry.confirmed then
			-- Rigid stacks need the same nearby two-tile search as single rocks.
			-- Jumping straight to the coarser four-tile lattice can miss a safe
			-- pocket only one or two tiles from the original formation.
			native_relocation=not topup
			plan,why=Seating.Plan(entry.components,height_at,{tile=tile,allow_xy=true,offsets=Seating.NearbyOffsets(2*tile,8),allowed=allowed,clearance=bounded_clearance,foundation_cache=foundation_cache,
				position_allowed=function(dx,dy)
					return same_sector(dx,dy) and x+dx>=0 and y+dy>=0 and x+dx<width and y+dy<height
						and terrain.GetTerrainType(map,point_fn(x+dx,y+dy))==terrain_type
				end,visible_fraction=0.5,retain_existing_visibility=true})
			if plan then plan.support="bounded open-base terrain seating" end
		end
		if not plan and entry.confirmed and sector_limits then
			-- Preserve the main shape rather than burying it or changing its
			-- authored tilt. Only confirmed difficult formations reach this search.
			-- Candidates are nearest-first, bounded, and retain every member's
			-- sector, terrain type, visibility and physical-neighbour safeguards.
			native_relocation=not topup
			plan,why=Seating.Plan(entry.components,height_at,{tile=tile,allow_xy=true,
				offsets=Seating.NearbyOffsets(4*tile,32),position_allowed=matching_site,allowed=allowed,clearance=bounded_clearance,foundation_cache=foundation_cache,
				visible_fraction=0.5,retain_existing_visibility=true})
			if not plan and entry.members then
				-- A stack has several independent visibility/terrain constraints.
				-- If the coarse lattice misses their common pocket, fill its gaps
				-- within the SAME radius before declaring that rigid seating fails.
				-- Already measured candidates reuse exact local-transaction evidence.
				plan,why=Seating.Plan(entry.components,height_at,{tile=tile,allow_xy=true,
					offsets=Seating.NearbyOffsets(2*tile,64),position_allowed=matching_site,allowed=allowed,
					clearance=bounded_clearance,foundation_cache=foundation_cache,
					visible_fraction=0.5,retain_existing_visibility=true})
				if not plan then
					plan,why=Seating.Plan(entry.components,height_at,{tile=tile,allow_xy=true,
						offsets=Seating.NearbyOffsets(tile,128),position_allowed=matching_site,allowed=allowed,
						clearance=bounded_clearance,foundation_cache=foundation_cache,
						visible_fraction=0.5,retain_existing_visibility=true})
				end
			end
			if plan then
				-- Refine around the discovered four-tile candidate before committing;
				-- this may reduce movement, never increase it or weaken acceptance.
				local candidates={};local distance=plan.dx*plan.dx+plan.dy*plan.dy
				for dx=-3,3 do for dy=-3,3 do
					local a,b=plan.dx+dx*tile,plan.dy+dy*tile
					if a*a+b*b<distance then candidates[#candidates+1]={a,b} end
				end end
				table.sort(candidates,function(a,b)
					local da,db=a[1]*a[1]+a[2]*a[2],b[1]*b[1]+b[2]*b[2]
					if da~=db then return da<db end
					if a[1]~=b[1] then return a[1]<b[1] end
					return a[2]<b[2]
				end)
				local refined=Seating.Plan(entry.components,height_at,{tile=tile,allow_xy=true,offsets=candidates,
					position_allowed=matching_site,allowed=allowed,clearance=bounded_clearance,foundation_cache=foundation_cache,visible_fraction=0.5,retain_existing_visibility=true})
				plan=refined or plan;plan.support="nearest sampled same-sector terrain seating"
			end
		end
		-- Never change the authored orientation to satisfy a contact witness.
		-- A supported tilted prefab can still look visibly wrong. If the bounded
		-- translation search cannot seat it safely, report the unresolved placement.
		-- Sparse misses and inconclusive geometry never authorize movement.
		if not entry.confirmed then plan=nil;why="separation is unconfirmed" end
		if plan and (plan.dx~=0 or plan.dy~=0 or plan.dz~=0) then
		local transaction={}
		for _,member in ipairs(entry.members or {{obj=obj,foundation=entry.foundation}}) do
			local obj=member.obj;local x,y,z=obj:GetVisualPos():xyz()
			local old=obj:GetPos()
			local previous_repair=obj.SuperBigMapSupportRepair
			local detail={entity=obj:GetEntity(),from={x,y,z},to={x+plan.dx,y+plan.dy,z+plan.dz},topup=obj.SuperBigMapDecorEnginePass==true,confirmed=entry.confirmed,support=plan.support}
			if member.foundation then detail.foundation_seating=true end
			if entry.members then detail.rigid_support_group=true end
			local row={map=map,obj=obj,old=old,repair=previous_repair,row=detail,transaction=transaction}
			transaction[#transaction+1]=row
			if type(obj.GetAxis)=="function" and type(obj.GetAngle)=="function" then
				row.axis,row.angle=obj:GetAxis(),obj:GetAngle()
			end
			pending[#pending+1]=row;report.records[#report.records+1]=detail
			local good,accepted=pcall(function()
				obj:SetPos(point_fn(table.unpack(detail.to)))
				local ax,ay,az=obj:GetPosXYZ()
				if ax~=detail.to[1] or ay~=detail.to[2] or az~=detail.to[3] then return false end
				if row.axis and (obj:GetAxis()~=row.axis or obj:GetAngle()~=row.angle) then return false end
				if plan.dx~=0 or plan.dy~=0 then
					if not validator.SeatingCurrentPoseClear or not validator.SeatingCurrentPoseClear(map,obj,detail.from,
						entry.group_members and {group_members=entry.group_members}) then return false end
				end
				return validator.RecordSeating(map,obj,detail.from,detail.to)==true
			end)
			if not good or not accepted then
				RestoreSurface(row,report);report.rejected=report.rejected+1
				report.rejections[#report.rejections+1]={entity=obj:GetEntity(),reason=good and "correction evidence was refused" or tostring(accepted)}
				for _,previous in ipairs(transaction) do if not previous.rolled_back then
					RestoreSurface(previous,report);report.corrected=report.corrected-1;report.rejected=report.rejected+1
				end end
				break
			else
				report.corrected=report.corrected+1
			end
		end
		if entry.members then
			for _,row in ipairs(transaction) do if not row.rolled_back then group_moved[row.obj]=true end end
		end
		else report.rejected=report.rejected+1;report.rejections[#report.rejections+1]={entity=obj:GetEntity(),position={x,y,z},reason=why} end
	end end
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
		local rolled_back=false;local failed_transactions={}
		for _,change in ipairs(pending) do
		if not change.rolled_back then
			local result=change.obj.SuperBigMapSupportValidation
			if not check_ok or not verification or verification.error or not result or result.current_geometry_status~="valid"
				or result.foundation_unresolved or not result.placement_repaired then
				failed_transactions[change.transaction]=true
			end
		end
		end
		for _,change in ipairs(pending) do
			if not change.rolled_back and failed_transactions[change.transaction] then
				RestoreSurface(change,report);rolled_back=true
				report.corrected=report.corrected-1;report.rejected=report.rejected+1
				report.rejections[#report.rejections+1]={entity=change.obj:GetEntity(),reason="independent rendered-placement verification failed"}
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
