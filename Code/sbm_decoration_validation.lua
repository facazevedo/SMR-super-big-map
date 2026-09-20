-- Diagnostic only: this module never moves objects, changes terrain or replaces
-- rendering. Positive contact witnesses and complete geometry coverage are separate.
local SBM = rawget(_G, "SuperBigMap")
local Global, Geometry = SBM.Engine.Global, SBM.DecorationGeometry
local Validator = {}
local contexts = setmetatable({}, {__mode="k"})
local loaded_maps = setmetatable({}, {__mode="k"})
local abs, min, max, floor = math.abs, math.min, math.max, math.floor
-- Standard library lookups through the mod sandbox's __index were a measured
-- hotspot. These immutable primitives can be bound once without caching any
-- mutable engine state or weakening instance checks.
local type,tostring,pairs,ipairs,pcall=type,tostring,pairs,ipairs,pcall
local concat,format=table.concat,string.format
local math=math
local native_point,native_valid=Global("point"),Global("IsValid")
do
	local register,registry=Global("MapVar"),Global("MapVarValues")
	for _,name in ipairs({"SuperBigMapDecorationBaselines","SuperBigMapSupportIdSequence"}) do
		if type(register)=="function" and (type(registry)~="table" or registry[name]==nil) then register(name,false) end
	end
end

local function Overlap(a,b,pad)
	for i=1,3 do if a[i]>b[i+3]+pad or b[i]>a[i+3]+pad then return false end end
	return true
end

-- Spatial buckets include the complete AABB, not just an object's pivot. Large
-- formations use a separate small list rather than millions of bucket entries.
function Validator.Index(size)
	local index={size=size,buckets={},large={}}
	function index:Add(node)
		local b=node.bounds
		local x0,y0,x1,y1=floor(b[1]/(size+0.0)),floor(b[2]/(size+0.0)),floor(b[4]/(size+0.0)),floor(b[5]/(size+0.0))
		if (x1-x0+1)*(y1-y0+1)>256 then self.large[#self.large+1]=node;return end
		for x=x0,x1 do for y=y0,y1 do
			local key=x..":"..y;local bucket=self.buckets[key]
			if not bucket then bucket={};self.buckets[key]=bucket end
			bucket[#bucket+1]=node
		end end
	end
	function index:Query(bounds,pad)
		local out,seen={},{}
		local function take(node)
			if not seen[node] and Overlap(node.bounds,bounds,pad) then seen[node]=true;out[#out+1]=node end
		end
		for x=floor((bounds[1]-pad)/(size+0.0)),floor((bounds[4]+pad)/(size+0.0)) do
			for y=floor((bounds[2]-pad)/(size+0.0)),floor((bounds[5]+pad)/(size+0.0)) do
				for _,node in ipairs(self.buckets[x..":"..y] or {}) do take(node) end
			end
		end
		for _,node in ipairs(self.large) do take(node) end
		return out
	end
	return index
end

local function Dot(a,b)return a[1]*b[1]+a[2]*b[2]+a[3]*b[3]end
local function SegmentDistanceSquared(px,py,pz,ax,ay,az,bx,by,bz)
	local x,y,z=bx-ax,by-ay,bz-az
	local qx,qy,qz=px-ax,py-ay,pz-az
	local d=x*x+y*y+z*z
	local t=d>0 and max(0,min(1,(qx*x+qy*y+qz*z)/(d+0.0))) or 0
	qx,qy,qz=qx-t*x,qy-t*y,qz-t*z
	return qx*qx+qy*qy+qz*qz
end

function Validator.TriangleDistanceSquared(p,a,b,c)
	-- Same predicate and operation order, without allocating vectors for every
	-- candidate triangle. Shared geometry and per-instance coverage are unchanged.
	local px,py,pz=p[1],p[2],p[3]
	local ax,ay,az=a[1],a[2],a[3]
	local bx,by,bz=b[1],b[2],b[3]
	local cx,cy,cz=c[1],c[2],c[3]
	local x,y,z=bx-ax,by-ay,bz-az
	local u,v,w=cx-ax,cy-ay,cz-az
	local qx,qy,qz=px-ax,py-ay,pz-az
	local aa,bb,cc=x*x+y*y+z*z,x*u+y*v+z*w,u*u+v*v+w*w
	local pa,pc=qx*x+qy*y+qz*z,qx*u+qy*v+qz*w
	local det=aa*cc-bb*bb
	if det>1e-18 then
		local s,t=(pa*cc-pc*bb)/(det+0.0),(pc*aa-pa*bb)/(det+0.0)
		if s>=0 and t>=0 and s+t<=1 then
			qx,qy,qz=qx-s*x-t*u,qy-s*y-t*v,qz-s*z-t*w
			return qx*qx+qy*qy+qz*qz
		end
	end
	return min(SegmentDistanceSquared(px,py,pz,ax,ay,az,bx,by,bz),
		SegmentDistanceSquared(px,py,pz,bx,by,bz,cx,cy,cz),SegmentDistanceSquared(px,py,pz,cx,cy,cz,ax,ay,az))
end

function Validator.Classify(nodes,complete,attachment_changed)
	if attachment_changed then return "confirmed defect","native attachment changed" end
	local pending=false
	for _,n in ipairs(nodes) do
		if n.defect then return "confirmed defect",n.reason end
		if not n.supported then pending=true end
	end
	if not complete or #nodes==0 or pending then return "inconclusive","geometry or support coverage incomplete" end
	return "valid","all inspected rendered components have support witnesses"
end

local function Enabled()return (SBM.Config or {}).DECORATION_VALIDATION_ENABLED~=false end
local function Tick()return Global("GetPreciseTicks")()end
local last_yield=0
local function YieldBatch(i,context)
	-- Generation holds native pass-edit transactions. Do not let queued engine
	-- work observe their half-transformed objects by yielding inside that pass.
	if not context or not context.allow_yield then return end
	if i%128~=0 then return end
	local now=Tick();if now-last_yield<40 then return end
	local can_yield,sleep=Global("CanYield"),Global("Sleep")
	if type(can_yield)=="function" and can_yield() and type(sleep)=="function" then sleep(1);last_yield=Tick() end
end
local function IsValid(obj)return obj and (native_valid or Global("IsValid"))(obj)end
local function Point(p)return (native_point or Global("point"))(floor(p[1]+0.5),floor(p[2]+0.5),floor(p[3]+0.5))end
local function XYZ(p)local x,y,z=p:xyz();return {x,y,z}end
local function BoxBounds(b)return {b:minx(),b:miny(),b:minz(),b:maxx(),b:maxy(),b:maxz()}end
local function Identity(map,obj)
	if not obj then return false end
	if type(obj.handle)=="number" then return "h"..obj.handle end
	-- Plain cosmetic CObjects often have no engine handle. Give them a persisted,
	-- map-local diagnostic identity; nil must never merge unrelated supports.
	if not obj.SuperBigMapSupportId then
		map.SuperBigMapSupportIdSequence=(map.SuperBigMapSupportIdSequence or 0)+1
		obj.SuperBigMapSupportId=map.SuperBigMapSupportIdSequence
	end
	return "d"..obj.SuperBigMapSupportId
end

local function PersistedPoseKey(obj)
	local pos=obj:GetPos();local x,y,z=pos:xyz()
	local parent=obj:GetParent()
	local px,py,pz
	if parent then px,py,pz=parent:GetPos():xyz() end
	return concat({tostring(obj.class),obj:GetEntity(),tostring(x),tostring(y),tostring(z),
		tostring(obj:GetWorldScale()),tostring(type(obj.GetAngle)=="function" and obj:GetAngle()),
		tostring(type(obj.GetAxis)=="function" and obj:GetAxis()),tostring(obj:GetState()),
		tostring(parent and parent:GetEntity()),tostring(px),tostring(py),tostring(pz)},"|")
end

local function RestoreBaseline(map,obj)
	local ledger=map.SuperBigMapDecorationBaselines
	local entry=type(ledger)=="table" and ledger.records and ledger.records[PersistedPoseKey(obj)]
	if entry and not entry.ambiguous then
		if not obj.SuperBigMapSupportId then obj.SuperBigMapSupportId=entry.id end
		if not obj.SuperBigMapSupportBaseline then obj.SuperBigMapSupportBaseline=entry.baseline end
		if not obj.SuperBigMapSupportRepair then obj.SuperBigMapSupportRepair=entry.repair end
	end
end

local function PersistBaselines(context)
	-- Some permanent surface decorations lose arbitrary Lua fields when their
	-- inactive map is serialized. A value-only MapVar ledger restores only exact,
	-- unique placements. Ambiguity/missing keys remain inconclusive, never guessed.
	local ledger={version=1,records={}}
	for _,record in ipairs(context.list) do
		local obj=record.obj
		if IsValid(obj) and (obj.SuperBigMapSupportBaseline or obj.SuperBigMapSupportId) then
			local key=context.selection and not context.selection[record] and record.persisted_key or PersistedPoseKey(obj)
			record.persisted_key=key
			if ledger.records[key] then ledger.records[key]={ambiguous=true}
			else ledger.records[key]={id=obj.SuperBigMapSupportId,baseline=obj.SuperBigMapSupportBaseline,repair=obj.SuperBigMapSupportRepair} end
		end
	end
	context.map.SuperBigMapDecorationBaselines=ledger
end

local function Relevant(obj,skip,important)
	if obj.class=="CaveInRubble" or obj.class=="TunnelBlockerRubble" then return true end
	local kind=Global("IsKindOf")
	if type(kind)=="function" and kind(obj,"UndergroundWonder") then return true end
	-- Authoring markers deliberately have non-grounded placeholder entities, but
	-- vanilla never renders them during gameplay. They are not decorative rocks.
	if type(kind)=="function" and kind(obj,"EditorVisibleObject") then return false end
	if not SBM.ObjectClone.ObjectScalesWithTerrain(obj) then return false end
	local data=Global("EntityData")[obj:GetEntity()]
	if data and data.editor_category=="StonesRocksCliffs" then return true end
	return not skip and not important
end

local function Projected(obj)
	local kind=Global("IsKindOf")
	return type(kind)=="function" and kind(obj,"Decal") or false
end

local function Pose(obj,source_map)
	local origin=XYZ(obj:GetVisualPos());local shift={0,0,0}
	if source_map then
		local root=obj
		while root:GetParent() do root=root:GetParent() end
		if not root:IsValidZ() then
			local pos=root:GetPos();shift[3]=Global("terrain").GetHeight(source_map,pos)-root:GetVisualPos():z()
		end
	end
	return {origin=origin,shift=shift,scale=obj:GetWorldScale(),parent=obj:GetParent()}
end

local function Matrix(record)
	local pose=record.pose
	if pose.matrix then return pose.matrix end
	local unit=Global("guim");local extent=100*unit
	local origin=XYZ(record.obj:GetRelativePoint(Point({0,0,0})))
	local columns={}
	for a=1,3 do
		local local_point={0,0,0};local_point[a]=extent
		local p=XYZ(record.obj:GetRelativePoint(Point(local_point)))
		columns[a]={(p[1]-origin[1])/100.0,(p[2]-origin[2])/100.0,(p[3]-origin[3])/100.0}
	end
	pose.matrix={origin=origin,columns=columns};return pose.matrix
end

local function World(record,p)
	local m=Matrix(record);local q={}
	for a=1,3 do q[a]=m.origin[a]+record.pose.shift[a]+m.columns[1][a]*p[1]+m.columns[2][a]*p[2]+m.columns[3][a]*p[3] end
	return q
end

local function Local(record,p)
	local m=Matrix(record);local c=m.columns
	local q={p[1]-m.origin[1]-record.pose.shift[1],p[2]-m.origin[2]-record.pose.shift[2],p[3]-m.origin[3]-record.pose.shift[3]}
	-- Rigid engine transforms have orthogonal columns and one uniform scale.
	return {Dot(q,c[1])/(Dot(c[1],c[1])+0.0),Dot(q,c[2])/(Dot(c[2],c[2])+0.0),Dot(q,c[3])/(Dot(c[3],c[3])+0.0)}
end

local function WorldBounds(record,b)
	local m=Matrix(record);local c=m.columns
	local x,y,z=(b[1]+b[4])*0.5,(b[2]+b[5])*0.5,(b[3]+b[6])*0.5
	local hx,hy,hz=(b[4]-b[1])*0.5,(b[5]-b[2])*0.5,(b[6]-b[3])*0.5
	local result={}
	for a=1,3 do
		local center=m.origin[a]+record.pose.shift[a]+c[1][a]*x+c[2][a]*y+c[3][a]*z
		local extent=abs(c[1][a])*hx+abs(c[2][a])*hy+abs(c[3][a])*hz
		result[a],result[a+3]=center-extent,center+extent
	end
	return result
end

local function EntirelyClipped(obj,b)
	local plane=obj:GetClipPlane()
	if plane==0 then return false,false end
	local decode=Global("DecodePlane")
	if type(decode)~="function" then return false,true end
	local norm,base,local_space=decode(plane)
	if not local_space then return false,true end
	local n,p=XYZ(norm),XYZ(base);local unit=Global("guim")
	local negative,positive=false,false
	for x=0,1 do for y=0,1 do for z=0,1 do
		local d=n[1]*(b[1+x*3]*unit-p[1])+n[2]*(b[2+y*3]*unit-p[2])+n[3]*(b[3+z*3]*unit-p[3])
		if d<0 then negative=true else positive=true end
	end end end
	return negative and not positive,negative and positive
end

local function BuildNodes(record)
	local obj=record.obj;local asset=Geometry.Instance(obj)
	record.asset=asset;record.complete=asset.complete;record.nodes={};record.reason=asset.reason
	record.projected=Projected(obj)
	if record.projected then
		-- A decal mesh is a projection volume, not the rendered surface. It cannot
		-- prove floating geometry or act as solid support for another decoration.
		record.complete=false;record.reason="projected decal coverage requires a separate decoder";return
	end
	-- World-space warping needs its own shader-specific decoder. Never approve it
	-- using the unwarped CPU vertices.
	if (type(obj.GetSkewX)=="function" and obj:GetSkewX()~=0)
		or (type(obj.GetSkewY)=="function" and obj:GetSkewY()~=0)
		or (type(obj.GetWarped)=="function" and obj:GetWarped())
		or (type(obj.GetMirrored)=="function" and obj:GetMirrored()) then
		record.complete=false;record.reason="non-rigid rendering transform";return
	end
	if type(obj.GetTerrainDistortedSupport)~="function" then
		record.complete=false;record.reason="terrain-distortion metadata unavailable";return
	end
	local distorted=obj:GetTerrainDistortedSupport()
	if distorted~=false and distorted~="disabled" then
		record.complete=false;record.reason="terrain-distorted rendering requires a separate decoder";return
	end
	if asset.animated then
		local state_idx,duration=Global("GetStateIdx"),Global("GetAnimDuration")
		local settled=type(state_idx)=="function" and type(duration)=="function" and type(obj.GetAnimPhase)=="function"
			and (obj:GetState()==state_idx("idle") or (obj:GetState()==state_idx("falling")
			and obj:GetAnimPhase(1)>=duration(obj:GetEntity(),obj:GetState())-1))
		if not settled then record.complete=false;record.reason="animated pose is moving or unverifiable";return end
	end
	for part_index,part in ipairs(asset.parts) do
		local geometry=part.mesh.geometry
		if geometry and (not geometry.animated or geometry.rigid_skin) and part.material_complete~=false then
			local transforms={}
			for component_index,component in ipairs(geometry.components) do
				local transform=record
				if geometry.animated then
					transform=transforms[component.bone]
					if transform==nil then
						local matrix,why=Geometry.BoneMatrix(obj,geometry,component.bone)
						transform=matrix and {obj=obj,pose={matrix=matrix,shift=record.pose.shift,scale=math.sqrt(Dot(matrix.columns[1],matrix.columns[1]))/Global("guim")*100}} or false
						transforms[component.bone]=transform
						if not transform then record.complete=false;record.reason=why end
					end
				end
				local clip_bounds=component.bounds
				if transform and geometry.animated and obj:GetClipPlane()~=0 then
					clip_bounds=Geometry.Bounds()
					for x=0,1 do for y=0,1 do for z=0,1 do
						local b=component.bounds
						Geometry.Extend(clip_bounds,Local(record,World(transform,{b[1+x*3],b[2+y*3],b[3+z*3]})))
					end end end
				end
				local clipped,partial=EntirelyClipped(obj,clip_bounds)
				if transform and not clipped then
					local bottom=component.bottom or component.samples[1]
					local unit=Global("guim")
					if not component.bottom_point then component.bottom_point=Point({bottom[1]*unit,bottom[2]*unit,bottom[3]*unit}) end
					local sample
					if geometry.animated then sample=World(transform,bottom)
					else sample=XYZ(obj:GetRelativePoint(component.bottom_point));sample[3]=sample[3]+record.pose.shift[3] end
					local node={record=record,transform_record=transform,geometry=geometry,component=component,lod=part.lod,
						key=part.lod..":"..part.mesh.path..":"..component_index,
						samples={sample},edges={},contacts={},partial=partial}
					record.nodes[#record.nodes+1]=node
					if partial then record.complete=false end
				end
			end
		end
	end
end

local function MeshContact(node,world,tolerance)
	local transform=node.transform_record or node.record
	local p=Local(transform,world)
	local local_tolerance=tolerance*100.0/max(1,transform.pose.scale)/Global("guim")
	local b=node.component.bounds
	for a=1,3 do if p[a]<b[a]-local_tolerance or p[a]>b[a+3]+local_tolerance then return false end end
	local verts=node.geometry.vertices;local limit=local_tolerance*local_tolerance
	local function visit(tree)
		local bounds=tree.bounds
		for a=1,3 do if p[a]<bounds[a]-local_tolerance or p[a]>bounds[a+3]+local_tolerance then return false end end
		if tree.items then
			for _,item in ipairs(tree.items) do
				local t=item.triangle
				if Validator.TriangleDistanceSquared(p,verts[t[1]],verts[t[2]],verts[t[3]])<=limit then return true end
			end
			return false
		end
		return visit(tree.left) or visit(tree.right)
	end
	return visit(Geometry.TriangleTree(node.geometry,node.component))
end

local function Scan(context,source)
	local started=Tick();local profile={phase="building",candidates=0,probes=0,visited=0}
	context.map.SuperBigMapDecorationValidationProgress=profile
	local index=Validator.Index(6400);local nodes={};local map=source and context.source_map or context.map
	-- One terrain tile is far too generous for a positive contact (it would call
	-- visibly floating fragments supported). Use a 1/50-tile rounding tolerance;
	-- keep the full tile only as a conservative margin for negative terrain proof.
	local separation_margin=Global("const").HeightTileSize
	local tolerance=min(2,separation_margin/50.0)
	local width,height=map:GetMapSize()
	local function inside(p)return p[1]>=0 and p[2]>=0 and p[1]<width and p[2]<height end
	local uncaptured,uncaptured_complete
	local function NoUncapturedSupport(bounds)
		-- A later native pass may have spawned a support after source capture. Only
		-- possible negative findings need this lazy census; omitted objects must not
		-- turn a sparse capture into proof of empty space.
		if not uncaptured then
			uncaptured=Validator.Index(6400);uncaptured_complete=true
			local kind=Global("IsKindOf")
			local function inspect(obj)
				if not IsValid(obj) or context.by_object[obj] or Projected(obj)
					or (type(kind)=="function" and kind(obj,"EditorVisibleObject")) then return end
				local b=obj:GetObjectBBox()
				if not b then uncaptured_complete=false;return end
				b=BoxBounds(b)
				local shift=source and Pose(obj,context.source_map).shift[3] or 0
				b[3],b[6]=b[3]+shift,b[6]+shift
				uncaptured:Add({bounds=b})
			end
			if type(context.map.MapForEach)=="function" then context.map:MapForEach("map","CObject",inspect)
			else uncaptured_complete=false end
		end
		return uncaptured_complete and #uncaptured:Query(bounds,tolerance)==0
	end
	local holes=Validator.Index(6400);local hole_types={};local has_holes=false
	local function InHole(p)
		if not has_holes then return false end
		for _,hole in ipairs(holes:Query({p[1],p[2],p[3],p[1],p[2],p[3]},0)) do
			local t=hole.triangle
			if not t then return true end -- unavailable cut geometry: conservative bound
			local function side(ax,ay,bx,by)return (p[1]-bx)*(ay-by)-(ax-bx)*(p[2]-by) end
			local a,b,c=side(t[1],t[2],t[3],t[4]),side(t[3],t[4],t[5],t[6]),side(t[5],t[6],t[1],t[2])
			if not ((a<0 or b<0 or c<0) and (a>0 or b>0 or c>0)) then return true end
		end
		return false
	end
	for record_index,record in ipairs(context.list) do
		YieldBatch(record_index,context)
		if IsValid(record.obj) then
		local refresh=not context.selection or context.selection[record] or not record.pose
		if refresh then record.pose=Pose(record.obj,source and context.source_map or nil);record.fast_bounds=nil end
		local obj=record.obj;local key=obj:GetEntity()..":"..tostring(obj:GetState())
		if hole_types[key]==nil then
			local flag=(Global("EntitySurfaces") or {}).TerrainHole
			local has=Global("HasAnySurfaces")
			hole_types[key]=flag and type(has)=="function" and has(obj,flag,true) or false
		end
		if hole_types[key] then
			has_holes=true
			local for_each=Global("ForEachSurface");local count=0
			local ok=type(for_each)=="function" and pcall(for_each,obj,Global("EntitySurfaces").TerrainHole,function(a,b,c)
				local ax,ay=a:xy();local bx,by=b:xy();local cx,cy=c:xy()
				-- Vertical/degenerate projected faces have no terrain-cut area.
				if (bx-ax)*(cy-ay)-(by-ay)*(cx-ax)~=0 then
					holes:Add({bounds={min(ax,bx,cx),min(ay,by,cy),-1e12,max(ax,bx,cx),max(ay,by,cy),1e12},triangle={ax,ay,bx,by,cx,cy}})
					count=count+1
				end
			end)
			if not ok or count==0 then
				local b=BoxBounds(obj:GetObjectBBox());b[3],b[6]=-1e12,1e12;holes:Add({bounds=b})
			end
		end
		if record.relevant and refresh then BuildNodes(record) end
		if record.nodes and #record.nodes>0 then
			for _,node in ipairs(record.nodes) do
				if refresh then nodes[#nodes+1]=node else index:Add(node) end
			end
		end
		-- Unknown/skinned parts may still support another formation. Do not turn
		-- omitted geometry into a false proof that no neighbouring support exists.
		if not record.projected and (not record.complete or not record.nodes or #record.nodes==0) then
			local b=BoxBounds(record.obj:GetObjectBBox())
			b[3],b[6]=b[3]+record.pose.shift[3],b[6]+record.pose.shift[3]
			index:Add({bounds=b,record=record,unknown=true})
		end
	end end
	profile.build_ms=Tick()-started;profile.nodes=#nodes;profile.phase="contacts"
	local terrain_api=Global("terrain")
	local function TerrainUpper(node)
		if node.terrain_upper~=nil then return node.terrain_upper or nil end
		local b=node.bounds
		local high
		if type(terrain_api.GetMinMaxHeight)=="function" and inside(b) and inside({b[4],b[5]}) then
			local _,upper=terrain_api.GetMinMaxHeight(map,Global("box")(max(0,floor(b[1])-separation_margin),
				max(0,floor(b[2])-separation_margin),min(width-1,math.ceil(b[4])+separation_margin),
				min(height-1,math.ceil(b[5])+separation_margin)))
			if type(upper)=="number" then high=upper end
		end
		node.terrain_upper=high or false;return high
	end
	for node_index,node in ipairs(nodes) do
		YieldBatch(node_index,context)
		profile.visited=node_index
		local record=node.record
		local transform=node.transform_record or record
		for _,p in ipairs(node.samples) do
			local in_hole=InHole(p)
			-- The height field still exists beneath a terrain-cutting wonder. Without
			-- an exact hole coverage witness it must not count as visible support.
			local height=inside(p) and not in_hole and terrain_api.GetHeight(map,Point(p))
			if height and p[3]<=height+tolerance then
				node.supported=true;node.contacts.terrain=true;node.terrain_witness={point=p,height=height};break
			end
		end
		if node.supported then
			-- A real-vertex terrain witness needs no six-point contact search. The
			-- native object AABB is a conservative candidate bound; exact component
			-- triangles still decide another object's contact with this support.
			if #node.geometry.components==1 and not node.geometry.animated then
				local b=record.fast_bounds
				if not b then b=BoxBounds(record.obj:GetObjectBBox());b[3],b[6]=b[3]+record.pose.shift[3],b[6]+record.pose.shift[3];record.fast_bounds=b end
				node.bounds=b
			else
				-- A rubble entity can contain dozens of distant components. Using its
				-- whole box for every component would flood the nearby-object search.
				node.bounds=WorldBounds(transform,node.component.bounds)
			end
		else
			node.bounds=WorldBounds(transform,node.component.bounds);node.samples={}
			for _,p in ipairs(node.component.samples) do node.samples[#node.samples+1]=World(transform,p) end
			-- After rotation, minimum-local-Z need not be minimum-world-Z.
			for _,p in ipairs(node.samples) do
				local h=inside(p) and not InHole(p) and terrain_api.GetHeight(map,Point(p))
				if h and p[3]<=h+tolerance then node.supported=true;node.contacts.terrain=true;node.terrain_witness={point=p,height=h};break end
			end
		end
		-- A slope can intersect an interior mesh vertex without touching any of
		-- its six extrema. Try the remaining real vertices before expensive nearby
		-- triangle searches. This adds positive evidence, never a negative shortcut.
		local terrain_upper=not node.supported and TerrainUpper(node)
		if not node.supported and (not terrain_upper or node.bounds[3]<=terrain_upper+tolerance) then
			local unit=Global("guim")
			local points=node.component.engine_points
			if not points then
				points={};node.component.engine_points=points
				for _,vi in ipairs(node.component.vertices or {}) do
					local v=node.geometry.vertices[vi];points[#points+1]=Point({v[1]*unit,v[2]*unit,v[3]*unit})
				end
			end
			for pi,local_point in ipairs(points) do
				local p
				if node.geometry.animated then p=World(transform,node.geometry.vertices[node.component.vertices[pi]])
				else p=XYZ(record.obj:GetRelativePoint(local_point));p[3]=p[3]+record.pose.shift[3] end
				local h=inside(p) and not InHole(p) and terrain_api.GetHeight(map,Point(p))
				if h and p[3]<=h+tolerance then
					node.supported=true;node.contacts.terrain=true;node.terrain_witness={point=p,height=h};break
				end
			end
		end
		index:Add(node)
		if record.pose.parent then
			node.supported=true;node.contacts["attachment:"..Identity(context.map,record.pose.parent)]=true
		end
	end
	-- Seed every terrain/attachment root first. A proven contact with any rooted
	-- neighbour then needs no further triangle searches for that component.
	for node_index,node in ipairs(nodes) do
		YieldBatch(node_index,context)
		local record=node.record
		-- One proven terrain witness is sufficient for this connected component.
		-- Do not scan every neighbour of thousands of already grounded small rocks.
		local candidates=not node.supported and index:Query(node.bounds,tolerance) or {}
		local possible_other=false
		for _,other in ipairs(candidates) do
			profile.candidates=profile.candidates+1;YieldBatch(profile.candidates,context)
			if other~=node and ((other.record~=record and (other.unknown or other.lod==0))
				or (other.record==record and (other.unknown or other.lod==node.lod))) then
				possible_other=true
				if other.unknown or other.partial then node.unknown_support=true
				else
					for _,p in ipairs(node.samples) do
						profile.probes=profile.probes+1
						if MeshContact(other,p,tolerance) then
							node.edges[#node.edges+1]=other
							local kind=other.bounds[3]>node.bounds[3]+tolerance and "ceiling" or "object"
							node.contacts[kind..":"..Identity(context.map,other.record.obj)..":"..other.key]=true
							if other.supported then node.supported=true end
							break
						end
					end
				end
			end
			if node.supported then break end
		end
		if not node.supported and not possible_other and not node.partial and not context.incomplete then
			-- Exact native terrain upper bound + disjoint complete nearby AABBs proves
			-- separation. Sparse ray/sample misses alone never confirm a defect.
			if type(terrain_api.GetMinMaxHeight)=="function"
				and inside(node.bounds) and inside({node.bounds[4],node.bounds[5]}) then
				local b=node.bounds
				-- Include the neighbouring height-grid nodes used by edge interpolation;
				-- a tight sub-tile rectangle need not bound the interpolated terrain.
				local high=TerrainUpper(node)
				if type(high)=="number" and b[3]>high+separation_margin then
					if NoUncapturedSupport(b) then
						node.defect=true;node.reason="rendered component separated from terrain and nearby support"
					else node.unknown_support=true end
				elseif type(high)=="number" then
					-- The tile-wide XY padding already includes all terrain grid nodes
					-- used for interpolation. Refine the *vertical* error for small meshes
					-- rather than allowing a whole tile of visible air. Bound native-point
					-- rounding in the 100-metre transform basis and decoded quantization.
					local local_bounds=node.component.bounds
					local magnitude=0
					for a=1,3 do magnitude=magnitude+max(abs(local_bounds[a]),abs(local_bounds[a+3])) end
					local error_bound=2+math.ceil(magnitude/100.0
						+2*(node.geometry.quantum or 0)*Global("guim")*record.pose.scale/100.0)
					-- Large meshes retain the original conservative tile margin.
					if error_bound<separation_margin and b[3]>high+error_bound and NoUncapturedSupport(b) then
						node.defect=true;node.reason="rendered component separated beyond bounded transform/terrain error"
						node.separation_error_bound=error_bound
					end
				end
			end
		end
	end
	profile.contacts_ms=Tick()-started-profile.build_ms
	-- Resolve stacked/cantilevered connected components from actual rooted contact
	-- witnesses; unsupported cycles do not bootstrap themselves into validity.
	local changed=true
	while changed do
		changed=false
		for _,node in ipairs(nodes) do if not node.supported then
			for _,other in ipairs(node.edges) do if other.supported then node.supported=true;changed=true;break end end
		end end
	end
	profile.total_ms=Tick()-started;profile.phase="complete";context.profile=profile;context.index=index
	return nodes
end

function Validator.BeginCapture(map,source_map)
	if not Enabled() then contexts[map]=nil;return end
	contexts[map]={map=map,source_map=source_map or map,list={},by_object={},capture_ms=0}
end

function Validator.Failure(map,stage,err)
	local context=contexts[map]
	if context then
		context.incomplete=true;context.errors=context.errors or {}
		context.errors[#context.errors+1]={stage=stage,error=tostring(err)}
	end
	map.SuperBigMapDecorationValidation={diagnostic_only=true,status="inconclusive",
		reason="validator error",stage=stage,error=tostring(err)}
	Global("print")("[SBM decoration validation] inconclusive "..stage..": "..tostring(err))
end

function Validator.Run(method,map,...)
	if not Enabled() then return nil end
	local bounded=method=="FinishCapture" or method=="Validate" or method=="Recheck" or method=="CaptureGroup" or method=="CheckPlacements"
	local pause,resume=Global("PauseInfiniteLoopDetection"),Global("ResumeInfiniteLoopDetection")
	-- These loops are bounded by the captured object/triangle arrays. Keep the
	-- engine's transaction atomic, restoring its guard even when inspection fails.
	if bounded and type(pause)=="function" then pause("SuperBigMapDecorationValidation") end
	local ok,result=pcall(Validator[method],map,...)
	if bounded and type(resume)=="function" then resume("SuperBigMapDecorationValidation") end
	if not ok then Validator.Failure(map,method,result);return nil end
	return result
end

function Validator.Capture(map,obj,skip,important)
	local context=contexts[map]
	if not context or context.by_object[obj] then return end
	if context.restoring then RestoreBaseline(map,obj) end
	if type(obj.SuperBigMapSupportId)=="number" then
		map.SuperBigMapSupportIdSequence=max(map.SuperBigMapSupportIdSequence or 0,obj.SuperBigMapSupportId)
	end
	local record={obj=obj,relevant=Relevant(obj,skip,important),projected=Projected(obj)}
	context.by_object[obj]=record;context.list[#context.list+1]=record
	if record.relevant and type(obj.ForEachAttach)=="function" then
		obj:ForEachAttach(function(child)
			Validator.Capture(map,child,SBM.ObjectClone.ShouldSkipObject(child),SBM.ObjectClone.IsImportantSectorObject(child))
		end)
	end
end

local function FinishCapture(context)
	local map=context.map
	local started=Tick();Scan(context,true)
	for _,record in ipairs(context.list) do if record.relevant and IsValid(record.obj) then
		local baseline={version=1,entity=record.obj:GetEntity(),state=record.obj:GetState(),
			geometry_complete=record.complete or false,
			parent=Identity(map,record.pose.parent),components={}}
		for _,node in ipairs(record.nodes or {}) do
			baseline.components[node.key]={contacts=node.contacts,supported=node.supported or false,
				defect=node.defect or false}
		end
		record.obj.SuperBigMapSupportBaseline=baseline
	end end
	context.capture_ms=Tick()-started
	context.capture_profile=context.profile
	context.source_map=nil -- release a temporary native source after its witnesses were recorded
end

function Validator.FinishCapture(map)
	local context=contexts[map];if context then FinishCapture(context) end
end

-- Top-ups arrive as native prefab groups before their offsets/scales change.
-- Capture internal/terrain support then add them to the final map-wide check.
-- The partial group cannot prove absence of support outside itself.
function Validator.CaptureGroup(map,objects)
	if not Enabled() then return end
	local context={map=map,source_map=map,list={},by_object={},capture_ms=0,incomplete=true}
	for _,obj in ipairs(objects) do if IsValid(obj) then
		local c=SBM.ObjectClone
		context.list[#context.list+1]={obj=obj,relevant=Relevant(obj,c.ShouldSkipObject(obj),c.IsImportantSectorObject(obj)),projected=Projected(obj)}
	end end
	FinishCapture(context)
	local main=contexts[map]
	if main then
		main.capture_ms=main.capture_ms+context.capture_ms
		for _,record in ipairs(context.list) do
			if not main.by_object[record.obj] then main.list[#main.list+1]=record;main.by_object[record.obj]=record end
		end
	end
end

local function Fingerprint(obj)
	local p=obj:GetVisualPos();local parent=obj:GetParent()
	local x,y,z=p:xyz()
	return concat({obj:GetEntity(),tostring(obj:GetState()),x,y,z,tostring(obj:GetWorldScale()),
		tostring(type(obj.GetAxis)=="function" and obj:GetAxis()),tostring(type(obj.GetAngle)=="function" and obj:GetAngle()),
		tostring(obj:GetClipPlane()),tostring(parent),tostring(type(obj.GetMirrored)=="function" and obj:GetMirrored()),
		tostring(type(obj.GetAnimPhase)=="function" and obj:GetAnimPhase(1)),
		tostring(type(obj.GetWarped)=="function" and obj:GetWarped()),
		tostring(type(obj.GetSkewX)=="function" and obj:GetSkewX()),tostring(type(obj.GetSkewY)=="function" and obj:GetSkewY())},"|")
end

function Validator.Validate(map,reason)
	local context=contexts[map];if not context or not Enabled() then return nil end
	local started=Tick();Scan(context,false)
	local report={version=1,reason=reason or "generation",diagnostic_only=true,
		valid=0,confirmed_defect=0,inconclusive=0,instances={},capture_ms=context.capture_ms,
		contact_tolerance_world_units=min(2,Global("const").HeightTileSize/50.0),
		capture_profile=context.capture_profile,validation_profile=context.profile}
	for _,record in ipairs(context.list) do if record.relevant and IsValid(record.obj) then
		local cached=context.selection and not context.selection[record] and record.obj.SuperBigMapSupportValidation
		if cached then
			local key=cached.status=="confirmed defect" and "confirmed_defect" or cached.status
			report[key]=report[key]+1;report.instances[#report.instances+1]=cached
		else
		local baseline=record.obj.SuperBigMapSupportBaseline
		local changed=baseline and baseline.parent~=Identity(map,record.pose.parent)
		local complete=record.complete
		local preserved=baseline~=nil
		if baseline then
			if not baseline.geometry_complete then complete=false end
			local present={}
			for _,node in ipairs(record.nodes or {}) do
				present[node.key]=true
				local before=baseline.components[node.key]
				if before and before.supported then
					local retained=false
					for contact in pairs(before.contacts) do if node.contacts[contact] then retained=true;break end end
					if not retained then preserved=false end
				else preserved=false end
			end
			for key in pairs(baseline.components) do if not present[key] then preserved=false end end
			if baseline.entity~=record.obj:GetEntity() then complete=false end
		end
		local current_status=Validator.Classify(record.nodes or {},record.complete and not context.incomplete,changed)
		local repair=record.obj.SuperBigMapSupportRepair
		local repaired=repair and repair.version==1 and repair.pose==PersistedPoseKey(record.obj)
			and baseline and baseline.geometry_complete and current_status=="valid" and not changed
		local status,why=Validator.Classify(record.nodes or {},complete and (preserved or repaired) and not context.incomplete,changed)
		if repaired and status=="valid" then why="current rendered components supported after a recorded rigid correction" end
		local key=status=="confirmed defect" and "confirmed_defect" or status
		report[key]=report[key]+1
		local row={handle=record.obj.handle,id=Identity(map,record.obj),entity=record.obj:GetEntity(),class=record.obj.class,status=status,
			reason=status=="confirmed defect" and why or record.reason or why,
			geometry_complete=complete or false,support_preserved=preserved,current_geometry_status=current_status,
			placement_repaired=repaired or false,
			native_baseline=baseline~=nil,components=#(record.nodes or {}),position=XYZ(record.obj:GetVisualPos())}
		if status~="valid" then
			row.findings={}
			for _,node in ipairs(record.nodes or {}) do if not node.supported or node.defect then
				row.findings[#row.findings+1]={component=node.key,bounds=node.bounds,
					status=node.defect and "confirmed defect" or "inconclusive",reason=node.reason or "no rooted support witness",
						partial_clip=node.partial or false,unknown_support=node.unknown_support or false,
						separation_error_bound=node.separation_error_bound}
			end end
		end
		report.instances[#report.instances+1]=row
		record.obj.SuperBigMapSupportValidation=row
		end
	end end
	for _,record in ipairs(context.list) do if IsValid(record.obj) and (not context.selection or context.selection[record] or not record.fingerprint) then
		record.fingerprint=Fingerprint(record.obj);record.last_bounds=BoxBounds(record.obj:GetObjectBBox())
	end end
	PersistBaselines(context)
	report.validation_ms=Tick()-started;report.errors=context.errors;map.SuperBigMapDecorationValidation=report
	Global("print")(format("[SBM decoration validation] %s: valid=%d defect=%d inconclusive=%d capture=%dms validate=%dms",
		report.reason,report.valid,report.confirmed_defect,report.inconclusive,report.capture_ms,report.validation_ms))
	context.selection=nil;return report
end

-- A correction changes only the listed rigid placements. Recheck their old/new
-- neighbours and every support dependent, retaining unrelated instance evidence.
-- This does not replace the complete initial map check or lifecycle census.
function Validator.CheckPlacements(map,changes,reason)
	local context=contexts[map]
	if not context or not context.index then return nil end
	local selection={}
	for _,change in ipairs(changes) do
		local record=context.by_object[change.obj]
		if not record then return nil end
		selection[record]=true
		for _,bounds in ipairs({record.last_bounds,BoxBounds(change.obj:GetObjectBBox())}) do
			for _,node in ipairs(context.index:Query(bounds,Global("const").HeightTileSize)) do selection[node.record]=true end
		end
	end
	local changed=true
	while changed do
		changed=false
		for _,record in ipairs(context.list) do if not selection[record] then
			for _,node in ipairs(record.nodes or {}) do
				for _,other in ipairs(node.edges) do if selection[other.record] then selection[record]=true;changed=true;break end end
			end
		end end
	end
	context.selection=selection
	return Validator.Validate(map,reason)
end

-- Retain positive witnesses for unchanged instances. Unknown instances, changed
-- placements, nearby supports and dependent formations are always rechecked.
-- A loaded map has no in-memory witness cache, so its first check covers all.
function Validator.Recheck(map,reason)
	if not Enabled() or not map then return nil end
	if Geometry.RetryIncomplete then Geometry.RetryIncomplete() end
	local context=contexts[map]
	if not context then Validator.BeginCapture(map,map);context=contexts[map] end
	context.allow_yield=true
	context.restoring=true
	local seen,selection,regions={},{},{}
	map:MapForEach("map","CObject",function(obj)
		Validator.Capture(map,obj,SBM.ObjectClone.ShouldSkipObject(obj),SBM.ObjectClone.IsImportantSectorObject(obj))
		local record=context.by_object[obj];seen[record]=true
		local terrain_changed=false
		for _,node in ipairs(record.nodes or {}) do
			local witness=node.terrain_witness
			if witness and Global("terrain").GetHeight(map,Point(witness.point))~=witness.height then terrain_changed=true;break end
		end
		local unverifiable=record.relevant and (not obj.SuperBigMapSupportValidation or obj.SuperBigMapSupportValidation.status~="valid")
		local asset_changed=record.relevant and record.asset~=Geometry.Instance(obj)
		if record.fingerprint~=Fingerprint(obj) or unverifiable or asset_changed or terrain_changed then
			selection[record]=true
			if record.last_bounds then regions[#regions+1]=record.last_bounds end
			regions[#regions+1]=BoxBounds(obj:GetObjectBBox())
		end
	end)
	for _,record in ipairs(context.list) do if IsValid(record.obj) and not seen[record] then
		local parent=record.obj:GetParent()
		while parent do
			if seen[context.by_object[parent]] then seen[record]=true;break end
			parent=parent:GetParent()
		end
	end end
	for _,record in ipairs(context.list) do if not seen[record] then
		selection[record]=true;if record.last_bounds then regions[#regions+1]=record.last_bounds end
	end end
	if context.index then
		for _,b in ipairs(regions) do
			for _,node in ipairs(context.index:Query(b,Global("const").HeightTileSize)) do selection[node.record]=true end
		end
	end
	local changed=true
	while changed do
		changed=false
		for _,record in ipairs(context.list) do if not selection[record] then
			for _,node in ipairs(record.nodes or {}) do
				for _,other in ipairs(node.edges) do if selection[other.record] then selection[record]=true;changed=true;break end end
			end
		end end
	end
	local retained={}
	for _,record in ipairs(context.list) do
		if seen[record] then retained[#retained+1]=record else context.by_object[record.obj]=nil end
	end
	context.list=retained
	context.selection=selection
	return Validator.Validate(map,reason)
end

local scheduled=setmetatable({}, {__mode="k"})
function Validator.Loaded(map)
	-- Called only after the lifecycle has validated an expanded saved map. The
	-- surface generation milestone is deliberately transient, so it cannot gate
	-- checks after loading (including old saves with no diagnostic ledger).
	contexts[map]=nil
	loaded_maps[map]=true
end

function Validator.Schedule(map,reason)
	if not Enabled() or not map or scheduled[map] then return end
	-- Never race source capture/transformation or pull underground checks into T1.
	local underground=SBM.Engine.MapDataEnvironment(map.mapdata)=="Underground"
	if underground and map.SuperBigMapUndergroundPrepared~=true then return end
	if not underground and map.SuperBigMapSurfacePostPipelineRevalidationComplete~=true and not loaded_maps[map] then return end
	local create,sleep=Global("CreateRealTimeThread"),Global("Sleep")
	if type(create)~="function" then return end
	scheduled[map]=true
	create(function()
		sleep(1)
		if Global("Maps") and Global("Maps")[map.slot]==map then Validator.Run("Recheck",map,reason) end
		scheduled[map]=nil
	end)
end

Validator.Clear=function(map)contexts[map]=nil end
function Validator.RecordSeating(map,obj,from,to)
	local row=obj.SuperBigMapSupportValidation
	if not row or row.status~="confirmed defect" or not row.geometry_complete then return false end
	obj.SuperBigMapSupportRepair={version=1,pose=PersistedPoseKey(obj),from=from,to=to,
		reason="confirmed unsupported cosmetic geometry",source_id=row.id}
	return true
end
-- Read-only evidence for the separate correction service. Unknown geometry,
-- attachments, stacks and dependent formations cannot be treated as loose stones.
function Validator.SeatingEvidence(map)
	local context=contexts[map];local result={}
	if not context or context.incomplete or not context.index then return result end
	local eligible=SBM.RockGrounding and SBM.RockGrounding.Eligible
	for _,record in ipairs(context.list) do
		local obj=record.obj;local row=IsValid(obj) and obj.SuperBigMapSupportValidation
		if row and row.status=="confirmed defect" and record.complete and eligible and eligible(obj)
			and not record.pose.parent and #record.nodes>0 then
			local safe=true;local unsupported=false
			for _,node in ipairs(record.nodes) do
				if node.geometry.animated or node.partial or node.unknown_support or #node.edges>0 then safe=false end
				if not node.supported then unsupported=true end
				if node.supported and not obj.SuperBigMapDecorEnginePass then safe=false end
			end
			if type(obj.ForEachAttach)=="function" then obj:ForEachAttach(function()safe=false end) end
			local bounds=BoxBounds(obj:GetObjectBBox())
			for _,other in ipairs(context.index:Query(bounds,Global("const").HeightTileSize)) do
				if other.record~=record then
					for _,edge in ipairs(other.edges or {}) do if edge.record==record then safe=false end end
				end
			end
			if safe and unsupported then
				local components={}
				for _,node in ipairs(record.nodes) do
					local c={vertices={},height=0};local lo,hi=math.huge,-math.huge
					for _,vi in ipairs(node.component.vertices) do
						local p=World(record,node.geometry.vertices[vi]);c.vertices[#c.vertices+1]=p
						lo=min(lo,p[3]);hi=max(hi,p[3])
					end
					c.height=hi-lo;components[#components+1]=c
				end
				result[#result+1]={obj=obj,components=components,bounds=bounds,confirmed=row.status=="confirmed defect"}
			end
		end
	end
	return result
end

function Validator.SeatingPlacementClear(map,obj,bounds)
	local context=contexts[map]
	if not context or not context.index then return false end
	local record=context.by_object[obj];if not record then return false end
	local original=BoxBounds(obj:GetObjectBBox())
	local delta={bounds[1]-original[1],bounds[2]-original[2],bounds[3]-original[3]}
	local function transformed(node,shift)
		local verts={}
		for _,vi in ipairs(node.component.vertices) do
			local p=World(node.transform_record or node.record,node.geometry.vertices[vi])
			verts[vi]={p[1]+shift[1],p[2]+shift[2],p[3]+shift[3]}
		end
		return verts
	end
	local target_vertices={}
	for _,node in ipairs(context.index:Query(bounds,2)) do
		if node.record.obj~=obj then
			if node.unknown or node.partial or not node.record.complete then return false,node.record.obj:GetEntity() end
			local other_vertices=transformed(node,{0,0,0})
			for _,own in ipairs(record.nodes) do
				local verts=target_vertices[own]
				if not verts then verts=transformed(own,delta);target_vertices[own]=verts end
				for _,ta in ipairs(own.component.triangles) do
					local a={verts[ta[1]],verts[ta[2]],verts[ta[3]]}
					for _,tb in ipairs(node.component.triangles) do
						local b={other_vertices[tb[1]],other_vertices[tb[2]],other_vertices[tb[3]]}
						if not Geometry.TrianglesSeparated(a,b,2) then return false,node.record.obj:GetEntity() end
					end
				end
			end
		end
	end
	return true
end
SBM.DecorationValidation=Validator
