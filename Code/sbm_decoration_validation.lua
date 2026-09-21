-- Diagnostic only: this module never moves objects, changes terrain or replaces
-- rendering. Positive contact witnesses and complete geometry coverage are separate.
local SBM = rawget(_G, "SuperBigMap")
local Global, Geometry = SBM.Engine.Global, SBM.DecorationGeometry
local Validator = {}
local contexts = setmetatable({}, {__mode="k"})
local loaded_maps = setmetatable({}, {__mode="k"})
local active_checks = setmetatable({}, {__mode="k"})
local main_owner = {}
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
	-- Read an unchanged union of query regions. The caller owns the transaction's
	-- seen set; no results survive into another placement or lifecycle check.
	function index:QueryOnce(bounds,pad,seen,visit)
		local function take(node)
			if not seen[node] and Overlap(node.bounds,bounds,pad) then seen[node]=true;visit(node) end
		end
		for x=floor((bounds[1]-pad)/(size+0.0)),floor((bounds[4]+pad)/(size+0.0)) do
			for y=floor((bounds[2]-pad)/(size+0.0)),floor((bounds[5]+pad)/(size+0.0)) do
				for _,node in ipairs(self.buckets[x..":"..y] or {}) do take(node) end
			end
		end
		for _,node in ipairs(self.large) do take(node) end
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

local function SegmentPairDistanceSquared(p,q,a,b)
	local ux,uy,uz=q[1]-p[1],q[2]-p[2],q[3]-p[3]
	local vx,vy,vz=b[1]-a[1],b[2]-a[2],b[3]-a[3]
	local rx,ry,rz=p[1]-a[1],p[2]-a[2],p[3]-a[3]
	local uu,vv=ux*ux+uy*uy+uz*uz,vx*vx+vy*vy+vz*vz
	local uv,ur,vr=ux*vx+uy*vy+uz*vz,ux*rx+uy*ry+uz*rz,vx*rx+vy*ry+vz*rz
	local s,t=0,0
	if uu<=1e-20 then t=vv>1e-20 and max(0,min(1,vr/(vv+0.0))) or 0
	elseif vv<=1e-20 then s=max(0,min(1,-ur/(uu+0.0)))
	else
		local den=uu*vv-uv*uv
		if den>1e-20 then s=max(0,min(1,(uv*vr-ur*vv)/(den+0.0))) end
		t=(uv*s+vr)/(vv+0.0)
		if t<0 then t=0;s=max(0,min(1,-ur/(uu+0.0)))
		elseif t>1 then t=1;s=max(0,min(1,(uv-ur)/(uu+0.0))) end
	end
	local x,y,z=rx+s*ux-t*vx,ry+s*uy-t*vy,rz+s*uz-t*vz
	return x*x+y*y+z*z
end

function Validator.TrianglePairDistanceSquared(a,b)
	if not Geometry.TrianglesSeparated(a,b,0) then return 0 end
	local distance=math.huge
	for i=1,3 do
		distance=min(distance,Validator.TriangleDistanceSquared(a[i],b[1],b[2],b[3]),
			Validator.TriangleDistanceSquared(b[i],a[1],a[2],a[3]))
		for j=1,3 do distance=min(distance,SegmentPairDistanceSquared(a[i],a[i%3+1],b[j],b[j%3+1])) end
	end
	return distance
end

function Validator.TrianglesContact(a,b,tolerance)
	-- A separating-axis gap larger than the contact tolerance is a proof of
	-- separation, so skip the much more expensive closest-feature calculation.
	-- Failure to find such an axis is NOT proof of contact: retain the complete
	-- vertex/face and edge/edge distance test for every remaining candidate.
	return not Geometry.TrianglesSeparated(a,b,tolerance)
		and Validator.TrianglePairDistanceSquared(a,b)<=tolerance*tolerance
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

local function PersistedPoseKey(obj,entity)
	local pos=obj:GetPos();local x,y,z=pos:xyz()
	local parent=obj:GetParent()
	local px,py,pz
	if parent then px,py,pz=parent:GetPos():xyz() end
	return concat({tostring(obj.class),entity or obj:GetEntity(),tostring(x),tostring(y),tostring(z),
		tostring(obj:GetWorldScale()),tostring(type(obj.GetAngle)=="function" and obj:GetAngle()),
		tostring(type(obj.GetAxis)=="function" and obj:GetAxis()),tostring(obj:GetState()),
		tostring(parent and parent:GetEntity()),tostring(px),tostring(py),tostring(pz)},"|")
end

local function VerifiedRubbleClearing(record,baseline,repair)
	local obj=record.obj
	if obj.class~="TunnelBlockerRubble" or not baseline or not baseline.geometry_complete
		or baseline.entity~="CaveIn_TunnelBlocker_1" or not repair or repair.version~=1
		or repair.forced_lod~=0 or record.asset.forced_lod~=0
		or obj.gradual_clearing_name~="CaveIn_TunnelBlocker" or obj.anim_phases~=5
		or type(obj.GetClearProgress)~="function" or obj:GetState()~=baseline.state
		or repair.pose~=PersistedPoseKey(obj,baseline.entity) then return false end
	local phase=tonumber(obj:GetEntity():match("^CaveIn_TunnelBlocker_([2-5])$"))
	local progress=obj:GetClearProgress()
	if not phase or type(progress)~="number" or progress<0 or progress>=100
		or phase~=1+floor(progress/(100/obj.anim_phases+1)) then return false end
	-- The native clearing recipe is not permission for a foreign mesh override.
	local native=Geometry.Entity(obj:GetEntity(),obj:GetState())
	if not native.complete or not record.asset.complete then return false end
	local index=0
	for _,part in ipairs(native.parts) do if part.lod==0 then
		index=index+1;local rendered=record.asset.parts[index]
		if not rendered or rendered.lod~=0 or rendered.material~=part.material
			or rendered.mesh.path~=part.mesh.path then return false end
	end end
	return index>0 and index==#record.asset.parts
end

local function RestoreBaseline(map,obj)
	local ledger=map.SuperBigMapDecorationBaselines
	local entry=type(ledger)=="table" and ledger.records and ledger.records[PersistedPoseKey(obj)]
	if entry and not entry.ambiguous then
		if not obj.SuperBigMapSupportId then obj.SuperBigMapSupportId=entry.id end
		if not obj.SuperBigMapSupportBaseline then obj.SuperBigMapSupportBaseline=entry.baseline end
		if not obj.SuperBigMapSupportRepair then obj.SuperBigMapSupportRepair=entry.repair end
		-- Plain CObjects also lose this placement-policy flag on inactive-map
		-- serialization. Only an exact, unique ledger entry may restore permission
		-- for a top-up's bounded XY correction; never infer it for a native rock.
		if obj.SuperBigMapDecorEnginePass==nil and entry.decor_topup==true then obj.SuperBigMapDecorEnginePass=true end
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
			else ledger.records[key]={id=obj.SuperBigMapSupportId,baseline=obj.SuperBigMapSupportBaseline,repair=obj.SuperBigMapSupportRepair,
				decor_topup=obj.SuperBigMapDecorEnginePass==true} end
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
	-- Attached prefab architecture is skipped by the free-standing scaling pass,
	-- but is rendered with its parent and can support that parent's loose pieces.
	-- Decode it rather than inserting an unknown whole-object bounding box.
	local parent=obj:GetParent()
	while parent do
		local data=Global("EntityData")[parent:GetEntity()]
		if (type(kind)=="function" and kind(parent,"UndergroundWonder"))
			or (data and data.editor_category=="StonesRocksCliffs") then return true end
		parent=parent:GetParent()
	end
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
	record.asset=asset;record.complete=asset.complete;record.nodes={};record.clipped_nodes={};record.reason=asset.reason
	record.projected=Projected(obj)
	record.nonphysical=nil
	if asset.render_kind=="native non-rendering entity" or asset.render_kind=="native non-rendering logical marker"
		or asset.render_kind=="verified native particle attachment"
		or (record.projected and asset.render_kind=="terrain texture projection") then
		record.nonphysical=asset.render_kind;record.complete=true;record.reason=asset.render_kind
		return
	end
	if record.projected then
		-- A decal mesh is a projection volume, not the rendered surface. It cannot
		-- prove floating geometry or act as solid support for another decoration.
		record.complete=false;record.reason="projected decal coverage requires a separate decoder";return
	end
	-- World-space warping needs its own shader-specific decoder. Never approve it
	-- using the unwarped CPU vertices.
	if (type(obj.GetSkewX)=="function" and obj:GetSkewX()~=0)
		or (type(obj.GetSkewY)=="function" and obj:GetSkewY()~=0)
		or (type(obj.GetWarped)=="function" and obj:GetWarped()) then
		record.complete=false;record.reason="non-rigid rendering transform";return
	end
	-- GetRelativePoint applies the native local-Y reflection. Matrix() builds its
	-- basis from that API, not GetTransformMatrix (which omits mirroring). A
	-- reflection is orthogonal, so the same inverse and triangle tests apply.
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
				if transform and clipped then record.clipped_nodes[part.lod..":"..part.mesh.path..":"..component_index]=true end
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

-- Extremal points miss face/edge intersections in legitimate stacked meshes.
-- Traverse both shared triangle BVHs; world bounds prune disjoint subtrees.
-- This inspects rendered triangles, not overlapping object boxes as proof.
local function RawComponentContact(a,b,tolerance)
	local ar,br=a.transform_record or a.record,b.transform_record or b.record
	local ac,bc={},{}
	local function bounds(record,tree,cache)
		local value=cache[tree]
		if not value then value=WorldBounds(record,tree.bounds);cache[tree]=value end
		return value
	end
	local av,bv={},{}
	local function vertex(node,record,cache,i)
		local value=cache[i]
		if not value then value=World(record,node.geometry.vertices[i]);cache[i]=value end
		return value
	end
	local function visit(at,bt)
		if not Overlap(bounds(ar,at,ac),bounds(br,bt,bc),tolerance) then return false end
		if at.items and bt.items then
			for _,ai in ipairs(at.items) do for _,bi in ipairs(bt.items) do
				if Overlap(bounds(ar,ai,ac),bounds(br,bi,bc),tolerance) then
					local x,y={},{}
					for i=1,3 do x[i]=vertex(a,ar,av,ai.triangle[i]);y[i]=vertex(b,br,bv,bi.triangle[i]) end
					-- A padded SAT failure is not a distance witness. Check every
					-- vertex/face and edge/edge pair, including interior edge contacts.
					if Validator.TrianglesContact(x,y,tolerance) then return true end
				end
			end end
			return false
		end
		if at.items then return visit(at,bt.left) or visit(at,bt.right) end
		if bt.items then return visit(at.left,bt) or visit(at.right,bt) end
		return visit(at.left,bt.left) or visit(at.left,bt.right) or visit(at.right,bt.left) or visit(at.right,bt.right)
	end
	if visit(Geometry.TriangleTree(a.geometry,a.component),Geometry.TriangleTree(b.geometry,b.component)) then return true end
	local ap=World(ar,a.geometry.vertices[a.component.vertices[1]])
	local bp=World(br,b.geometry.vertices[b.component.vertices[1]])
	local a_in_b=Geometry.PointInClosedComponent(b.geometry,b.component,Local(br,ap))
	local b_in_a=Geometry.PointInClosedComponent(a.geometry,a.component,Local(ar,bp))
	-- The complete triangle search has excluded contact. Both connected pieces
	-- must also be demonstrably outside each other's volume before their
	-- overlapping broad-phase boxes may be dismissed as possible support.
	return a_in_b==true or b_in_a==true,a_in_b==false and b_in_a==false
end

local function ComponentContact(a,b,tolerance,reuse_bounds)
	local ar,br=a.transform_record or a.record,b.transform_record or b.record
	if ar==br and not a.geometry.animated and not b.geometry.animated then
		-- Fragments within one rigid mesh share the same affine frame. Contact
		-- is an asset property; do not repeat every triangle-pair search for each
		-- translated/rotated blocker. Gershgorin bounds on A' A bracket the exact
		-- world metric, including native basis rounding/nonuniform transforms.
		local cols=Matrix(ar).columns;local lower,upper=math.huge,0
		for i=1,3 do
			local diagonal=Dot(cols[i],cols[i]);local radius=0
			for j=1,3 do if i~=j then radius=radius+abs(Dot(cols[i],cols[j])) end end
			lower=min(lower,diagonal-radius);upper=max(upper,diagonal+radius)
		end
		if lower>0 and upper<math.huge then
			-- Outward quantization shares bounds across harmless rotation rounding.
			-- Ambiguous boundary cases still use the original world-space search.
			local lo=floor(tolerance/math.sqrt(upper)*1e6)/1e6
			local hi=math.ceil(tolerance/math.sqrt(lower)*1e6)/1e6
			local cache=a.component.rigid_contacts
			if not cache then cache={};a.component.rigid_contacts=cache end
			local pair=cache[b.component];if not pair then pair={};cache[b.component]=pair end
			-- A positive asset-space witness at a stricter tolerance remains valid
			-- at a looser one. Conversely complete separation at a looser tolerance
			-- proves it at every stricter one. Keep the same conservative metric
			-- bounds; this only avoids rediscovering a previously proven relation.
			if reuse_bounds then
				if pair.contact_at and lo>=pair.contact_at then return true,false end
				if pair.separated_at and hi<=pair.separated_at then return false,true end
			end
			local key=lo..":"..hi;local result=pair[key]
			if not result then
				local r={pose={matrix={origin={0,0,0},columns={{1,0,0},{0,1,0},{0,0,1}}},shift={0,0,0},scale=100}}
				local x={record=r,geometry=a.geometry,component=a.component}
				local y={record=r,geometry=b.geometry,component=b.component}
				local hit,separated=RawComponentContact(x,y,lo)
				if hit then
					result={true,false}
					if reuse_bounds then pair.contact_at=min(pair.contact_at or math.huge,lo) end
				else
					if hi~=lo then hit,separated=RawComponentContact(x,y,hi) end
					result=not hit and separated and {false,true} or {}
					if reuse_bounds then
						if hit then pair.contact_at=min(pair.contact_at or math.huge,hi)
						elseif separated then pair.separated_at=max(pair.separated_at or 0,hi) end
					end
				end
				pair[key]=result
			end
			if result[1]~=nil then return result[1],result[2] end
		end
	end
	return RawComponentContact(a,b,tolerance)
end

local function Scan(context,source)
	local started=Tick();local profile={phase="building",candidates=0,probes=0,visited=0}
	if not context.placement_only then context.map.SuperBigMapDecorationValidationProgress=profile end
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
		-- Surface nomination built this exact geometry in the same non-yielding
		-- correction transaction. Consume it ONCE, before any placement changes.
		-- Later CheckPlacements/load/switch scans always reconstruct changed poses.
		local prebuilt=context.correction_only and not source and record.correction_prebuilt
		record.correction_prebuilt=nil
		if refresh and not prebuilt then record.pose=Pose(record.obj,source and context.source_map or nil);record.fast_bounds=nil end
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
		if record.relevant and refresh and not prebuilt then BuildNodes(record) end
		if record.nodes and #record.nodes>0 then
			for _,node in ipairs(record.nodes) do
				if refresh then nodes[#nodes+1]=node else index:Add(node) end
			end
		end
		-- Unknown/skinned parts may still support another formation. Do not turn
		-- omitted geometry into a false proof that no neighbouring support exists.
		if not record.editor_only and not record.projected and not record.nonphysical and (not record.complete or not record.nodes or #record.nodes==0) then
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
	local function TerrainFaceWitness(node,upper)
		-- Terrain may meet the INTERIOR of a face while every mesh vertex misses
		-- it. A sampled hit is a positive witness only: misses never prove a gap.
		-- Query at integer XY and recompute the triangle's exact Z there, avoiding
		-- snapping a centroid across a steep terrain edge while retaining its old Z.
		local world,heights={},{}
		local transform=node.transform_record or node.record
		local function vertex(i)
			if not world[i] then world[i]=World(transform,node.geometry.vertices[i]) end
			return world[i]
		end
		for _,t in ipairs(node.component.triangles) do
			local a,b,c=vertex(t[1]),vertex(t[2]),vertex(t[3])
			local den=(b[2]-c[2])*(a[1]-c[1])+(c[1]-b[1])*(a[2]-c[2])
			if abs(den)>1e-12 and (not upper or min(a[3],b[3],c[3])<=upper+tolerance) then
				local function sample(x,y)
					x,y=floor(x+0.5),floor(y+0.5)
					local u=((b[2]-c[2])*(x-c[1])+(c[1]-b[1])*(y-c[2]))/den
					local v=((c[2]-a[2])*(x-c[1])+(a[1]-c[1])*(y-c[2]))/den
					if u<0 or v<0 or u+v>1 then return nil end
					local p={x,y,u*a[3]+v*b[3]+(1-u-v)*c[3]}
					local key=x..":"..y;local h=heights[key]
					if h==nil then
						h=inside(p) and not InHole(p) and terrain_api.GetHeight(map,Point(p)) or false
						heights[key]=h
					end
					if h and p[3]<=h+tolerance then return {point=p,height=h} end
				end
				local hit=sample((a[1]+b[1]+c[1])/3.0,(a[2]+b[2]+c[2])/3.0)
				if hit then return hit end
				for _,steps in ipairs({2,4,8}) do
					for i=0,steps do for j=0,steps-i do
						local u,v=i/(steps+0.0),j/(steps+0.0)
						hit=sample(a[1]*u+b[1]*v+c[1]*(1-u-v),a[2]*u+b[2]*v+c[2]*(1-u-v))
						if hit then return hit end
					end end
				end
			end
		end
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
				for _,vi in ipairs(Geometry.SupportVertices(node.geometry,node.component)) do
					local v=node.geometry.vertices[vi];points[#points+1]=Point({v[1]*unit,v[2]*unit,v[3]*unit})
				end
			end
			for pi,local_point in ipairs(points) do
				local p
					if node.geometry.animated then p=World(transform,node.geometry.vertices[Geometry.SupportVertices(node.geometry,node.component)[pi]])
				else p=XYZ(record.obj:GetRelativePoint(local_point));p[3]=p[3]+record.pose.shift[3] end
				local h=inside(p) and not InHole(p) and terrain_api.GetHeight(map,Point(p))
				if h and p[3]<=h+tolerance then
					node.supported=true;node.contacts.terrain=true;node.terrain_witness={point=p,height=h};break
				end
			end
		end
		if not node.supported and not node.partial and not context.positive_only
			and (not terrain_upper or node.bounds[3]<=terrain_upper+tolerance) then
			local witness=TerrainFaceWitness(node,terrain_upper)
			if witness then node.supported=true;node.contacts.terrain=true;node.terrain_witness=witness end
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
				if other.unknown or other.partial then node.unknown_support=true;possible_other=true
				else
					local contact,separated=false,false
					-- Same-frame fragment pairs have a reusable complete triangle
					-- result; avoid repeating sample-to-triangle probes before it.
					if (node.transform_record or node.record)~=(other.transform_record or other.record) then
						for _,p in ipairs(node.samples) do
							profile.probes=profile.probes+1
							if MeshContact(other,p,tolerance) then contact=true;break end
						end
					end
					if not contact then contact,separated=ComponentContact(node,other,tolerance,context.placement_only) end
					if not separated then possible_other=true end
					if contact then
						node.edges[#node.edges+1]=other
						local kind=other.bounds[3]>node.bounds[3]+tolerance and "ceiling" or "object"
						node.contacts[kind..":"..Identity(context.map,other.record.obj)..":"..other.key]=true
						if other.supported then node.supported=true end
					end
				end
			end
			if node.supported then break end
		end
		if source and context.placement_only and not node.supported and #node.edges==0 then
			-- This new stamp will be rejected: every terrain witness and possible
			-- support for this component has been tried, and later nodes cannot add
			-- an outgoing edge to it. Root propagation therefore cannot rescue it.
			-- Stop wasted work on the rest of a rejected stamp, not necessary checks
			-- on any accepted one. Diagnostic captures still collect every finding.
			profile.contacts_ms=Tick()-started-profile.build_ms
			profile.total_ms=Tick()-started;profile.phase="rejected"
			context.profile=profile;context.index=index
			return
		end
		if not node.supported and not possible_other and not node.partial and not context.incomplete and not context.positive_only then
			-- Exact native terrain upper bound + disjoint complete nearby AABBs proves
			-- separation. Sparse ray/sample misses alone never confirm a defect.
			if type(terrain_api.GetMinMaxHeight)=="function"
				and inside(node.bounds) and inside({node.bounds[4],node.bounds[5]}) then
				local b=node.bounds
				-- A transformed local box can dip far below every rendered vertex.
				-- Tighten only this negative proof using ALL vertices of the rigid
				-- component, not sparse samples. An affine triangle's coordinate
				-- extrema occur at its vertices; retain transform error padding below.
				local tight=Geometry.Bounds()
				for _,vi in ipairs(Geometry.SupportVertices(node.geometry,node.component)) do
					Geometry.Extend(tight,World(node.transform_record or record,node.geometry.vertices[vi]))
				end
				local minimum_z=tight[3]
				-- Include the neighbouring height-grid nodes used by edge interpolation;
				-- a tight sub-tile rectangle need not bound the interpolated terrain.
				local high=TerrainUpper(node)
				if type(high)=="number" and minimum_z>high+separation_margin then
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
					if error_bound<separation_margin and minimum_z>high+error_bound and NoUncapturedSupport(b) then
						node.defect=true;node.reason="rendered component separated beyond bounded transform/terrain error"
						node.separation_error_bound=error_bound
					elseif error_bound<separation_margin and NoUncapturedSupport(b) then
						-- On sloped terrain a fragment's lowest point and the terrain's
						-- highest point may be at opposite ends of its box. Bound each
						-- complete triangle separately before accepting that ambiguity.
						local triangles,vertices,heights={},{},{}
						for _,t in ipairs(node.component.triangles) do
							local triangle={}
							for i,vi in ipairs(t) do
								vertices[vi]=vertices[vi] or World(node.transform_record or record,node.geometry.vertices[vi])
								triangle[i]=vertices[vi]
							end
							triangles[#triangles+1]=triangle
						end
						local function upper(rect)
							local x0,y0=max(0,floor(rect[1])-separation_margin),max(0,floor(rect[2])-separation_margin)
							local x1,y1=min(width-1,math.ceil(rect[4])+separation_margin),min(height-1,math.ceil(rect[5])+separation_margin)
							local key=x0..":"..y0..":"..x1..":"..y1
							if heights[key]==nil then
								local _,value=terrain_api.GetMinMaxHeight(map,Global("box")(x0,y0,x1,y1))
								heights[key]=type(value)=="number" and value or false
							end
							return heights[key] or nil
						end
						if Geometry.TrianglesAboveTerrain(triangles,upper,error_bound) then
							node.defect=true;node.reason="every rendered triangle separated from bounded terrain and nearby support"
							node.separation_error_bound=error_bound
						end
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
	if context.positive_only then
		-- A known, signature-guarded blocker correction needs a complete positive
		-- support proof, not a diagnostic proof of every existing negative gap.
		-- Try the shared rigid contact graph before expensive face-interior terrain
		-- searches. No failed/missing witness is accepted; the correction service
		-- still rolls back unless every rendered component is positively rooted.
		for _,node in ipairs(nodes) do if not node.supported and not node.partial then
			local upper=TerrainUpper(node)
			if not upper or node.bounds[3]<=upper+tolerance then
				local witness=TerrainFaceWitness(node,upper)
				if witness then node.supported=true;node.contacts.terrain=true;node.terrain_witness=witness end
			end
		end end
		changed=true
		while changed do
			changed=false
			for _,node in ipairs(nodes) do if not node.supported then
				for _,other in ipairs(node.edges) do if other.supported then node.supported=true;changed=true;break end end
			end end
		end
	end
	if not source and not context.correction_only then
		-- The fast current-support path stops at its first terrain/object witness.
		-- That is sufficient to ground a piece, but cannot establish that a saved
		-- native edge disappeared. Check only missing recorded edges explicitly;
		-- do not turn a new terrain witness into an unverified preservation claim.
		local identities
		local function find_contact(key)
			if not identities then
				identities={}
				for _,r in ipairs(context.list) do if IsValid(r.obj) then
					local id=Identity(context.map,r.obj)
					for _,n in ipairs(r.nodes or {}) do
						local k=id..":"..n.key
						if identities[k]~=nil then identities[k]=false else identities[k]=n end
					end
				end end
			end
			return identities[key]
		end
		for _,node in ipairs(nodes) do
			local baseline=node.record.obj.SuperBigMapSupportBaseline
			local before=baseline and baseline.components[node.key]
			if node.supported and before and before.supported then
				local retained=false
				for contact in pairs(before.contacts) do if node.contacts[contact] then retained=true;break end end
				if not retained then for contact in pairs(before.contacts) do
					local key=contact:match("^object:(.+)$") or contact:match("^ceiling:(.+)$")
					local other=key and find_contact(key)
					if other and other~=node and other.record.complete and not other.partial
						and Overlap(node.bounds,other.bounds,tolerance) and ComponentContact(node,other,tolerance) then
						node.contacts[contact]=true;break
					end
				end end
			end
		end
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

local function Protected(method,map,...)
	local bounded=method=="FinishCapture" or method=="Validate" or method=="Recheck" or method=="CaptureGroup" or method=="CheckPlacements" or method=="Correction" or method=="BuildDecorPlacement"
	local current,sleep,can_yield=Global("CurrentThread"),Global("Sleep"),Global("CanYield")
	local owner=type(current)=="function" and current() or main_owner
	if map then
		while active_checks[map] and active_checks[map]~=owner do
			if type(sleep)~="function" or type(can_yield)~="function" or not can_yield() then
				Validator.Failure(map,method,"another decoration check owns this map");return nil
			end
			sleep(10)
		end
	end
	local owns=map and not active_checks[map]
	if owns then active_checks[map]=owner end
	local pause,resume=Global("PauseInfiniteLoopDetection"),Global("ResumeInfiniteLoopDetection")
	-- These loops are bounded by the captured object/triangle arrays. Keep the
	-- engine's transaction atomic, restoring its guard even when inspection fails.
	if bounded and type(pause)=="function" then pause("SuperBigMapDecorationValidation") end
	local ok,result=pcall(Validator[method],map,...)
	if bounded and type(resume)=="function" then resume("SuperBigMapDecorationValidation") end
	if owns then active_checks[map]=nil end
	if not ok then Validator.Failure(map,method,result);return nil end
	return result
end

function Validator.Run(method,map,...)
	if not Enabled() then return nil end
	return Protected(method,map,...)
end

function Validator.Capture(map,obj,skip,important)
	local context=contexts[map]
	if not context or context.by_object[obj] then return end
	if context.restoring then RestoreBaseline(map,obj) end
	if type(obj.SuperBigMapSupportId)=="number" then
		map.SuperBigMapSupportIdSequence=max(map.SuperBigMapSupportIdSequence or 0,obj.SuperBigMapSupportId)
	end
	local kind=Global("IsKindOf")
	local record={obj=obj,relevant=Relevant(obj,skip,important),projected=Projected(obj),
		editor_only=type(kind)=="function" and kind(obj,"EditorVisibleObject") or false}
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
			render_kind=record.nonphysical,
			parent=Identity(map,record.pose.parent),components={}}
		baseline.composition_signature=Geometry.CompositionSignature(record.asset)
		local matrix=Matrix(record)
		baseline.composition_pose={origin={},columns=matrix.columns,scale=record.pose.scale}
		for a=1,3 do baseline.composition_pose.origin[a]=matrix.origin[a]+record.pose.shift[a] end
		baseline.composition_frames={}
		for _,node in ipairs(record.nodes or {}) do
			baseline.components[node.key]={contacts=node.contacts,supported=node.supported or false,
				defect=node.defect or false}
			-- Save the settled bone-to-object transform. A shared mesh identity
			-- alone cannot prove that an animated fragment retained its pose.
			local frame={}
			for _,p in ipairs({{0,0,0},{1,0,0},{0,1,0},{0,0,1}}) do
				frame[#frame+1]=node.transform_record==record and p
					or Local(record,World(node.transform_record or record,p))
			end
			baseline.composition_frames[node.key]=frame
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
local function DecorGroupContext(map,objects)
	local context={map=map,source_map=map,list={},by_object={},capture_ms=0,incomplete=true}
	for _,obj in ipairs(objects) do if IsValid(obj) then
		local c=SBM.ObjectClone
		local record={obj=obj,relevant=Relevant(obj,c.ShouldSkipObject(obj),c.IsImportantSectorObject(obj)),projected=Projected(obj)}
		context.list[#context.list+1]=record;context.by_object[obj]=record
	end end
	return context
end
function Validator.CaptureGroup(map,objects)
	if not Enabled() then return end
	local context=DecorGroupContext(map,objects)
	FinishCapture(context)
	local main=contexts[map]
	if main then
		main.capture_ms=main.capture_ms+context.capture_ms
		for _,record in ipairs(context.list) do
			if not main.by_object[record.obj] then main.list[#main.list+1]=record;main.by_object[record.obj]=record end
		end
	end
	return context
end

-- Placement needs the prefab's own support topology even when exhaustive
-- diagnostics are disabled. Inspect this new group only, reuse shared assets,
-- and return a value-only placement plan. No existing decoration is scanned or
-- moved; the normal diagnostic map reports/ledgers stay disabled in release mode.
function Validator.BuildDecorPlacement(map,objects,center,factor)
	local context
	if Enabled() then context=Validator.CaptureGroup(map,objects)
	else context=DecorGroupContext(map,objects);context.placement_only=true;Scan(context,true) end
	local parents,entries={},{}
	local terrain=Global("terrain")
	local width,height=map:GetMapSize()
	local function flat_height(bounds)
		if type(terrain.GetMinMaxHeight)~="function" or bounds[1]<0 or bounds[2]<0
			or bounds[4]>=width or bounds[5]>=height then return nil end
		-- Include interpolation neighbours and integer point rounding. Equal
		-- extrema certify this entire region, not just sampled mesh vertices.
		local tile=Global("const").HeightTileSize
		local low,high=terrain.GetMinMaxHeight(map,Global("box")(
			max(0,floor(bounds[1])-tile),max(0,floor(bounds[2])-tile),
			min(width-1,math.ceil(bounds[4])+tile),min(height-1,math.ceil(bounds[5])+tile)))
		if type(low)=="number" and low==high then return low end
	end
	-- The terrain is immutable for this synchronous stamp plan. Native vertices
	-- across components/LODs often quantize to the same XY query. Keep the cache
	-- local to this plan so no placement/load/terraform can reuse stale heights.
	local heights={}
	local terrain_height=terrain.GetHeight
	local function height_at(x,y)
		x,y=floor(x+.5),floor(y+.5)
		local row=heights[x];if not row then row={};heights[x]=row end
		-- The stock XY overload reads the same integer coordinates without an
		-- intermediate Lua array and native point allocation for each query.
		if row[y]==nil then row[y]=terrain_height(map,x,y) end
		return row[y]
	end
	local function root(record)
		while parents[record]~=record do record=parents[record] end
		return record
	end
	local linked={}
	for _,record in ipairs(context.list) do for _,node in ipairs(record.nodes or {}) do
		for _,other in ipairs(node.edges or {}) do if other.record~=record then
			linked[record]=true;linked[other.record]=true
		end end
	end end
	local function zero_offset(record,p,ratio)
		if linked[record] or #(record.nodes or {})==0 then return false end
		local old=record.pose.origin;local roots=0
		for _,node in ipairs(record.nodes) do
			if not node.supported or node.partial or node.geometry.animated then return false end
			local b=WorldBounds(node.transform_record or record,node.component.bounds)
			-- A padded complete mesh box bounds source visible height from above.
			-- A real target vertex above half that bound proves the visibility rule
			-- without needing the exact source-height/clearance maxima.
			local visible=max(2,(b[6]-b[3])*.5+1)
			if not (visible<math.huge) then return false end
			for a=1,2 do
				local limit=a==1 and width or height
				if p[a]+(b[a]-old[a])*ratio<1 or p[a]+(b[a+3]-old[a])*ratio>=limit-1 then return false end
			end
			local terrain_root=node.contacts.terrain==true
			if terrain_root then roots=roots+1 end
			local grounded,exposed=not terrain_root,false
			for _,v in ipairs(node.component.samples or {}) do
				local w=World(node.transform_record or record,v)
				local x,y,z=p[1]+(w[1]-old[1])*ratio,p[2]+(w[2]-old[2])*ratio,p[3]+(w[3]-old[3])*ratio
				local h=height_at(x,y)
				if type(h)~="number" then return false end
				local clearance=z-h
				if clearance<=0 then grounded=true end
				if clearance>=visible then exposed=true end
				if grounded and exposed then break end
			end
			if not grounded or not exposed then return false end
		end
		-- For every root, exact minimum clearance <= 0; for every component,
		-- exact maximum clearance >= its required visible height. Thus the full
		-- planner's interval contains zero and its preferred shift is EXACTLY zero.
		return roots>0
	end
	local cx,cy,cz=center:xyz()
	for _,record in ipairs(context.list) do if record.relevant then
		local obj=record.obj
		if not record.complete or (not record.nonphysical and #(record.nodes or {})==0) or record.pose.parent then
			return {ok=false,reason="native decor geometry or free-standing pose unavailable"}
		end
		local sc=obj:GetScale();local ns=SBM.ObjectClone.ObjectScalesWithTerrain(obj)
			and min(500,max(1,floor(sc*factor+.5))) or sc
		local old=record.pose.origin
		local p={floor(cx+(old[1]-cx)*factor+.5),floor(cy+(old[2]-cy)*factor+.5),floor(cz+(old[3]-cz)*factor+.5)}
		local entry={obj=obj,position=p,scale=ns,components={}}
		entries[record]=entry;parents[record]=record
		if record.nonphysical then p[3]=terrain.GetHeight(map,Point(p)) end
		local px,py,pz=p[1],p[2],p[3]
		local sx,sy,sz=old[1],old[2],old[3]
		local ratio=ns/(sc+0.0)
		entry.zero_offset_proven=zero_offset(record,p,ratio)
		if not entry.zero_offset_proven then
		for _,node in ipairs(record.nodes or {}) do
			if not node.supported or node.partial or node.geometry.animated then
				return {ok=false,reason="native decor component has no verified rigid support"}
			end
			local c={terrain=node.contacts.terrain==true}
			local bottom,top=math.huge,-math.huge
			local b=WorldBounds(node.transform_record or record,node.component.bounds)
			local source_flat=flat_height(b)
			local target_bounds={}
			for a=1,3 do target_bounds[a]=p[a]+(b[a]-old[a])*ratio;target_bounds[a+3]=p[a]+(b[a+3]-old[a])*ratio end
			c.flat_height=flat_height(target_bounds)
			local low,high,exposed=math.huge,-math.huge,-math.huge
			local transform=node.transform_record or record
			local matrix=Matrix(transform);local columns=matrix.columns
			local ox,oy,oz=matrix.origin[1]+transform.pose.shift[1],matrix.origin[2]+transform.pose.shift[2],matrix.origin[3]+transform.pose.shift[3]
			-- Hoist this component's invariant coefficients and extrema out of the
			-- vertex loop: no repeated nested-table reads or min/max C calls.
			local xx,xy,xz=columns[1][1],columns[2][1],columns[3][1]
			local yx,yy,yz=columns[1][2],columns[2][2],columns[3][2]
			local zx,zy,zz=columns[1][3],columns[2][3],columns[3][3]
			local target_flat=c.flat_height
			if source_flat and target_flat and zx==0 and zy==0 then
				-- Both padded terrain regions are certified constant, and local X/Y
				-- cannot affect world Z. Component bounds contain the EXACT vertex
				-- Z extrema, so this is the same all-vertex result without a second
				-- geometry walk. The target bounds above also certify map containment.
				low=oz+zz*node.component.bounds[3]
				high=oz+zz*node.component.bounds[6]
				if low>high then low,high=high,low end
				exposed=high-source_flat
				bottom=pz+(low-sz)*ratio-target_flat
				top=pz+(high-sz)*ratio-target_flat
			else
			for _,vi in ipairs(Geometry.SupportVertices(node.geometry,node.component)) do
				local v=node.geometry.vertices[vi];local vx,vy,vz=v[1],v[2],v[3]
				local wx=ox+xx*vx+xy*vy+xz*vz
				local wy=oy+yx*vx+yy*vy+yz*vz
				local wz=oz+zx*vx+zy*vy+zz*vz
				local h=source_flat or height_at(wx,wy)
				if wz<low then low=wz end
				if wz>high then high=wz end
				local visible=wz-h;if visible>exposed then exposed=visible end
				local tx,ty,tz=px+(wx-sx)*ratio,py+(wy-sy)*ratio,pz+(wz-sz)*ratio
				if tx<0 or ty<0 or tx>=width or ty>=height then return {ok=false,reason="support-island terrain unavailable"} end
				local target_height=target_flat or height_at(tx,ty)
				if type(target_height)~="number" then return {ok=false,reason="support-island terrain unavailable"} end
				local clearance=tz-target_height
				if clearance<bottom then bottom=clearance end
				if clearance>top then top=clearance end
			end
			end
			c.clearance={bottom,top}
			c.visible=max(2,min(high-low,max(0,exposed))*.5)
			entry.components[#entry.components+1]=c
		end
		end
	end end
	for record in pairs(entries) do for _,node in ipairs(record.nodes or {}) do for _,other in ipairs(node.edges or {}) do
		if entries[other.record] then parents[root(record)]=root(other.record) end
	end end end
	local groups={}
	for record,entry in pairs(entries) do
		local r=root(record);groups[r]=groups[r] or {entries={},components={}}
		local g=groups[r];g.entries[#g.entries+1]=entry
		for _,c in ipairs(entry.components) do g.components[#g.components+1]=c end
	end
	local result={ok=true,placements={},groups=0}
	local function at(x,y)
		if x<0 or y<0 or x>=width or y>=height then return nil end
		return height_at(x,y)
	end
	for _,group in pairs(groups) do
		local dz,why=0
		if #group.components>0 then dz,why=SBM.DecorationSeating.PlanSupportIsland(group.components,at) end
		if dz==nil then return {ok=false,reason=why} end
		result.groups=result.groups+1
		for _,entry in ipairs(group.entries) do entry.position[3]=entry.position[3]+dz;result.placements[entry.obj]=entry end
	end
	return result
end
function Validator.PlanDecorPlacement(map,objects,center,factor)
	return Protected("BuildDecorPlacement",map,objects,center,factor)
end

local function Fingerprint(obj)
	local p=obj:GetVisualPos();local parent=obj:GetParent()
	local x,y,z=p:xyz()
	local forced=type(obj.GetForcedLOD)=="function" and obj:GetForcedLOD()
	return concat({obj:GetEntity(),tostring(obj:GetState()),x,y,z,tostring(obj:GetWorldScale()),
		tostring(type(obj.GetAxis)=="function" and obj:GetAxis()),tostring(type(obj.GetAngle)=="function" and obj:GetAngle()),
		tostring(obj:GetClipPlane()),tostring(parent),tostring(type(obj.GetMirrored)=="function" and obj:GetMirrored()),
		tostring(type(obj.GetAnimPhase)=="function" and obj:GetAnimPhase(1)),
		tostring(type(obj.GetWarped)=="function" and obj:GetWarped()),
		tostring(type(obj.GetSkewX)=="function" and obj:GetSkewX()),tostring(type(obj.GetSkewY)=="function" and obj:GetSkewY()),tostring(forced)},"|")
end

-- Compare authored composition separately from physical support. Inherited
-- native gaps stay visible in current_geometry_status/findings; they are never
-- silently relabelled as supported, and missing source evidence stays unknown.
function Validator.CompareComposition(before,after)
	if not before or not after or not before.complete or not after.complete
		or not before.signature or before.signature~=after.signature
		or before.parent~=after.parent then return false,"composition identity unavailable or changed" end
	local rooted,inherited=0,0
	for key,a in pairs(after.components) do
		local b=before.components[key]
		if not b then return false,"rendered component absent from native capture" end
		if not a.frame_preserved then return false,"native fragment pose changed or unavailable" end
		if b.supported then
			if not a.retained then return false,"native support relationship lost" end
			rooted=rooted+1
		else
			inherited=inherited+1
		end
	end
	for key in pairs(before.components) do
		if not after.components[key] and not (after.clipped and after.clipped[key]) then
			return false,"native component missing without verified clipping"
		end
	end
	if rooted==0 then return false,"no preserved rooted native component" end
	return true,inherited
end

-- Only edges proved in BOTH source and expanded geometry enter this graph.
-- The capture's first witness is not an exhaustive list of native contacts.
function Validator.PreservedContactGraph(graph)
	local reached={}
	for key,node in pairs(graph) do if node.root then reached[key]=true end end
	local changed=true
	while changed do
		changed=false
		for key,node in pairs(graph) do if not reached[key] then
			for other in pairs(node.edges or {}) do if reached[other] then reached[key]=true;changed=true;break end end
		end end
	end
	return reached
end

local function PreservedContacts(context,map)
	local graph,nodes,source,signatures={},{},{},{}
	local function source_node(node)
		if source[node]~=nil then return source[node] or nil end
		source[node]=false
		local r=node.record;local b=r.obj.SuperBigMapSupportBaseline
		if not b or not b.geometry_complete or not b.composition_pose or not b.composition_frames then return end
		if signatures[r]==nil then signatures[r]=b.composition_signature~=nil and b.composition_signature==Geometry.CompositionSignature(r.asset) end
		local frame=b.composition_frames[node.key]
		if not signatures[r] or not frame or #frame~=4 then return end
		local pose=b.composition_pose;local native={pose={matrix=pose,shift={0,0,0},scale=pose.scale}}
		local origin=World(native,frame[1]);local columns={}
		for i=1,3 do local p=World(native,frame[i+1]);columns[i]={p[1]-origin[1],p[2]-origin[2],p[3]-origin[3]} end
		local transform={pose={matrix={origin=origin,columns=columns},shift={0,0,0},scale=pose.scale}}
		local n={record=transform,geometry=node.geometry,component=node.component}
		n.bounds=WorldBounds(transform,node.component.bounds);source[node]=n;return n
	end
	for _,r in ipairs(context.list) do if IsValid(r.obj) then
		local id=Identity(map,r.obj);local b=r.obj.SuperBigMapSupportBaseline
		for _,n in ipairs(r.nodes or {}) do if n.supported and r.complete and b and b.geometry_complete then
			local key=id..":"..n.key;nodes[key]=n;local entry={edges={}};graph[key]=entry
			local old=b.components[n.key]
			if old and old.supported then for contact in pairs(old.contacts) do if n.contacts[contact] then entry.root=true;break end end end
		end end
	end end
	local tolerance=min(2,Global("const").HeightTileSize/50.0)
	for key,entry in pairs(graph) do if not entry.root then
		local node=nodes[key];local a=source_node(node)
		if a then for contact in pairs(node.contacts) do
			local other_key=contact:match("^object:(.+)$") or contact:match("^ceiling:(.+)$")
			local other=other_key and nodes[other_key];local b=other and source_node(other)
			if b and Overlap(a.bounds,b.bounds,tolerance) and ComponentContact(a,b,tolerance) then entry.edges[other_key]=true end
		end end
	end end
	return Validator.PreservedContactGraph(graph)
end

-- An affine displacement's norm is convex: the eight box corners bound EVERY
-- enclosed mesh vertex and triangle. Compare world-space error, not coefficients
-- near a distant inverse-bind origin. The tolerance is the existing contact
-- precision budget, never an increased tolerance chosen from a test scenario.
function Validator.AffineBoundsAgree(bounds,expected,actual,tolerance)
	if not bounds or not expected or not actual or not expected.origin or not actual.origin
		or not expected.columns or not actual.columns or type(tolerance)~="number" or tolerance<0 then return false end
	for a=1,3 do if type(bounds[a])~="number" or type(bounds[a+3])~="number" or bounds[a]>bounds[a+3] then return false end end
	for x=0,1 do for y=0,1 do for z=0,1 do
		local p={bounds[1+x*3],bounds[2+y*3],bounds[3+z*3]};local squared=0
		for a=1,3 do
			local d=(actual.origin[a] or 0/0)-(expected.origin[a] or 0/0)
			for c=1,3 do
				local ac,ec=actual.columns[c],expected.columns[c]
				d=d+((ac and ac[a] or 0/0)-(ec and ec[a] or 0/0))*p[c]
			end
			if d~=d or d==math.huge or d==-math.huge then return false end
			squared=squared+d*d
		end
		if squared>tolerance*tolerance then return false end
	end end end
	return true
end

local function CompositionFramePreserved(record,node,frame)
	if not frame or #frame~=4 then return false end
	local origin=World(record,frame[1]);local columns={}
	for i=1,3 do
		local p=World(record,frame[i+1]);columns[i]={p[1]-origin[1],p[2]-origin[2],p[3]-origin[3]}
	end
	local transform=node.transform_record or record;local m=Matrix(transform);local current={origin={},columns=m.columns}
	for a=1,3 do current.origin[a]=m.origin[a]+transform.pose.shift[a] end
	return Validator.AffineBoundsAgree(node.component.bounds,{origin=origin,columns=columns},current,
		min(2,Global("const").HeightTileSize/50.0))
end

local function CompositionEvidence(record,baseline,map,preserved_contacts)
	if not baseline or not baseline.composition_frames then return false,"native composition not captured" end
	local after={complete=record.complete,signature=Geometry.CompositionSignature(record.asset),
		parent=Identity(map,record.pose.parent),components={},clipped=record.clipped_nodes}
	for _,node in ipairs(record.nodes or {}) do
		local b=baseline.components[node.key];local retained=false
		if b and node.supported then
			for contact in pairs(b.contacts) do if node.contacts[contact] then retained=true;break end end
		end
		if not retained and preserved_contacts then retained=preserved_contacts[Identity(map,record.obj)..":"..node.key] or false end
		local same=CompositionFramePreserved(record,node,baseline.composition_frames[node.key])
		after.components[node.key]={retained=retained,frame_preserved=same}
	end
	return Validator.CompareComposition({complete=baseline.geometry_complete,signature=baseline.composition_signature,
		parent=baseline.parent,components=baseline.components},after)
end

function Validator.Validate(map,reason)
	local context=contexts[map];if not context or (not Enabled() and not context.correction_only) then return nil end
	local started=Tick();Scan(context,false)
	local report={version=1,reason=reason or "generation",diagnostic_only=true,
		valid=0,confirmed_defect=0,inconclusive=0,native_composition_verified=0,instances={},capture_ms=context.capture_ms,
		contact_tolerance_world_units=min(2,Global("const").HeightTileSize/50.0),
		capture_profile=context.capture_profile,validation_profile=context.profile}
	local preserved_contacts
	for _,record in ipairs(context.list) do if record.relevant and IsValid(record.obj) then
		local cached=context.selection and not context.selection[record] and record.obj.SuperBigMapSupportValidation
		if cached then
			local key=cached.status=="confirmed defect" and "confirmed_defect" or cached.status
			report[key]=report[key]+1;report.instances[#report.instances+1]=cached
			if cached.native_composition_verified then report.native_composition_verified=report.native_composition_verified+1 end
		else
		local baseline=not context.correction_only and record.obj.SuperBigMapSupportBaseline or nil
		local changed=baseline and baseline.parent~=Identity(map,record.pose.parent)
		local complete=record.complete
		local preserved=baseline~=nil
		if baseline and baseline.render_kind~=record.nonphysical then preserved=false end
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
		if record.nonphysical and not context.incomplete and not changed then current_status="valid" end
		local repair=record.obj.SuperBigMapSupportRepair
		local repaired=repair and repair.version==1 and repair.pose==PersistedPoseKey(record.obj)
			and ((baseline and baseline.geometry_complete) or (context.correction_only and record.correction_complete))
			and current_status=="valid" and not changed
		if repaired and repair.forced_lod~=nil then repaired=record.asset.forced_lod==repair.forced_lod end
		local clearing_repair=current_status=="valid" and not changed and VerifiedRubbleClearing(record,baseline,repair)
		if clearing_repair then repaired=true;complete=record.complete and baseline.geometry_complete end
		local status,why=Validator.Classify(record.nodes or {},complete and (preserved or repaired) and not context.incomplete,changed)
		if record.nonphysical and current_status=="valid" and baseline and baseline.render_kind==record.nonphysical
			and baseline.entity==record.obj:GetEntity() and complete then status="valid";why=record.nonphysical end
		-- These post-generation logic markers have no entity and no rendering
		-- override. There is no physical support relationship to preserve; unlike
		-- missing decoration geometry, their empty coverage is positively known.
		if record.nonphysical=="native non-rendering logical marker" and current_status=="valid" then
			status="valid";why=record.nonphysical
		end
		if record.nonphysical=="verified native particle attachment" and current_status=="valid" then
			status="valid";why=record.nonphysical
		end
		if repaired and status=="valid" then why="current rendered components supported after a recorded rigid correction" end
		if clearing_repair and status=="valid" then why="verified native clearing transition with supported rendered components" end
		local key=status=="confirmed defect" and "confirmed_defect" or status
		report[key]=report[key]+1
		local composition,composition_detail=false
		if status~="valid" then
			composition,composition_detail=CompositionEvidence(record,baseline,map)
			if not composition and composition_detail=="native support relationship lost" then
				preserved_contacts=preserved_contacts or PreservedContacts(context,map)
				composition,composition_detail=CompositionEvidence(record,baseline,map,preserved_contacts)
			end
		end
		if composition then report.native_composition_verified=report.native_composition_verified+1 end
		local row={handle=record.obj.handle,id=Identity(map,record.obj),entity=record.obj:GetEntity(),class=record.obj.class,status=status,
			reason=status=="confirmed defect" and why or record.reason or why,
			geometry_complete=complete or false,support_preserved=preserved,current_geometry_status=current_status,
			render_kind=record.nonphysical or "physical geometry",
			placement_repaired=repaired or false,
			native_clearing_transition=clearing_repair or false,
			native_composition_verified=composition or false,native_composition_detail=composition_detail,
			effect_evidence=record.asset.effect,
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
		-- Fingerprints are for diagnostic lifecycle change detection. This short
		-- correction scope is discarded after the transaction; it needs only the
		-- candidate/support bounds used by CheckPlacements, not a saved pose string
		-- and another native bbox query for every unrelated object on the map.
		if not context.correction_only then record.fingerprint=Fingerprint(record.obj) end
		if not context.correction_only or record.relevant then record.last_bounds=BoxBounds(record.obj:GetObjectBBox()) end
	end end
	if not context.correction_only then PersistBaselines(context) end
	report.validation_ms=Tick()-started;report.errors=context.errors;map.SuperBigMapDecorationValidation=report
	if Enabled() or (SBM.Config or {}).DEBUG_LOGGING_ENABLED==true then
		Global("print")(format("[SBM decoration validation] %s: valid=%d defect=%d inconclusive=%d capture=%dms validate=%dms",
			report.reason,report.valid,report.confirmed_defect,report.inconclusive,report.capture_ms,report.validation_ms))
	end
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
	if not Enabled() or not map then return end
	-- Never race source capture/transformation or pull underground checks into T1.
	local underground=SBM.Engine.MapDataEnvironment(map.mapdata)=="Underground"
	if underground and map.SuperBigMapUndergroundPrepared~=true then return end
	if not underground and map.SuperBigMapSurfacePostPipelineRevalidationComplete~=true and not loaded_maps[map] then return end
	local create,sleep=Global("CreateRealTimeThread"),Global("Sleep")
	if type(create)~="function" then return end
	-- Events after the active census began need another census. Coalesce them,
	-- but never discard a newly spawned cave-in just because a check is running.
	if scheduled[map] then scheduled[map].pending=reason or "lifecycle change";return end
	local job={pending=reason or "lifecycle change"};scheduled[map]=job
	create(function()
		repeat
			local next_reason=job.pending;job.pending=nil
			sleep(1)
			if not Global("Maps") or Global("Maps")[map.slot]~=map then break end
			Validator.Run("Recheck",map,next_reason)
		until not job.pending
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

function Validator.RecordRubbleSeating(map,obj,from,to)
	local context=contexts[map];local record=context and context.by_object[obj]
	if not record or not record.complete or obj.class~="TunnelBlockerRubble"
		or obj:GetEntity()~="CaveIn_TunnelBlocker_1" then return false end
	obj.SuperBigMapSupportRepair={version=1,pose=PersistedPoseKey(obj),from=from,to=to,forced_lod=0,
		reason="native detailed tunnel rubble with verified fragment seating",source_id=Identity(map,obj)}
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
			and (not context.correction_only or context.repair_targets[obj])
			and not record.pose.parent and #record.nodes>0 then
			local safe=true;local unsupported=false
			for _,node in ipairs(record.nodes) do
				if node.geometry.animated or node.partial or node.unknown_support or #node.edges>0 then safe=false end
				if not node.supported then unsupported=true end
				-- A grounded member does not forbid a rigid group correction by
				-- itself. The planner must retain every component's visible extent;
				-- attachment/object edges and dependents still veto movement here.
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
					for _,vi in ipairs(Geometry.SupportVertices(node.geometry,node.component)) do
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
	local moved={}
	for _,own in ipairs(record.nodes) do
		local source=own.transform_record or record
		local transform={obj=obj,pose={matrix=Matrix(source),scale=source.pose.scale,shift={}}}
		for i=1,3 do transform.pose.shift[i]=source.pose.shift[i]+delta[i] end
		moved[#moved+1]={record=record,transform_record=transform,geometry=own.geometry,component=own.component}
	end
	for _,node in ipairs(context.index:Query(bounds,2)) do
		if node.record.obj~=obj then
			if node.unknown or node.partial or not node.record.complete then return false,node.record.obj:GetEntity() end
			for _,own in ipairs(moved) do
				-- Shared BVHs prune irrelevant triangle pairs. Empty placement needs
				-- proven separation, including containment, not just no crossing faces.
				local contact,separated=ComponentContact(own,node,2)
				if contact or not separated then return false,node.record.obj:GetEntity() end
			end
		end
	end
	return true
end
-- The diagnostic switch must not disable production fixes. A correction-only
-- scope inspects candidate placements and nearby support, not source history,
-- distant wonders, animated cave-ins or every object on map load/switch. Bounds
-- of ALL other objects remain in the index, so omitted geometry can veto a
-- correction but can never become evidence of empty space.
function Validator.Correction(map,layer,apply)
	local prior=contexts[map]
	local old_report,old_progress=map.SuperBigMapDecorationValidation,map.SuperBigMapDecorationValidationProgress
	local context={map=map,list={},by_object={},capture_ms=0,correction_only=true,repair_targets={},positive_only=layer=="Underground"}
	contexts[map]=context
	local ok,result=pcall(function()
		local bounds_index=Validator.Index(6400)
		local terrain=Global("terrain");local width,height=map:GetMapSize()
		local tolerance=min(2,Global("const").HeightTileSize/50.0)
		local candidates={};local eligible=SBM.RockGrounding and SBM.RockGrounding.Eligible
		map:MapForEach("map","CObject",function(obj)
			if not IsValid(obj) then return end
			local kind=Global("IsKindOf")
			local record={obj=obj,relevant=false,projected=Projected(obj),
				editor_only=type(kind)=="function" and kind(obj,"EditorVisibleObject") or false}
			context.list[#context.list+1]=record;context.by_object[obj]=record
			bounds_index:Add({bounds=BoxBounds(obj:GetObjectBBox()),record=record})
			local candidate=false
			if layer=="Underground" then
				candidate=obj.class=="TunnelBlockerRubble" and obj:GetEntity()=="CaveIn_TunnelBlocker_1"
					and not obj.SuperBigMapSupportRepair and not obj.clear_request
					and obj.remaining_work_to_clear==obj.required_work_to_clear
			elseif layer=="Surface" and eligible and eligible(obj) then
				-- A real terrain witness for every connected component rules out the
				-- loose-stone fix. A missing witness only nominates a candidate; the
				-- exact support/separation checks still authorize any actual move.
				record.pose=Pose(obj);BuildNodes(record)
				if record.complete and #record.nodes>0 then
					for _,node in ipairs(record.nodes) do
						local p=node.samples[1]
						if node.geometry.animated or node.partial then candidate=false;break end
						if p[1]<0 or p[2]<0 or p[1]>=width or p[2]>=height
							or p[3]>terrain.GetHeight(map,Point(p))+tolerance then candidate=true end
					end
				end
				record.correction_prebuilt=true
			end
			if candidate then candidates[#candidates+1]=record;context.repair_targets[obj]=true end
		end)
		local selected={};local c=SBM.ObjectClone
		local function select_near(node)
			local near=node.record
			if not near.relevant then
				near.relevant=Relevant(near.obj,c.ShouldSkipObject(near.obj),c.IsImportantSectorObject(near.obj))
			end
		end
		for _,record in ipairs(candidates) do
			record.relevant=true
			local b=BoxBounds(record.obj:GetObjectBBox())
			local range=record.obj.SuperBigMapDecorEnginePass and 32*5*Global("const").HeightTileSize or 2
			local region={b[1]-range,b[2]-range,-1e12,b[4]+range,b[5]+range,1e12}
			if layer=="Surface" then bounds_index:QueryOnce(region,2,selected,select_near) end
		end
		-- Retain precisely the same selected geometry as before. Unselected
		-- objects remain conservative unknown bounds, not newly granted supports.
		for _,record in ipairs(context.list) do
			if record.correction_prebuilt and not record.relevant then
				record.nodes=nil;record.pose=nil;record.correction_prebuilt=nil
			end
		end
		if #candidates>0 then
			if layer=="Underground" then
				-- This service proposes a previously verified, exact-asset blocker
				-- recipe; it does not need to diagnose the original holes again.
				-- Inspect the descriptor/coverage now and explicitly leave physical
				-- support unverified. The strict asset/pose guards in RunUnderground
				-- and the independent positive proof AFTER application still gate
				-- every commit, with full rollback on failure.
				context.index=bounds_index
				for _,record in ipairs(candidates) do
					record.pose=Pose(record.obj);BuildNodes(record)
					record.correction_complete=record.complete
					record.last_bounds=BoxBounds(record.obj:GetObjectBBox())
					record.obj.SuperBigMapSupportValidation={status="inconclusive",current_geometry_status="inconclusive",
						geometry_complete=record.complete,placement_repaired=false,reason="correction proposal awaiting positive support proof"}
				end
			else
				Validator.Validate(map,"correction-only placement evidence")
				for _,record in ipairs(candidates) do record.correction_complete=record.complete end
			end
		end
		return apply(map)
	end)
	contexts[map]=prior
	map.SuperBigMapDecorationValidation=old_report
	map.SuperBigMapDecorationValidationProgress=old_progress
	if not ok then error(result) end
	return result
end

function Validator.WithCorrectionEvidence(map,layer,apply)
	if Enabled() then return apply(map) end
	local result=Protected("Correction",map,layer,apply)
	if not result then
		local failure=map.SuperBigMapDecorationValidation
		error("decoration correction evidence could not be prepared: "..tostring(failure and failure.error))
	end
	return result
end

function Validator.VerifyCorrection(map,changes,reason)
	local context=contexts[map]
	if context and context.correction_only then return Protected("CheckPlacements",map,changes,reason) end
	return Validator.Run("CheckPlacements",map,changes,reason)
end

SBM.DecorationValidation=Validator
