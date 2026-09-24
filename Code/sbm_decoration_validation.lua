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
	return not (a[1]>b[4]+pad or b[1]>a[4]+pad
		or a[2]>b[5]+pad or b[2]>a[5]+pad
		or a[3]>b[6]+pad or b[3]>a[6]+pad)
end

-- Spatial buckets include the complete AABB, not just an object's pivot. Large
-- formations use a separate small list rather than millions of bucket entries.
function Validator.Index(size)
	local index={size=size,buckets={},large={}}
	function index:Add(node)
		local b=node.bounds
		local x0,y0,x1,y1=floor(b[1]/(size+0.0)),floor(b[2]/(size+0.0)),floor(b[4]/(size+0.0)),floor(b[5]/(size+0.0))
		if (x1-x0+1)*(y1-y0+1)>256 then self.large[#self.large+1]=node;return end
		for x=x0,x1 do
			local column=self.buckets[x];if not column then column={};self.buckets[x]=column end
		for y=y0,y1 do
			local bucket=column[y]
			if not bucket then bucket={};column[y]=bucket end
			bucket[#bucket+1]=node
		end end
	end
	function index:Query(bounds,pad)
		local out,seen={},{}
		local function take(node)
			if not seen[node] and Overlap(node.bounds,bounds,pad) then seen[node]=true;out[#out+1]=node end
		end
		for x=floor((bounds[1]-pad)/(size+0.0)),floor((bounds[4]+pad)/(size+0.0)) do
			local column=self.buckets[x]
			if column then
			for y=floor((bounds[2]-pad)/(size+0.0)),floor((bounds[5]+pad)/(size+0.0)) do
				for _,node in ipairs(column[y] or {}) do take(node) end
			end
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
			local column=self.buckets[x]
			if column then
			for y=floor((bounds[2]-pad)/(size+0.0)),floor((bounds[5]+pad)/(size+0.0)) do
				for _,node in ipairs(column[y] or {}) do take(node) end
			end
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
	local separated,strictly_separated=Geometry.TrianglesSeparated(a,b,tolerance)
	if separated then return false end
	if not strictly_separated then return true end
	local limit=tolerance*tolerance
	-- A positive exact closest-feature witness is sufficient. A negative answer
	-- still requires every vertex/face and edge/edge pair, in the original order.
	for i=1,3 do
		if Validator.TriangleDistanceSquared(a[i],b[1],b[2],b[3])<=limit
			or Validator.TriangleDistanceSquared(b[i],a[1],a[2],a[3])<=limit then return true end
		for j=1,3 do
			if SegmentPairDistanceSquared(a[i],a[i%3+1],b[j],b[j%3+1])<=limit then return true end
		end
	end
	return false
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
	-- Scaling eligibility is not support eligibility. A fixed gameplay structure
	-- can replace terrain with a rendered floor/rim beside its hole. Inspect its
	-- actual geometry before classifying nearby rocks: an unknown whole-object
	-- box cannot prove either contact or a safe correction. This grants no right
	-- to move the structure and does not waive incomplete mesh/material evidence.
	local hole_flag=(Global("EntitySurfaces") or {}).TerrainHole
	local has_surfaces=Global("HasAnySurfaces")
	if hole_flag and type(has_surfaces)=="function" and has_surfaces(obj,hole_flag,true) then return true end
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
	-- Only the private same-frame contact oracle marks this exact identity
	-- transform. Its immutable decoded coordinates are already in query space.
	if record.pose.asset_local then return p end
	local m=Matrix(record);local o,s,c=m.origin,record.pose.shift,m.columns
	local x,y,z=p[1],p[2],p[3];local a,b,d=c[1],c[2],c[3]
	return {o[1]+s[1]+a[1]*x+b[1]*y+d[1]*z,
		o[2]+s[2]+a[2]*x+b[2]*y+d[2]*z,
		o[3]+s[3]+a[3]*x+b[3]*y+d[3]*z}
end

local function Local(record,p)
	if record.pose.asset_local then return p end
	local m=Matrix(record);local c=m.columns
	local q={p[1]-m.origin[1]-record.pose.shift[1],p[2]-m.origin[2]-record.pose.shift[2],p[3]-m.origin[3]-record.pose.shift[3]}
	-- Rigid engine transforms have orthogonal columns and one uniform scale.
	return {Dot(q,c[1])/(Dot(c[1],c[1])+0.0),Dot(q,c[2])/(Dot(c[2],c[2])+0.0),Dot(q,c[3])/(Dot(c[3],c[3])+0.0)}
end

local function FoundationEvidence(map,obj,asset)
	if not asset or not asset.complete or asset.animated or not Geometry.FoundationBoundary then return nil end
	local found=asset.foundation_descriptors
	if not found then
	local counts,identical_rims={},{};found={}
	for _,part in ipairs(asset.parts or {}) do counts[part.lod or 0]=(counts[part.lod or 0] or 0)+1 end
	for _,part in ipairs(asset.parts or {}) do
		local g=part.mesh and part.mesh.geometry
		-- Multiple material parts can have open seam edges despite a closed
		-- assembled surface. Do not infer a foundation from those partial meshes.
		if g and not g.animated and part.material_complete~=false and counts[part.lod or 0]==1 then
			for _,c in ipairs(g.components) do
				local rim=Geometry.FoundationBoundary(g,c)
				if rim then
					-- Exact rendered boundary identity, not matching bounds or rounded
					-- coordinates. Different LOD bodies can retain the same opening;
					-- its terrain proof needs measuring only once at this object pose.
					local names,edges={},{}
					for _,vi in ipairs(rim.vertices) do
						local p=g.vertices[vi];names[vi]=string.format("%.17g,%.17g,%.17g",p[1],p[2],p[3])
					end
					for _,e in ipairs(rim.edges) do
						local a,b=names[e[1]],names[e[2]];if a>b then a,b=b,a end
						edges[#edges+1]=a..":"..b
					end
					table.sort(edges);local key=table.concat(edges,";")
					local entry={geometry=g,component=c,rim=rim,equivalent=identical_rims[key]}
					if not entry.equivalent then identical_rims[key]=entry end
					found[#found+1]=entry
				end
			end
		end
	end
	asset.foundation_descriptors=found
	end
	if #found==0 then return nil end
	if obj:GetParent() or Projected(obj) or obj:GetClipPlane()~=0
		or obj:GetSkewX()~=0 or obj:GetSkewY()~=0 or obj:GetWarped() then return nil end
	local distorted=obj:GetTerrainDistortedSupport()
	if distorted~=false and distorted~="disabled" then return nil end
	local record={obj=obj,pose=Pose(obj)}
	-- Vanilla also uses these meshes upside down as caps on rock stacks. The
	-- asset-local open bottom then faces UP, not toward the ground. Burying that
	-- rim would erase the entire cap. This is not a support exemption: the
	-- ordinary rendered-component/terrain/neighbour proof still checks the cap.
	if Matrix(record).columns[3][3]<=0 then return nil end
	local width,height=map:GetMapSize();local terrain=Global("terrain");local tile=Global("const").HeightTileSize
	-- LODs share most terrain corners. This cache belongs only to this single
	-- synchronous actual-pose inspection, never to a later move or map change.
	local heights={}
	local function height_at(x,y)
		local col=heights[x];if not col then col={};heights[x]=col end
		if col[y]==nil then col[y]=terrain.GetHeight(map,x,y) end
		return col[y]
	end
	local result={gap=-math.huge,by_component={}}
	for _,entry in ipairs(found) do
		local shared=entry.equivalent and result.by_component[entry.equivalent.component]
		if shared then result.by_component[entry.component]=shared else
		local points={};local b={math.huge,math.huge,math.huge,-math.huge,-math.huge,-math.huge}
		for _,i in ipairs(entry.rim.vertices) do
			local p=World(record,entry.geometry.vertices[i]);points[i]=p
			for a=1,3 do b[a]=min(b[a],p[a]);b[a+3]=max(b[a+3],p[a]) end
		end
		local gap;local box=Global("box")
		if type(terrain.GetMinMaxHeight)=="function" and type(box)=="function"
			and b[1]>=tile and b[2]>=tile and b[4]+tile<width and b[5]+tile<height then
			local lower,upper=terrain.GetMinMaxHeight(map,box(floor(b[1])-tile,floor(b[2])-tile,math.ceil(b[4])+tile,math.ceil(b[5])+tile))
			-- Over a certified flat rectangle, the rim's maximum Z is the exact
			-- maximum clearance. No edge/cell crossings add another extremum.
			if type(lower)=="number" and (lower==upper or lower>=b[6]) then gap=b[6]-lower end
		end
		if not gap then gap=Geometry.FoundationClearance(points,entry.rim.edges,height_at,tile,width,height) end
		if not gap then result.incomplete=true;return result end
		result.gap=max(result.gap,gap)
		result.by_component[entry.component]={points=points,edges=entry.rim.edges,gap=gap,tile=tile,width=width,height=height,maximum_z=b[6]}
		end
	end
	return result
end

function Validator.FoundationEvidence(map,obj)
	return FoundationEvidence(map,obj,Geometry.Instance(obj))
end

local function WorldBounds(record,b)
	if record.pose.asset_local then return b end
	local m=Matrix(record);local c=m.columns
	-- A captured matrix is immutable. Its absolute coefficients are shared by
	-- every node/triangle box in this pose, rather than nine abs calls per box.
	local ac=m.absolute_columns
	if not ac then
		ac={{abs(c[1][1]),abs(c[1][2]),abs(c[1][3])},
			{abs(c[2][1]),abs(c[2][2]),abs(c[2][3])},
			{abs(c[3][1]),abs(c[3][2]),abs(c[3][3])}}
		m.absolute_columns=ac
	end
	local x,y,z=(b[1]+b[4])*0.5,(b[2]+b[5])*0.5,(b[3]+b[6])*0.5
	local hx,hy,hz=(b[4]-b[1])*0.5,(b[5]-b[2])*0.5,(b[6]-b[3])*0.5
	local o,s,c1,c2,c3=m.origin,record.pose.shift,c[1],c[2],c[3]
	local a1,a2,a3=ac[1],ac[2],ac[3]
	local cx=o[1]+s[1]+c1[1]*x+c2[1]*y+c3[1]*z
	local cy=o[2]+s[2]+c1[2]*x+c2[2]*y+c3[2]*z
	local cz=o[3]+s[3]+c1[3]*x+c2[3]*y+c3[3]*z
	local ex=a1[1]*hx+a2[1]*hy+a3[1]*hz
	local ey=a1[2]*hx+a2[2]*hy+a3[2]*hz
	local ez=a1[3]*hx+a2[3]*hy+a3[3]*hz
	return {cx-ex,cy-ey,cz-ez,cx+ex,cy+ey,cz+ez}
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

local function BuildNodes(record,asset)
	local obj=record.obj;asset=asset or Geometry.Instance(obj)
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
						samples={sample},sample_vertices={bottom},edges={},contacts={},partial=partial}
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
local function OrientedContactBounds(record,bounds)
	local cache=record.pose.oriented_contact_bounds
	if not cache then cache={};record.pose.oriented_contact_bounds=cache end
	local box=cache[bounds];if box then return box end
	local columns=record.pose.asset_local and {{1,0,0},{0,1,0},{0,0,1}} or Matrix(record).columns
	box={center=World(record,{(bounds[1]+bounds[4])*.5,(bounds[2]+bounds[5])*.5,(bounds[3]+bounds[6])*.5}),edges={},axes={}}
	for i=1,3 do
		local c=columns[i];local h=(bounds[i+3]-bounds[i])*.5
		box.edges[i]={c[1]*h,c[2]*h,c[3]*h}
		box.axes[i]={c[1],c[2],c[3],math.sqrt(c[1]^2+c[2]^2+c[3]^2)}
	end
	cache[bounds]=box;return box
end

local function OrientedContactSeparated(ar,ab,br,bb,tolerance)
	local a,b=OrientedContactBounds(ar,ab),OrientedContactBounds(br,bb)
	local x,y,z=b.center[1]-a.center[1],b.center[2]-a.center[2],b.center[3]-a.center[3]
	-- Every tested direction bounds ALL eight corners of both affine boxes.
	-- A separating projection proves empty space, even for reflected frames.
	-- An overlapping projection proves nothing; retain the full mesh fallback.
	local scale=max(1,abs(a.center[1]),abs(a.center[2]),abs(a.center[3]),abs(b.center[1]),abs(b.center[2]),abs(b.center[3]))
	for i=1,6 do
		local n=i<=3 and a.axes[i] or b.axes[i-3]
		local nx,ny,nz=n[1],n[2],n[3];local radius=0
		for j=1,3 do
			local u,v=a.edges[j],b.edges[j]
			radius=radius+abs(nx*u[1]+ny*u[2]+nz*u[3])+abs(nx*v[1]+ny*v[2]+nz*v[3])
		end
		local gap=abs(nx*x+ny*y+nz*z)-radius
		local slack=1e-7*(scale*(abs(nx)+abs(ny)+abs(nz))+radius)
		if gap>tolerance*n[4]+slack then return true end
	end
	return false
end

-- The native neighbour's axes usually bound a rotated cliff far more tightly
-- than world XYZ. Project BOTH complete BVHs onto those same unit directions;
-- disjoint intervals prove separation in world-distance units. Overlap still
-- reaches the unchanged world-space triangle and containment predicates.
local function ContactProjection(record,reference)
	local cache=record.pose.reference_frames or {};record.pose.reference_frames=cache
	local identity=reference.pose.pair_contact_frame or reference.pose
	local frame=cache[identity];if frame then return frame end
	local m,r=Matrix(record),Matrix(reference)
	local origin,delta,magnitudes={}, {}, {}
	local columns={{},{},{}};local magnitude=1
	for i=1,3 do
		local a,b=m.origin[i]+record.pose.shift[i],r.origin[i]+reference.pose.shift[i]
		delta[i]=a-b;magnitude=magnitude+abs(a)+abs(b)
		local c=m.columns[i];magnitudes[i]=abs(c[1])+abs(c[2])+abs(c[3])
	end
	for axis=1,3 do
		local v=r.columns[axis];local length=math.sqrt(Dot(v,v))
		if not (length>=1e-12 and length<math.huge) then return nil end
		local n={v[1]/length,v[2]/length,v[3]/length}
		origin[axis]=Dot(delta,n)
		for i=1,3 do columns[i][axis]=Dot(m.columns[i],n) end
	end
	frame={record={pose={matrix={origin=origin,columns=columns},shift={0,0,0}}},
		bounds={},origin_magnitude=magnitude,column_magnitudes=magnitudes}
	cache[identity]=frame;return frame
end

local function ProjectionRoundoff(frame,bounds)
	local magnitude=frame.origin_magnitude
	for i=1,3 do magnitude=magnitude+frame.column_magnitudes[i]*max(abs(bounds[i]),abs(bounds[i+3])) end
	-- Outward budget for subtraction, normalization and affine projection. This
	-- can only retain extra candidates, never supply a positive contact witness.
	return magnitude*1e-7
end

local function RawComponentContact(a,b,tolerance)
	local ar,br=a.transform_record or a.record,b.transform_record or b.record
	-- The spatial index may use a conservative native object box for a grounded
	-- neighbour. Reject disjoint component boxes before constructing either mesh
	-- hierarchy; this is the same root test the triangle traversal would perform.
	if not Overlap(WorldBounds(ar,a.component.bounds),WorldBounds(br,b.component.bounds),tolerance) then
		return false,true
	end
	if OrientedContactSeparated(ar,a.component.bounds,br,b.component.bounds,tolerance) then return false,true,true end
	-- Transforms belong to a captured pose, not an object lifetime. Reuse them
	-- across pair queries in this scan; BuildNodes/Pose after movement obtains
	-- fresh caches, including independent post-seating validation.
	ar.pose.contact_bounds=ar.pose.contact_bounds or {}
	br.pose.contact_bounds=br.pose.contact_bounds or {}
	local ac,bc=ar.pose.contact_bounds,br.pose.contact_bounds
	local projected_a,projected_b
	if ar~=br and not ar.pose.asset_local and not br.pose.asset_local then
		projected_a,projected_b=ContactProjection(ar,br),ContactProjection(br,br)
		if projected_a and projected_b then ac,bc=projected_a.bounds,projected_b.bounds
		else projected_a,projected_b=nil,nil end
	end
	local tree_ar,tree_br=projected_a and projected_a.record or ar,projected_b and projected_b.record or br
	local tree_tolerance=tolerance+(projected_a and
		ProjectionRoundoff(projected_a,a.component.bounds)+ProjectionRoundoff(projected_b,b.component.bounds) or 0)
	local function vertex_cache(record,geometry)
		local by_geometry=record.pose.contact_vertices or {};record.pose.contact_vertices=by_geometry
		local cache=by_geometry[geometry] or {};by_geometry[geometry]=cache
		return cache
	end
	local av,bv=vertex_cache(ar,a.geometry),vertex_cache(br,b.geometry)
	local function triangle_cache(record,geometry)
		local by_geometry=record.pose.contact_triangles or {};record.pose.contact_triangles=by_geometry
		local cache=by_geometry[geometry] or {};by_geometry[geometry]=cache;return cache
	end
	local atc,btc=triangle_cache(ar,a.geometry),triangle_cache(br,b.geometry)
	local function vertex(node,record,cache,i)
		local value=cache[i]
		if not value then value=World(record,node.geometry.vertices[i]);cache[i]=value end
		return value
	end
	local function triangle(node,record,cache,t,triangles)
		local value=triangles[t]
		if not value then
			value={vertex(node,record,cache,t[1]),vertex(node,record,cache,t[2]),vertex(node,record,cache,t[3])}
			triangles[t]=value
		end
		return value
	end
	local hint_key,hint_bucket
	if ar~=br then
		-- Hints are triangle identities, NEVER cached support verdicts. Repeated
		-- prefab formations often contact at the same mesh features. Test those
		-- features at the current captured poses before another full BVH search.
		local q=Local(ar,World(br,{0,0,0}));local box=a.component.bounds
		local cell=max(.01,box[4]-box[1],box[5]-box[2],box[6]-box[3])*.2
		hint_key=floor(q[1]/cell)..":"..floor(q[2]/cell)..":"..floor(q[3]/cell)
		local by_component=a.component.contact_hints
		local pair=by_component and by_component[b.component]
		hint_bucket=pair and pair[hint_key]
		for _,hint in ipairs(hint_bucket or {}) do
			if Validator.TrianglesContact(triangle(a,ar,av,hint[1],atc),triangle(b,br,bv,hint[2],btc),tolerance) then return true end
		end
		-- A local placement search can cross a bucket boundary while the same
		-- two rendered faces still intersect. Retest the most recent exact face
		-- witness at these NEW poses before restarting the complete BVH walk.
		-- This is never a cached contact verdict or a negative shortcut.
		local recent=pair and pair.recent
		if recent then
			local tried=false
			for _,hint in ipairs(hint_bucket or {}) do if hint==recent then tried=true;break end end
			if not tried and Validator.TrianglesContact(triangle(a,ar,av,recent[1],atc),triangle(b,br,bv,recent[2],btc),tolerance) then return true end
		end
	end
	local function remember(at,bt)
		if not hint_key then return end
		local by_component=a.component.contact_hints or {};a.component.contact_hints=by_component
		local pair=by_component[b.component]
		if not pair then pair={order={}};by_component[b.component]=pair end
		local bucket=pair[hint_key]
		if not bucket then
			bucket={};pair[hint_key]=bucket;pair.order[#pair.order+1]=hint_key
			if #pair.order>32 then pair[table.remove(pair.order,1)]=nil end
		end
		for _,hint in ipairs(bucket) do if hint[1]==at and hint[2]==bt then pair.recent=hint;return end end
		local hint={at,bt};pair.recent=hint
		table.insert(bucket,1,hint);if #bucket>4 then table.remove(bucket) end
	end
	local function visit(at,bt)
		-- Explicit depth-first stack retains left-before-right traversal and every
		-- bounds/triangle predicate, without a Lua call for every visited node.
		-- Only pending right branches are retained; no result outlives this pose.
		local pending={};local count=0
		while at do
		local ab,bb=ac[at],bc[bt]
		if not ab then ab=WorldBounds(tree_ar,at.bounds);ac[at]=ab end
		if not bb then bb=WorldBounds(tree_br,bt.bounds);bc[bt]=bb end
		if Overlap(ab,bb,tree_tolerance) then
		if at.items and bt.items then
			for _,ai in ipairs(at.items) do
				local aib=ac[ai];if not aib then aib=WorldBounds(tree_ar,ai.bounds);ac[ai]=aib end
				-- One triangle disjoint from the complete opposite leaf cannot
				-- contact any of its triangles. Avoid up to twelve repeated pair
				-- bounds checks, retaining conservative world-rounding slack.
				if Overlap(aib,bb,tree_tolerance+1e-6) then for _,bi in ipairs(bt.items) do
				local bib=bc[bi];if not bib then bib=WorldBounds(tree_br,bi.bounds);bc[bi]=bib end
				if Overlap(aib,bib,tree_tolerance) then
					-- All pairs in this captured pose share the same transformed
					-- triangle, just as they already share its exact vertex cache.
					local x=atc[ai.triangle] or triangle(a,ar,av,ai.triangle,atc)
					local y=btc[bi.triangle] or triangle(b,br,bv,bi.triangle,btc)
					-- A padded SAT failure is not a distance witness. Check every
					-- vertex/face and edge/edge pair, including interior edge contacts.
					if Validator.TrianglesContact(x,y,tolerance) then remember(ai.triangle,bi.triangle);return true end
				end
			end end end
		else
		-- Split only the larger world-space box at this level. A child outside
		-- the other complete subtree then prunes all its descendants at once;
		-- splitting both sides eagerly repeats those failed bounds tests. Every
		-- overlapping leaf pair still reaches the unchanged triangle predicate.
		local split_a=not at.items and (bt.items
			or ab[4]-ab[1]+ab[5]-ab[2]+ab[6]-ab[3]>=bb[4]-bb[1]+bb[5]-bb[2]+bb[6]-bb[3])
		if split_a then
			pending[count+1],pending[count+2]=at.right,bt;at=at.left
		else
			pending[count+1],pending[count+2]=at,bt.right;bt=bt.left
		end
		count=count+2
		goto next_pair
		end
		end
		if count==0 then return false end
		at,bt=pending[count-1],pending[count]
		pending[count-1],pending[count]=nil,nil;count=count-2
		::next_pair::
		end
		return false
	end
	if visit(Geometry.TriangleTree(a.geometry,a.component),Geometry.TriangleTree(b.geometry,b.component)) then return true end
	-- Open authored meshes cannot answer an inside-volume ray query. A first
	-- vertex inside the other's AABB is not proof of containment, either. After
	-- the COMPLETE triangle search above excludes every crossing, any vertex
	-- outside the other's complete bounds proves this connected component is
	-- not embedded in it. Try all vertices only for that ambiguous case; never
	-- infer separation from a sampled miss or bypass a real triangle contact.
	local function outside_bounds(node,record,other,other_record)
		local b=other.component.bounds
		-- If the COMPLETE transformed component box lies inside the other local
		-- box, none of its vertices can provide an outside-box witness. Avoid
		-- rechecking hundreds of interior vertices before the unchanged hull/volume
		-- test. This is not a containment/contact verdict, only a failed-witness
		-- search shortcut. Include generous outward floating-point slack.
		local box=OrientedContactBounds(record,node.component.bounds)
		local p=Local(other_record,box.center)
		local columns=other_record.pose.asset_local and {{1,0,0},{0,1,0},{0,0,1}} or Matrix(other_record).columns
		local inside=true
		local magnitude=max(1,abs(box.center[1]),abs(box.center[2]),abs(box.center[3]))
		for axis=1,3 do
			local n=columns[axis];local denominator=Dot(n,n);local radius=0
			for j=1,3 do radius=radius+abs(Dot(n,box.edges[j])) end
			radius=radius/(denominator+0.0)
			local slack=1e-7*(magnitude*(abs(n[1])+abs(n[2])+abs(n[3]))/(denominator+0.0)+abs(p[axis])+radius+1)
			if not (p[axis]-radius>b[axis]+slack and p[axis]+radius<b[axis+3]-slack) then inside=false;break end
		end
		if inside then return false end
		for _,vi in ipairs(Geometry.SupportVertices(node.geometry,node.component)) do
			local p=Local(other_record,World(record,node.geometry.vertices[vi]))
			for axis=1,3 do
				local margin=1e-8*max(1,abs(b[axis]),abs(b[axis+3]))
				if p[axis]<b[axis]-margin or p[axis]>b[axis+3]+margin then return true end
			end
		end
		return false
	end
	-- Once every face pair is separated, any outside rendered vertex excludes
	-- containment of its CONNECTED component. Try this cheap complete witness
	-- before an open-mesh convex-hull search, not after that expensive search
	-- returns unknown. Components wholly enclosed by the other's bounds retain
	-- the original closed-volume/hull test and its conservative unknown result.
	local a_in_b,b_in_a
	if outside_bounds(a,ar,b,br) then a_in_b=false
	else a_in_b=Geometry.PointInClosedComponent(b.geometry,b.component,Local(br,World(ar,a.geometry.vertices[a.component.vertices[1]]))) end
	if outside_bounds(b,br,a,ar) then b_in_a=false
	else b_in_a=Geometry.PointInClosedComponent(a.geometry,a.component,Local(ar,World(br,b.geometry.vertices[b.component.vertices[1]]))) end
	-- The complete triangle search has excluded contact. Both connected pieces
	-- must also be demonstrably outside each other's volume before their
	-- overlapping broad-phase boxes may be dismissed as possible support.
	return a_in_b==true or b_in_a==true,a_in_b==false and b_in_a==false,
		a_in_b~=true and b_in_a~=true -- every rendered face is separated; open-volume relation may remain unknown
end

local function ContactFrameEntry(node,record)
	local pose=record.pose;local matrix=Matrix(record);local o,s,c=matrix.origin,pose.shift,matrix.columns
	local frame=pose.pair_contact_frame;local v=frame and frame.values
	local same=v and v[1]==o[1] and v[2]==o[2] and v[3]==o[3]
		and v[4]==s[1] and v[5]==s[2] and v[6]==s[3] and frame.asset_local==pose.asset_local
	if same then for i=1,3 do for j=1,3 do if v[6+(i-1)*3+j]~=c[i][j] then same=false end end end end
	if not same then
		pose.contact_bounds=nil;pose.contact_vertices=nil;pose.contact_triangles=nil;pose.oriented_contact_bounds=nil
		pose.reference_frames=nil
		v={o[1],o[2],o[3],s[1],s[2],s[3]}
		for i=1,3 do for j=1,3 do v[#v+1]=c[i][j] end end
		frame={values=v,asset_local=pose.asset_local,geometries={}};pose.pair_contact_frame=frame
	end
	local components=frame.geometries[node.geometry]
	if not components then components={};frame.geometries[node.geometry]=components end
	local entry=components[node.component]
	if not entry then entry={};components[node.component]=entry end
	return entry
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
			local reverse=b.component.rigid_contacts
			if not reverse then reverse={};b.component.rigid_contacts=reverse end
			local pair=cache[b.component] or reverse[a.component] or {}
			-- Distance/contact and mutual containment are symmetric. The opposite
			-- traversal of this same rigid pair may reuse the very same proof.
			cache[b.component]=pair;reverse[a.component]=pair
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
				local r={pose={asset_local=true,matrix={origin={0,0,0},columns={{1,0,0},{0,1,0},{0,0,1}}},shift={0,0,0},scale=100}}
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
	-- Repeated graph/placement queries at the SAME two captured frames need not
	-- rediscover an exact pair relation. Changed origin, shift, basis, geometry,
	-- component or tolerance obtains a new entry; a new actual-pose capture is
	-- independent of every planning pose. Both positive and negative results are
	-- scoped to those frames, never a location bucket or approximate transform.
	local left,right=ContactFrameEntry(a,ar),ContactFrameEntry(b,br)
	local pair=left[right] or right[left]
	if not pair then pair={};left[right]=pair;right[left]=pair end
	local result=pair[tolerance]
	if not result then result={RawComponentContact(a,b,tolerance)};pair[tolerance]=result end
	return result[1],result[2],result[3]
end

-- A contact with an already rooted component settles this support question.
-- Keep all candidates (and stable order within each group), but try proven
-- roots before building edges to other unrooted pieces. Negative/unknown
-- evidence still visits every candidate; unsupported cycles cannot self-root.
local function RootedCandidatesFirst(candidates)
	local ordered={}
	for _,node in ipairs(candidates) do if node.supported then ordered[#ordered+1]=node end end
	if #ordered==0 or #ordered==#candidates then return candidates end
	for _,node in ipairs(candidates) do if not node.supported then ordered[#ordered+1]=node end end
	return ordered
end

local CompositionEvidence

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
	local integer_upper,heightfield_nodes
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
		if refresh and not prebuilt then
			-- Unselected objects contribute only conservative native world bounds.
			-- No local mesh frame is consumed for them. Source-map scans still need
			-- their terrain-relative Z correction; newly selected geometry always
			-- captures a complete current pose before BuildNodes below.
			if context.correction_only and not source and not record.relevant and not record.nodes then
				record.pose={shift={0,0,0}}
			else record.pose=Pose(record.obj,source and context.source_map or nil) end
			record.fast_bounds=nil
		end
		local obj=record.obj;local is_hole
		if context.preparation_snapshot and context.cut_snapshot then
			is_hole=context.cut_snapshot[obj]
		else
			local key=obj:GetEntity()..":"..tostring(obj:GetState())
			if hole_types[key]==nil then
				local flag=(Global("EntitySurfaces") or {}).TerrainHole
				local has=Global("HasAnySurfaces")
				hole_types[key]=flag and type(has)=="function" and has(obj,flag,true) or false
			end
			is_hole=hole_types[key]
		end
		if is_hole then
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
			local b=context.preparation_snapshot and not source and record.nomination_bounds
			if not b then
				b=BoxBounds(record.obj:GetObjectBBox())
				b[3],b[6]=b[3]+record.pose.shift[3],b[6]+record.pose.shift[3]
			end
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
	local function TerrainFaceWitnessImpl(node,upper)
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
			local face_upper=upper
			-- A formation-wide upper height can be far above terrain under this
			-- individual face. Bound its complete XY footprint before up to 69
			-- interior samples. This only discards faces that cannot yield a hit;
			-- it does not turn the missed positive search into a defect proof.
			if abs(den)>1e-12 and (not upper or min(a[3],b[3],c[3])<=upper+tolerance)
				and type(terrain_api.GetMinMaxHeight)=="function" and inside(a) and inside(b) and inside(c) then
				local _,high=terrain_api.GetMinMaxHeight(map,Global("box")(
					max(0,floor(min(a[1],b[1],c[1]))-separation_margin),
					max(0,floor(min(a[2],b[2],c[2]))-separation_margin),
					min(width-1,math.ceil(max(a[1],b[1],c[1]))+separation_margin),
					min(height-1,math.ceil(max(a[2],b[2],c[2]))+separation_margin)))
				if type(high)=="number" then face_upper=high end
			end
			if abs(den)>1e-12 and (not face_upper or min(a[3],b[3],c[3])<=face_upper+tolerance) then
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
	local function TerrainFaceWitness(node,upper)
		local before=Tick()
		local result=TerrainFaceWitnessImpl(node,upper)
		profile.face_ms=(profile.face_ms or 0)+Tick()-before
		return result
	end
	for node_index,node in ipairs(nodes) do
		YieldBatch(node_index,context)
		profile.visited=node_index
		local record=node.record
		local transform=node.transform_record or record
		for sample_index,p in ipairs(node.samples) do
			local in_hole=InHole(p)
			-- The height field still exists beneath a terrain-cutting wonder. Without
			-- an exact hole coverage witness it must not count as visible support.
			local height=inside(p) and not in_hole and terrain_api.GetHeight(map,Point(p))
			if height and p[3]<=height+tolerance then
				node.supported=true;node.contacts.terrain=true;node.terrain_witness={point=p,height=height}
				node.terrain_vertex=node.sample_vertices and node.sample_vertices[sample_index];break
			end
		end
		if node.supported then
			-- A real-vertex terrain witness needs no six-point contact search. The
			-- native object AABB is a conservative candidate bound; exact component
			-- triangles still decide another object's contact with this support.
			if #node.geometry.components==1 and not node.geometry.animated then
				local b=record.fast_bounds
				if not b then
					b=context.preparation_snapshot and not source and record.nomination_bounds
					if not b then b=BoxBounds(record.obj:GetObjectBBox());b[3],b[6]=b[3]+record.pose.shift[3],b[6]+record.pose.shift[3] end
					record.fast_bounds=b
				end
				node.bounds=b
			else
				-- A rubble entity can contain dozens of distant components. Using its
				-- whole box for every component would flood the nearby-object search.
				node.bounds=WorldBounds(transform,node.component.bounds)
			end
		else
			node.bounds=WorldBounds(transform,node.component.bounds);node.samples={};node.sample_vertices=node.component.samples
			for _,p in ipairs(node.component.samples) do node.samples[#node.samples+1]=World(transform,p) end
			-- After rotation, minimum-local-Z need not be minimum-world-Z.
			for sample_index,p in ipairs(node.samples) do
				local h=inside(p) and not InHole(p) and terrain_api.GetHeight(map,Point(p))
				if h and p[3]<=h+tolerance then
					node.supported=true;node.contacts.terrain=true;node.terrain_witness={point=p,height=h}
					node.terrain_vertex=node.sample_vertices[sample_index];break
				end
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
					node.supported=true;node.contacts.terrain=true;node.terrain_witness={point=p,height=h}
					node.terrain_vertex=node.geometry.vertices[Geometry.SupportVertices(node.geometry,node.component)[pi]];break
				end
			end
		end
		if not context.correction_only and not node.supported and not node.partial and not context.positive_only
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
	profile.terrain_ms=Tick()-started-profile.build_ms
	if source and context.placement_only then
		-- A new prefab with an isolated unsupported component will be rejected
		-- by this same graph walk regardless of its other members. Establish
		-- that cheap decision first, before unrelated stacked-mesh contacts.
		-- Terrain/attachment witnesses above are complete for this nomination;
		-- any possible neighbour, including unknown geometry, keeps the full walk.
		for _,node in ipairs(nodes) do if not node.supported then
			local possible=false
			for _,other in ipairs(index:Query(node.bounds,tolerance)) do
				if other~=node and ((other.record~=node.record and (other.unknown or other.lod==0))
					or (other.record==node.record and (other.unknown or other.lod==node.lod))) then possible=true;break end
			end
			if not possible then
				context.placement_support_rejected=true
				profile.contacts_ms=Tick()-started-profile.build_ms
				profile.total_ms=Tick()-started;profile.phase="rejected"
				context.profile=profile;context.index=index;return
			end
		end end
	end
	-- neighbour then needs no further triangle searches for that component.
	for node_index,node in ipairs(nodes) do
		YieldBatch(node_index,context)
		local record=node.record
		-- One proven terrain witness is sufficient for this connected component.
		-- Do not scan every neighbour of thousands of already grounded small rocks.
		local candidates=not node.supported and index:Query(node.bounds,tolerance) or {}
		if context.correction_only then candidates=RootedCandidatesFirst(candidates) end
		local possible_other=false
		local surfaces_clear=true
		local contact_started=Tick()
		for _,other in ipairs(candidates) do
			profile.candidates=profile.candidates+1;YieldBatch(profile.candidates,context)
			if other~=node and ((other.record~=record and (other.unknown or other.lod==0))
				or (other.record==record and (other.unknown or other.lod==node.lod))) then
				if other.unknown or other.partial then node.unknown_support=true;possible_other=true;surfaces_clear=false
				else
					local contact,separated,surface_separated=false,false,false
					-- Same-frame fragment pairs have a reusable complete triangle
					-- result; avoid repeating sample-to-triangle probes before it.
					if (node.transform_record or node.record)~=(other.transform_record or other.record) then
						for _,p in ipairs(node.samples) do
							profile.probes=profile.probes+1
							local probe_started=Tick()
							local hit=MeshContact(other,p,tolerance)
							profile.point_contact_ms=(profile.point_contact_ms or 0)+Tick()-probe_started
							if hit then contact=true;break end
						end
					end
					if not contact then
						local pair_started=Tick()
						contact,separated,surface_separated=ComponentContact(node,other,tolerance,context.placement_only or context.correction_only)
						profile.pair_contact_ms=(profile.pair_contact_ms or 0)+Tick()-pair_started
					end
					if not separated then possible_other=true end
					if contact or not (separated or surface_separated) then surfaces_clear=false end
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
		profile.object_ms=(profile.object_ms or 0)+Tick()-contact_started
		local settled_root=node.supported
		if settled_root and not node.contacts.terrain then
			for _,edge in ipairs(node.edges) do
				for _,part in ipairs(edge.record.nodes or {}) do
					if not part.supported then settled_root=false;break end
				end
				if not settled_root then break end
			end
		end
		if context.correction_only and not settled_root and not node.partial and not context.positive_only then
			-- A real contact with a rooted neighbour is already complete positive
			-- support evidence. Only search terrain face interiors if the cheaper
			-- roots/vertices and exact neighbour search did not settle this node.
			-- A partly unsupported neighbour may itself need correction: retain an
			-- independent terrain root rather than introducing a false dependent.
			-- Unrooted cycles receive no exemption: every remaining face search and
			-- the original negative proof/graph propagation still run below.
			local upper=TerrainUpper(node)
			if not upper or node.bounds[3]<=upper+tolerance then
				local witness=TerrainFaceWitness(node,upper)
				if witness then
					node.supported=true;node.edges={};node.contacts={terrain=true};node.terrain_witness=witness
				end
			end
		end
		local negative_started=Tick()
		if source and context.placement_only and not node.supported and #node.edges==0 then
			-- This new stamp will be rejected: every terrain witness and possible
			-- support for this component has been tried, and later nodes cannot add
			-- an outgoing edge to it. Root propagation therefore cannot rescue it.
			-- Stop wasted work on the rest of a rejected stamp, not necessary checks
			-- on any accepted one. Diagnostic captures still collect every finding.
			context.placement_support_rejected=true
			profile.contacts_ms=Tick()-started-profile.build_ms
			profile.total_ms=Tick()-started;profile.phase="rejected"
			context.profile=profile;context.index=index
			return
		end
		if not node.supported and (not possible_other or surfaces_clear) and not node.partial and not context.incomplete and not context.positive_only then
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
						local separated=false
						if separation_margin==100 then
							-- First try the tighter, correlated proof with the existing
							-- conservative affine error. This avoids thousands of repeated
							-- integer-rectangle queries when a few terrain cells suffice.
							heightfield_nodes=heightfield_nodes or {}
							local function height_at(x,y)
								local key=x..":"..y;local value=heightfield_nodes[key]
								if value==nil then value=terrain_api.GetHeight(map,x,y);heightfield_nodes[key]=value or false end
								return value
							end
							separated=Geometry.TrianglesAboveHeightfield(triangles,height_at,100,width,height,error_bound)
						end
						if not separated then separated=Geometry.TrianglesAboveTerrain(triangles,upper,error_bound) end
						if not separated and width>0 and height>0 and width==floor(width) and height==floor(height)
							and width<=67108864 and height<=67108864 then
							integer_upper=integer_upper or Geometry.CachedIntegerTerrainUpper(function(x,y)
								return terrain_api.GetHeight(map,x,y)
							end,width,height)
							local function refined(rect)
								-- The first proof stops at its first unresolved triangle.
								-- On retry, retain cheap complete bounds for all already
								-- separated triangles/subtriangles; exhaustive queries can
								-- only refine a bound that does not yet prove separation.
								local coarse=upper(rect)
								if type(coarse)=="number" and coarse~=-math.huge and rect[3]>coarse+error_bound then return coarse end
								-- The horizontal transform budget excludes the extra unit
								-- reserved above for the integral terrain-height result.
								return integer_upper(rect,error_bound-1,1024) or coarse
							end
							separated=Geometry.TrianglesAboveTerrain(triangles,refined,error_bound)
						end
						if not separated and not source and not node.geometry.animated
							and (node.transform_record or record)==record and separation_margin==100 then
							-- The native floating transform removes integral basis rounding;
							-- exact terrain-face clipping retains correlation on slopes.
							local precise=Geometry.NativeRigidMatrix(record.obj)
							if precise then
								local points,faces={},{};local extent,origin=0,0
								for a=1,3 do origin=max(origin,abs(precise.origin[a])) end
								for _,t in ipairs(node.component.triangles) do
									local face={}
									for i,vi in ipairs(t) do
										if not points[vi] then
											local v=node.geometry.vertices[vi];local p={}
											for a=1,3 do
												local offset=precise.columns[1][a]*v[1]+precise.columns[2][a]*v[2]+precise.columns[3][a]*v[3]
												p[a]=precise.origin[a]+offset;extent=max(extent,abs(offset))
											end
											points[vi]=p
										end
										face[i]=points[vi]
									end
									faces[#faces+1]=face
								end
								-- Outward FP32 transform/vertex-decode budget, at least one
								-- native world unit; no positive contact tolerance changes.
								local uncertainty=max(1,(origin+extent)/1048576.0+extent/131072.0
									+2*(node.geometry.quantum or 0)*Global("guim")*record.pose.scale/100.0)
								heightfield_nodes=heightfield_nodes or {}
								local function height_at(x,y)
									local key=x..":"..y;local value=heightfield_nodes[key]
									if value==nil then value=terrain_api.GetHeight(map,x,y);heightfield_nodes[key]=value or false end
									return value
								end
								separated=Geometry.TrianglesAboveHeightfield(faces,height_at,100,width,height,uncertainty)
								if separated then node.precise_terrain_separation=true;node.precise_error_bound=uncertainty end
							end
						end
						if separated then
							node.defect=true;node.reason="every rendered triangle separated from bounded terrain and nearby support"
							node.separation_error_bound=error_bound
						end
					end
				end
			end
		end
		if node.defect then
			node.terrain_separated=true
			if possible_other then
				-- Complete rendered surfaces are disjoint, but an open cliff has no
				-- defined closed volume. Authorize only a swept, rollback-guarded
				-- seating proposal, never a fabricated positive support verdict.
				node.defect=false;node.seating_proposal=surfaces_clear
				node.reason="terrain gap and disjoint rendered faces; open-volume relation unresolved"
			end
		end
		profile.negative_ms=(profile.negative_ms or 0)+Tick()-negative_started
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

local function StoreBaselines(context)
	local map=context.map
	for _,record in ipairs(context.list) do if record.relevant and IsValid(record.obj) then
		local baseline={version=1,entity=record.obj:GetEntity(),state=record.obj:GetState(),
			geometry_complete=record.complete or false,
			geometry_only=context.native_geometry_only or false,
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
end

local function FinishCapture(context)
	local started=Tick();Scan(context,true)
	StoreBaselines(context)
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
	if context.placement_support_rejected then
		return {ok=false,reason="native decor component has no verified rigid support"}
	end
	local parents,entries={},{}
	local terrain=Global("terrain")
	local width,height=map:GetMapSize()
	local function height_range(bounds)
		if type(terrain.GetMinMaxHeight)~="function" or bounds[1]<0 or bounds[2]<0
			or bounds[4]>=width or bounds[5]>=height then return nil end
		-- Include interpolation neighbours and integer point rounding. Equal
		-- extrema certify this entire region, not just sampled mesh vertices.
		local tile=Global("const").HeightTileSize
		local low,high=terrain.GetMinMaxHeight(map,Global("box")(
			max(0,floor(bounds[1])-tile),max(0,floor(bounds[2])-tile),
			min(width-1,math.ceil(bounds[4])+tile),min(height-1,math.ceil(bounds[5])+tile)))
		if type(low)=="number" and type(high)=="number" then return low,high end
	end
	local function flat_height(bounds)
		local low,high=height_range(bounds)
		if low and low==high then return low end
	end
	-- The terrain is immutable for this synchronous stamp plan. Native vertices
	-- across components/LODs often quantize to the same XY query. Keep the cache
	-- local to this plan so no placement/load/terraform can reuse stale heights.
	local heights,height_rows={},{}
	-- Integer coordinates inside these bounded dimensions have an exact numeric
	-- cell key (at most 2^52). Avoid allocating a separate table for virtually
	-- every distinct X on rotated meshes; keep the unrestricted row path outside.
	local linear_heights=width>0 and height>0 and width<=67108864 and height<=67108864
		and width==floor(width) and height==floor(height)
	local terrain_height=terrain.GetHeight
	local function height_at(x,y)
		x,y=floor(x+.5),floor(y+.5)
		if linear_heights and x>=0 and y>=0 and x<width and y<height then
			local key=x+y*width
			local value=heights[key]
			if value==nil then value=terrain_height(map,x,y);heights[key]=value end
			return value
		end
		local row=height_rows[x];if not row then row={};height_rows[x]=row end
		-- The stock XY overload reads the same integer coordinates without an
		-- intermediate Lua array and native point allocation for each query.
		if row[y]==nil then row[y]=terrain_height(map,x,y) end
		return row[y]
	end
	local function root(record)
		while parents[record]~=record do record=parents[record] end
		return record
	end
	local function zero_offset(record,p,ratio)
		if record.nonphysical then return true,0 end
		if #(record.nodes or {})==0 then return false,0 end
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
			local target_visible=-math.huge
			for _,v in ipairs(node.component.samples or {}) do
				local w=World(node.transform_record or record,v)
				local x,y,z=p[1]+(w[1]-old[1])*ratio,p[2]+(w[2]-old[2])*ratio,p[3]+(w[3]-old[3])*ratio
				local h=height_at(x,y)
				if type(h)~="number" then return false end
				local clearance=z-h
				if clearance>target_visible then target_visible=clearance end
				if clearance<=0 then grounded=true end
				if clearance>=visible then exposed=true end
				if grounded and exposed then break end
			end
			if not grounded and node.terrain_vertex then
				-- Scan already found this real mesh vertex at the source terrain.
				-- Re-evaluate it in the exact proposed frame/target terrain; its old
				-- support status alone is never reused as proof after movement.
				local w=World(node.transform_record or record,node.terrain_vertex)
				local x,y,z=p[1]+(w[1]-old[1])*ratio,p[2]+(w[2]-old[2])*ratio,p[3]+(w[3]-old[3])*ratio
				local h=height_at(x,y)
				if type(h)=="number" and z<=h then grounded=true end
			end
			if grounded and not exposed then
				-- The original planner requires half the SOURCE visible extent, not
				-- half the whole (possibly deeply buried) mesh. A terrain lower bound
				-- over its complete padded footprint gives a conservative upper bound
				-- on that visible extent. This can certify the same exact zero shift
				-- without an all-vertex source/target height walk. Unknown bounds still
				-- fall through to the complete original interval computation.
				local low=height_range(b)
				if low then
					local required=max(2,min(b[6]-b[3],max(0,b[6]-low))*.5+1)
					if target_visible>=required then exposed=true end
				end
			end
			if not grounded or not exposed then return false end
		end
		-- For every root, exact minimum clearance <= 0; for every component,
		-- exact maximum clearance >= its required visible height. Thus the full
		-- planner's interval contains zero and its preferred shift is EXACTLY zero.
		return true,roots
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
	end end
	for record in pairs(entries) do for _,node in ipairs(record.nodes or {}) do for _,other in ipairs(node.edges or {}) do
		if entries[other.record] then parents[root(record)]=root(other.record) end
	end end end
	-- Zero is an exact plan for a CONNECTED island only when EVERY member's
	-- visibility/contact interval contains zero and the island has a terrain root.
	-- If one member fails this certificate, retain full intervals for ALL members;
	-- otherwise a later nonzero shift could invalidate a skipped member's bounds.
	local zero_islands={}
	for _,record in ipairs(context.list) do if entries[record] then
		local entry=entries[record];local key=root(record)
		local guard=zero_islands[key] or {ok=true,roots=0,physical=false};zero_islands[key]=guard
		guard.physical=guard.physical or not record.nonphysical
		if guard.ok then
			local proven,roots=zero_offset(record,entry.position,entry.scale/(record.obj:GetScale()+0.0))
			guard.ok=proven;guard.roots=guard.roots+(roots or 0)
		end
	end end
	for _,record in ipairs(context.list) do if entries[record] then
		local entry=entries[record];local p,ns=entry.position,entry.scale
		local old,sc=record.pose.origin,record.obj:GetScale()
		local px,py,pz=p[1],p[2],p[3]
		local sx,sy,sz=old[1],old[2],old[3]
		local ratio=ns/(sc+0.0)
		local guard=zero_islands[root(record)]
		entry.zero_offset_proven=guard.ok and (guard.roots>0 or not guard.physical)
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
			if not b.defect then return false,"native fragment support was inconclusive" end
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

-- Baselines contain only saved scalar evidence. Keep decoded native comparison
-- frames outside them, so save files never acquire geometry/cache references.
local native_contact_frames=setmetatable({}, {__mode="k"})
local function NativeComponent(node)
	local r=node.record;local b=r.obj.SuperBigMapSupportBaseline
	if not b or not b.geometry_complete or not b.composition_pose or not b.composition_frames
		or not b.composition_signature or b.composition_signature~=Geometry.CompositionSignature(r.asset) then return end
	local frame=b.composition_frames[node.key]
	if not frame or #frame~=4 then return end
	local pose=b.composition_pose
	local cache=native_contact_frames[b];local prior=cache and cache[node.key]
	local values={pose.origin[1],pose.origin[2],pose.origin[3],pose.scale}
	for i=1,3 do for j=1,3 do values[#values+1]=pose.columns[i][j] end end
	for i=1,4 do for j=1,3 do values[#values+1]=frame[i][j] end end
	if prior and prior.geometry==node.geometry and prior.component==node.component then
		local same=true
		for i=1,#values do if values[i]~=prior.values[i] then same=false;break end end
		if same then return prior.node end
	end
	local native={pose={matrix=pose,shift={0,0,0},scale=pose.scale}}
	local origin=World(native,frame[1]);local columns={}
	for i=1,3 do local p=World(native,frame[i+1]);columns[i]={p[1]-origin[1],p[2]-origin[2],p[3]-origin[3]} end
	local transform={pose={matrix={origin=origin,columns=columns},shift={0,0,0},scale=pose.scale}}
	local n={record=transform,geometry=node.geometry,component=node.component}
	n.bounds=WorldBounds(transform,node.component.bounds)
	cache=cache or {};native_contact_frames[b]=cache
	cache[node.key]={geometry=node.geometry,component=node.component,values=values,node=n}
	return n
end

local function PreservedContacts(context,map)
	local graph,nodes,source={},{},{}
	local function source_node(node)
		if source[node]~=nil then return source[node] or nil end
		source[node]=false
		local n=NativeComponent(node);source[node]=n or false;return n
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

CompositionEvidence=function(record,baseline,map,preserved_contacts)
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

-- A supported native-style overhang is not a floating rock. Preserve its
-- silhouette, but only with an actual rooted rock contact for each exposed
-- foundation component and EVERY alternative LOD of its supporting neighbour.
-- Terrain-only contact still cannot excuse an exposed, ground-facing opening.
local function SupportedRockOverhang(context,record,foundation)
	if not foundation or foundation.incomplete or not record.complete or record.pose.parent then return false end
	local eligible=SBM.RockGrounding and SBM.RockGrounding.Eligible
	if not eligible then return false end
	local neighbours,contacts={},{};local exposed=false
	local function supports(node,other)
		if other==record or not other.complete then return false end
		local lods=neighbours[other]
		if lods==nil then
			-- Nomination classified every live object in this SAME read-only,
			-- non-yielding snapshot. Do not repeat the gameplay/name/parent
			-- exclusion tree for each LOD of every nearby rock. After the
			-- correction callback begins, all eligibility checks remain live.
			local allowed
			if context.preparation_snapshot and context.correction_only and not context.native_capture
				and context.eligibility_function==eligible then allowed=other.eligible_rock end
			if allowed==nil then allowed=eligible(other.obj) end
			if not allowed then neighbours[other]=false;return false end
			lods={}
			for _,n in ipairs(other.nodes or {}) do
				if not n.supported or n.partial or n.unknown_support or n.geometry.animated then lods=false;break end
				local lod=n.lod or 0;local rows=lods[lod] or {};lods[lod]=rows;rows[#rows+1]=n
			end
			neighbours[other]=lods
		end
		if not lods or not next(lods) then return false end
		local witnesses={}
		for _,rows in pairs(lods) do
			local contact=false
			for _,n in ipairs(rows) do
				if n.bounds[3]<=node.bounds[3]+2 and Overlap(node.bounds,n.bounds,2)
					and ComponentContact(node,n,2,context.correction_only) then contact=n;break end
			end
			if not contact then return false end
			witnesses[#witnesses+1]=contact
		end
		contacts[node]=witnesses
		return true
	end
	for _,node in ipairs(record.nodes or {}) do
		if not node.supported or node.partial or node.unknown_support or node.geometry.animated then return false end
		local rim=foundation.by_component[node.component]
		if rim and rim.gap>2 then
			exposed=true;local supported=false
			local seen={}
			for _,edge in ipairs(node.edges or {}) do
				seen[edge.record]=true
				if supports(node,edge.record) then supported=true;break end
			end
			-- Scan may stop at its first support witness (including terrain).
			-- That witness need not be the neighbour supporting every LOD of
			-- this overhang. Inspect the remaining actual contacts as well;
			-- index overlap alone never supplies an exemption.
			if not supported and context.index then
				for _,candidate in ipairs(context.index:Query(node.bounds,2)) do
					local other=candidate.record
					if not seen[other] then
						seen[other]=true
						if supports(node,other) then supported=true;break end
					end
				end
			end
			if not supported then return false end
		end
	end
	if exposed then
		-- These are real rooted contacts, not only a visual exemption. Retain
		-- the witnesses so a later correction of their support carries this
		-- dependent rock with it as part of the same rigid transaction.
		for node,witnesses in pairs(contacts) do
			local seen={};for _,edge in ipairs(node.edges or {}) do seen[edge]=true end
			for _,edge in ipairs(witnesses) do if not seen[edge] then
				node.edges[#node.edges+1]=edge;seen[edge]=true
			end end
		end
	end
	return exposed
end

local function FoundationCoveredBySupport(context,record,foundation)
	if not foundation or foundation.incomplete or not context.index then return false end
	local stacked=false
	for _,node in ipairs(record.nodes or {}) do
		if node.supported and not node.contacts.terrain then stacked=true;break end
	end
	if not stacked then return false end
	local neighbours,seen={},{}
	for _,node in ipairs(context.index:Query(BoxBounds(record.obj:GetObjectBBox()),2)) do
		local other=node.record
		if other~=record and not seen[other] and other.relevant and other.complete and other.nodes and #other.nodes>0 then
			seen[other]=true;local lods={}
			for _,n in ipairs(other.nodes) do
				local lod=n.lod or 0;local rows=lods[lod] or {};lods[lod]=rows
				if n.supported and not n.partial and not n.geometry.animated then
					rows[#rows+1]={node=n,points={},inside={}}
				end
			end
			neighbours[#neighbours+1]=lods
		end
	end
	if #neighbours==0 then return false end
	for _,rim in pairs(foundation.by_component) do if rim.gap>2 then
		for _,edge in ipairs(rim.edges) do
			local a,b=rim.points[edge[1]],rim.points[edge[2]];local covered=false
			for _,lods in ipairs(neighbours) do
				local all=true
				for _,rows in pairs(lods) do
					local found=false
					for _,row in ipairs(rows) do
						local n=row.node;local frame=n.transform_record or n.record
						local p,q=row.points[a],row.points[b]
						if not p then p=Local(frame,a);row.points[a]=p end
						if not q then q=Local(frame,b);row.points[b]=q end
						if Geometry.SegmentInsideRenderedBody(n.geometry,n.component,p,q,row.inside) then found=true;break end
					end
					if not found then all=false;break end
				end
				if all then covered=true;break end
			end
			if not covered then return false end
		end
	end end
	return true
end

function Validator.Validate(map,reason)
	local context=contexts[map];if not context or (not Enabled() and not context.correction_only) then return nil end
	local started=Tick();Scan(context,false)
	local report={version=1,reason=reason or "generation",diagnostic_only=true,
		valid=0,confirmed_defect=0,inconclusive=0,native_composition_verified=0,instances={},capture_ms=context.capture_ms,
		contact_tolerance_world_units=min(2,Global("const").HeightTileSize/50.0),
		capture_profile=context.capture_profile,validation_profile=context.profile}
	for _,record in ipairs(context.list) do if record.relevant and IsValid(record.obj) then
		local cached=context.selection and not context.selection[record] and record.obj.SuperBigMapSupportValidation
		if cached then
			local key=cached.status=="confirmed defect" and "confirmed_defect" or cached.status
			report[key]=report[key]+1;report.instances[#report.instances+1]=cached
			if cached.native_composition_verified then report.native_composition_verified=report.native_composition_verified+1 end
		else
		local baseline=not context.native_capture and record.obj.SuperBigMapSupportBaseline or nil
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
		local row={handle=record.obj.handle,id=Identity(map,record.obj),entity=record.obj:GetEntity(),class=record.obj.class,status=status,
			reason=status=="confirmed defect" and why or record.reason or why,
			geometry_complete=complete or false,support_preserved=preserved,current_geometry_status=current_status,
			render_kind=record.nonphysical or "physical geometry",
			placement_repaired=repaired or false,
			native_clearing_transition=clearing_repair or false,
			native_composition_verified=false,
			effect_evidence=record.asset.effect,
			native_baseline=baseline~=nil,components=#(record.nodes or {}),position=XYZ(record.obj:GetVisualPos())}
		local proposal=false
		for _,node in ipairs(record.nodes or {}) do if node.seating_proposal then proposal=true end end
		if record.foundation then
			-- Nomination and preparation scans share one non-yielding, unchanged
			-- terrain/pose snapshot. Nomination already measured this entire rim.
			-- The flag is cleared BEFORE any correction callback, so independent
			-- post-move verification and later censuses always measure afresh.
			local foundation=context.preparation_snapshot and record.foundation
				or FoundationEvidence(map,record.obj,record.asset)
			row.foundation_gap=foundation and not foundation.incomplete and foundation.gap or false
			row.foundation_unresolved=not foundation or foundation.incomplete or foundation.gap>2
			-- Vanilla builds stacks from intersecting rocks. An upper opening
			-- need not reach terrain when EVERY rim segment is strictly inside
			-- an actually supported neighbour body in EVERY rendered LOD.
			-- Sparse contacts, AABBs and open-hull guesses cannot grant this proof.
			if row.foundation_unresolved and current_status=="valid" and SupportedRockOverhang(context,record,foundation) then
				row.foundation_unresolved=false;row.supported_overhang_preserved=true
			elseif row.foundation_unresolved and FoundationCoveredBySupport(context,record,foundation) then
				row.foundation_unresolved=false;row.foundation_support_covered=true
			end
			proposal=proposal or row.foundation_unresolved
		end
		row.seating_proposal=proposal and record.complete or false
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
		if not context.correction_only or record.relevant then
			record.last_bounds=context.preparation_snapshot and record.nomination_bounds or BoxBounds(record.obj:GetObjectBBox())
		end
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
	context.seated=nil -- subsequent validation rebuilds actual changed poses
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
	local context=contexts[map]
	local group_root=context and context.group_targets and context.group_targets[obj]
	local group_repair=group_root and group_root.obj.SuperBigMapSupportRepair
	local grouped=group_repair and group_repair.from and group_repair.to
	if grouped then for i=1,3 do if to[i]-from[i]~=group_repair.to[i]-group_repair.from[i] then grouped=false;break end end end
	if not row or (row.status~="confirmed defect" and not row.seating_proposal and not grouped) or not row.geometry_complete then return false end
	obj.SuperBigMapSupportRepair={version=1,pose=PersistedPoseKey(obj),from=from,to=to,
		reason=grouped and "retained rigid support group" or "confirmed unsupported cosmetic geometry",source_id=row.id}
	local original=context and context.by_object[obj]
	if original then
		local moved={obj=obj,pose=Pose(obj),relevant=true}
		BuildNodes(moved,original.asset)
		for _,node in ipairs(moved.nodes) do node.bounds=WorldBounds(node.transform_record or moved,node.component.bounds) end
		context.seated=context.seated or {};context.seated[obj]=moved
	end
	return true
end

function Validator.CancelSeating(map,obj)
	local context=contexts[map]
	-- Subsequent proposals must see the original indexed pose after rollback,
	-- not the discarded pose cached by RecordSeating.
	if context and context.seated then context.seated[obj]=nil end
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
function Validator.SeatingEvidence(map,bounds_only)
	local context=contexts[map];local result={}
	if not context or context.incomplete or not context.index then return result end
	local eligible=SBM.RockGrounding and SBM.RockGrounding.Eligible
	for _,record in ipairs(context.list) do
		local obj=record.obj;local row=IsValid(obj) and obj.SuperBigMapSupportValidation
		if row and (row.status=="confirmed defect" or row.seating_proposal) and record.complete and eligible and eligible(obj)
			and (not context.correction_only or context.repair_targets[obj])
			and not record.pose.parent and #record.nodes>0 then
			local safe=not (record.foundation and record.foundation.incomplete);local unsupported=record.foundation~=nil
			for _,node in ipairs(record.nodes) do
				if node.geometry.animated or node.partial or node.unknown_support then safe=false end
				-- An open-base repair proves terrain contact for every component at
				-- its proposed final pose. Existing rock contact is not itself a veto;
				-- dependencies must instead survive the exact proposed translation.
				for _,edge in ipairs(node.edges) do if edge.record~=record and not record.foundation then safe=false end end
				-- A complete open-base rim gap is itself the float proof. A pair of
				-- such rocks resting only on each other has no rooted component and
				-- no per-node negative proof, yet still needs terrain seating.
				if not node.supported and not (node.defect or node.seating_proposal or record.foundation) then safe=false end
				if not node.supported then unsupported=true end
				-- A grounded member does not forbid a rigid group correction by
				-- itself. The planner must retain every component's visible extent;
				-- attachment/object edges and dependents still veto movement here.
			end
			if type(obj.ForEachAttach)=="function" then obj:ForEachAttach(function()safe=false end) end
			local bounds=BoxBounds(obj:GetObjectBBox())
			for _,other in ipairs(context.index:Query(bounds,Global("const").HeightTileSize)) do
				if other.record~=record then
					for _,edge in ipairs(other.edges or {}) do if edge.record==record and not record.foundation then safe=false end end
				end
			end
			if safe and unsupported then
				local components={}
				for _,node in ipairs(bounds_only and {} or record.nodes) do
					local c={vertices={},height=0};local lo,hi=math.huge,-math.huge
					for _,vi in ipairs(Geometry.SupportVertices(node.geometry,node.component)) do
						local p=World(record,node.geometry.vertices[vi]);c.vertices[#c.vertices+1]=p
						lo=min(lo,p[3]);hi=max(hi,p[3])
					end
					local b=node.component.bounds
					c.volume=(b[4]-b[1])*(b[5]-b[2])*(b[6]-b[3])
					c.lod=node.lod
					c.foundation=record.foundation and record.foundation.by_component[node.component]
					c.height=hi-lo;components[#components+1]=c
				end
				result[#result+1]={obj=obj,components=components,bounds=bounds,foundation=record.foundation~=nil,
					confirmed=row.status=="confirmed defect" or row.seating_proposal}
			end
		end
	end
	return result
end

-- Keep a small supported stack rigid instead of lowering its root out from
-- underneath it. Only complete, unattached cosmetic dependents with no separate
-- open-base repair participate. Every member retains its own visibility/burial
-- budget; a separate small object does not become an attached fragment.
function Validator.SeatingGroup(map,entry)
	local context=contexts[map];local root=context and context.by_object[entry.obj]
	if not root or not root.foundation then return nil end
	local members,member_set={root},{[root]=true}
	local floating={}
	local eligible=SBM.RockGrounding and SBM.RockGrounding.Eligible
	local dependents=context.seating_dependents
	if not dependents then
		dependents={};context.seating_dependents=dependents
		for _,candidate in ipairs(context.list) do if candidate.nodes then
			local seen={}
			for _,node in ipairs(candidate.nodes) do for _,edge in ipairs(node.edges or {}) do
				local support=edge.record
				if support~=candidate and not seen[support] then
					seen[support]=true;local rows=dependents[support] or {};dependents[support]=rows;rows[#rows+1]=candidate
				end
			end end
		end end
	end
	local cursor=1
	while cursor<=#members do
		local support=members[cursor];cursor=cursor+1
		for _,candidate in ipairs(dependents[support] or {}) do if not member_set[candidate] then
				if context.seated and context.seated[candidate.obj] then return nil end
				local validation=candidate.obj.SuperBigMapSupportValidation
				local covered=validation and (validation.foundation_support_covered or validation.supported_overhang_preserved)
				-- An authored stack of open-base rocks that float together moves as
				-- one rigid unit; each such member keeps its own complete rim-gap
				-- constraint below, so every open base reaches terrain.
				local floating_foundation=candidate.foundation and not covered and not candidate.foundation.incomplete
					and (not context.repair_targets or context.repair_targets[candidate.obj])
				if (candidate.foundation and not covered and not floating_foundation)
					or not candidate.complete or not candidate.pose or candidate.pose.parent
					or not eligible or not eligible(candidate.obj) or not candidate.nodes or #candidate.nodes==0 then return nil end
				local attached=false
				if type(candidate.obj.ForEachAttach)=="function" then candidate.obj:ForEachAttach(function()attached=true end) end
				if attached then return nil end
				for _,node in ipairs(candidate.nodes) do
					if node.partial or node.geometry.animated or (not node.supported and not floating_foundation) then return nil end
				end
				if floating_foundation then floating[candidate]=true end
				members[#members+1]=candidate;member_set[candidate]=true
		end end
	end
	if #members==1 then return nil end
	local rooted={}
	for _,node in ipairs(root.nodes) do rooted[node]=true end
	local changed=true
	while changed do
		changed=false
		for _,record in ipairs(members) do for _,node in ipairs(record.nodes) do if not rooted[node] then
			for _,edge in ipairs(node.edges) do if rooted[edge] then rooted[node]=true;changed=true;break end end
		end end end
	end
	local result={obj=entry.obj,bounds=entry.bounds,foundation=true,confirmed=entry.confirmed,components={},members={},group_members={}}
	for _,record in ipairs(members) do
		result.group_members[record.obj]=true
		local member={obj=record.obj,bounds=BoxBounds(record.obj:GetObjectBBox()),foundation=record==root or floating[record]}
		result.members[#result.members+1]=member
		for i,node in ipairs(record.nodes) do
			local c
			if record==root then c=entry.components[i]
			else
				-- A floating open-base member is not held up by the root: it must
				-- reach terrain itself and close its own complete rim gap.
				c={vertices={},height=0,lod=node.lod,terrain_root=floating[record] or not rooted[node],
					foundation=floating[record] and record.foundation.by_component[node.component] or nil}
				local lo,hi=math.huge,-math.huge
				for _,vi in ipairs(Geometry.SupportVertices(node.geometry,node.component)) do
					local p=World(node.transform_record or record,node.geometry.vertices[vi]);c.vertices[#c.vertices+1]=p
					lo=min(lo,p[3]);hi=max(hi,p[3])
				end
				local b=node.component.bounds;c.volume=(b[4]-b[1])*(b[5]-b[2])*(b[6]-b[3]);c.height=hi-lo
			end
			c.burial_owner=record.obj;result.components[#result.components+1]=c
		end
	end
	context.group_targets=context.group_targets or {}
	for i=2,#members do context.group_targets[members[i].obj]=root end
	return result
end

-- Difficult sloped placements may meet terrain inside a face, not at a mesh
-- vertex. Complete terrain-face clipping refines the rigid planner only;
-- independent positive rendered-support verification still decides acceptance.
function Validator.SeatingFlatSearchHeight(map,bounds,radius)
	local terrain=Global("terrain");local width,height=map:GetMapSize()
	if type(terrain.GetMinMaxHeight)~="function" then return nil end
	local pad=radius+Global("const").HeightTileSize
	if bounds[1]-pad<0 or bounds[2]-pad<0 or bounds[4]+pad>=width or bounds[5]+pad>=height then return nil end
	local low,high=terrain.GetMinMaxHeight(map,Global("box")(floor(bounds[1]-pad),floor(bounds[2]-pad),
		math.ceil(bounds[4]+pad),math.ceil(bounds[5]+pad)))
	if type(low)=="number" and low==high and low>-math.huge and low<math.huge then return low end
end

function Validator.RefineSeatingComponents(map,entry)
	local context=contexts[map];local record=context and context.by_object[entry.obj]
	if not record or not record.complete then return false end
	local width,height=map:GetMapSize();local terrain=Global("terrain")
	local clearances={};local heights={}
	local function at(x,y)
		local key=x..":"..y
		if heights[key]==nil then heights[key]=terrain.GetHeight(map,x,y) end
		return heights[key]
	end
	for i,node in ipairs(record.nodes) do
		local vertices,triangles={},{}
		for _,t in ipairs(node.component.triangles) do
			local triangle={}
			for j,vi in ipairs(t) do
				vertices[vi]=vertices[vi] or World(node.transform_record or record,node.geometry.vertices[vi])
				triangle[j]=vertices[vi]
			end
			triangles[#triangles+1]=triangle
		end
		local _,low,high=Geometry.TrianglesAboveHeightfield(triangles,at,Global("const").HeightTileSize,width,height,0,32768,true)
		if not low or not high or low>=math.huge or high<=-math.huge then return false end
		-- Native integer height and affine basis rounding are not positive
		-- witnesses. Retain slack here and let the actual-pose verifier decide.
		clearances[i]={low+2,high-2}
	end
	for i,c in ipairs(entry.components) do c.clearance=clearances[i] end
	return true
end

-- A small rigid tilt is a last resort for an authored two-piece gap on flat
-- ground, where no translation can seat both pieces without burying one. Keep
-- the original visibility thresholds; never lower the bar after rotating.
function Validator.RotationSeatingEvidence(map,entry,degrees,direction)
	local context=contexts[map];local original=context and context.by_object[entry.obj]
	local compose=Global("ComposeRotation")
	if not original or not original.complete or original.pose.parent or type(compose)~="function"
		or type(entry.obj.SetAxisAngle)~="function" then return nil end
	local azimuth=direction*math.pi/4
	local ax,ay=math.cos(azimuth),math.sin(azimuth)
	local rotation_axis=Point({math.floor(ax*4096+.5),math.floor(ay*4096+.5),0})
	ax,ay=rotation_axis:xy();local length=math.sqrt(ax*ax+ay*ay);ax,ay=ax/length,ay/length
	local theta=degrees*math.pi/180;local cosine,sine=math.cos(theta),math.sin(theta)
	local function rotate(p)
		local dot=ax*p[1]+ay*p[2]
		return {p[1]*cosine+ay*p[3]*sine+ax*dot*(1-cosine),
			p[2]*cosine-ax*p[3]*sine+ay*dot*(1-cosine),
			p[3]*cosine+(ax*p[2]-ay*p[1])*sine}
	end
	local base=Matrix(original)
	local record={obj=entry.obj,pose={matrix={origin=base.origin,columns={rotate(base.columns[1]),rotate(base.columns[2]),rotate(base.columns[3])}},
		shift=original.pose.shift,scale=original.pose.scale}}
	-- Native ComposeRotation applies its FIRST rotation, then its SECOND
	-- (the HSL product uses axis2 cross axis1). Match the world-axis Rodrigues
	-- transform above by composing the existing pose before the new world tilt.
	local axis,angle=compose(entry.obj:GetAxis(),entry.obj:GetAngle(),rotation_axis,degrees*60)
	local result={record=record,axis=axis,angle=angle,degrees=degrees,components={},bounds=Geometry.Bounds()}
	local terrain=Global("terrain")
	for i,node in ipairs(original.nodes) do
		if node.geometry.animated or node.partial then return nil end
		local c={vertices={},height=entry.components[i].height}
		local exposed=entry.components[i].clearance and entry.components[i].clearance[2] or -math.huge
		for _,p in ipairs(entry.components[i].clearance and {} or entry.components[i].vertices) do
			exposed=max(exposed,p[3]-terrain.GetHeight(map,Point(p)))
		end
		c.required_visibility=max(2,min(c.height,max(0,exposed))*.5)
		for _,vi in ipairs(Geometry.SupportVertices(node.geometry,node.component)) do
			local p=World(record,node.geometry.vertices[vi]);c.vertices[#c.vertices+1]=p;Geometry.Extend(result.bounds,p)
		end
		result.components[#result.components+1]=c
	end
	return result
end

function Validator.SeatingRotationMatches(map,obj,rotation,from,to)
	local context=contexts[map];local original=context and context.by_object[obj]
	if not original or not original.complete then return false end
	local expected={origin={},columns=Matrix(rotation.record).columns}
	local base=Matrix(rotation.record)
	for i=1,3 do expected.origin[i]=base.origin[i]+rotation.record.pose.shift[i]+to[i]-from[i] end
	local actual_record={obj=obj,pose=Pose(obj)}
	local actual=Matrix(actual_record)
	for _,node in ipairs(original.nodes) do
		if not Validator.AffineBoundsAgree(node.component.bounds,expected,actual,2) then return false end
	end
	return true
end

-- A successful correction count is not proof that every rock was checked.
-- Account for untouched positive witnesses as well as current support graphs;
-- missing or inconclusive evidence must keep surface readiness closed.
function Validator.SurfaceSupportSummary(map)
	local context=contexts[map]
	if not context then return nil,"surface support context unavailable" end
	local result={eligible=0,terrain=0,graph=0,native_composition=0,unresolved=0,findings={}}
	local eligible=SBM.RockGrounding and SBM.RockGrounding.Eligible
	if not eligible then return nil,"rock eligibility unavailable" end
	for _,record in ipairs(context.list) do
		local is_eligible=record.eligible_rock
		if is_eligible==nil then is_eligible=IsValid(record.obj) and eligible(record.obj) end
		if IsValid(record.obj) and is_eligible then
		result.eligible=result.eligible+1
		local row=record.obj.SuperBigMapSupportValidation
		if record.support_terrain_witness and not (context.repair_targets and context.repair_targets[record.obj]) then
			result.terrain=result.terrain+1
		elseif record.relevant and record.complete and row and row.geometry_complete and row.current_geometry_status=="valid"
			and not row.foundation_unresolved then
			result.graph=result.graph+1
		else
			result.unresolved=result.unresolved+1
			result.findings[#result.findings+1]={entity=record.obj:GetEntity(),position=XYZ(record.obj:GetVisualPos()),
				status=row and row.current_geometry_status or "inconclusive",reason=row and row.reason or record.reason}
		end
	end end
	return result
end

local function PlacementNeighbours(context,bounds,pad)
	local result={}
	for _,node in ipairs(context.index:Query(bounds,pad)) do
		if not (context.seated and context.seated[node.record.obj]) then result[#result+1]=node end
	end
	for _,record in pairs(context.seated or {}) do
		for _,node in ipairs(record.nodes) do if Overlap(node.bounds,bounds,pad) then result[#result+1]=node end end
	end
	return result
end

local function CosmeticExteriorWitness(map,inner,outer)
	if not inner or not outer or #inner==0 or #outer==0 then return false end
	local terrain=Global("terrain");local width,height=map:GetMapSize()
	local fragments={}
	for _,node in ipairs(inner) do
		local b=node.component.bounds
		fragments[#fragments+1]={lod=node.lod,volume=(b[4]-b[1])*(b[5]-b[2])*(b[6]-b[3])}
	end
	if SBM.DecorationSeating and SBM.DecorationSeating.MarkSmallFragments then SBM.DecorationSeating.MarkSmallFragments(fragments) end
	for i,node in ipairs(inner) do if not fragments[i].allow_burial then
		if node.partial or node.geometry.animated then return false end
		local transform=node.transform_record or node.record
		local samples={};local highest
		for _,vi in ipairs(Geometry.SupportVertices(node.geometry,node.component)) do
			local p=World(transform,node.geometry.vertices[vi])
			if not highest or p[3]>highest[3] then highest=p end
		end
		if highest then samples[1]=highest end
		for _,v in ipairs(node.component.samples or {}) do samples[#samples+1]=World(transform,v) end
		local visible=false
		for _,p in ipairs(samples) do
			if p[1]>=0 and p[2]>=0 and p[1]<width and p[2]<height and p[3]>terrain.GetHeight(map,Point(p))+2 then
				-- Only upward-facing view directions: an open underside is not a
				-- visibility exemption. Every rendered variant must leave this same
				-- real surface point visible; no inferred solid/hull is involved.
				for _,direction in ipairs({{0,0,1},{1,0,1},{-1,0,1},{0,1,1},{0,-1,1}}) do
					local clear=true
					for _,other in ipairs(outer) do
						if other.partial or other.geometry.animated then return false end
						local target=other.transform_record or other.record
						local local_p=Local(target,p)
						local local_end=Local(target,{p[1]+direction[1]*100,p[2]+direction[2]*100,p[3]+direction[3]*100})
						local d={local_end[1]-local_p[1],local_end[2]-local_p[2],local_end[3]-local_p[3]}
						if not Geometry.ComponentRayClear(other.geometry,other.component,local_p,d) then clear=false;break end
					end
					if clear then visible=true;break end
				end
			end
			if visible then break end
		end
		if not visible then return false end
	end end
	return true
end

function Validator.SeatingPlacementClear(map,obj,bounds,rotation,search)
	local context=contexts[map]
	if not context or not context.index then return false end
	local record=context.by_object[obj];if not record then return false end
	local original=rotation and rotation.bounds or BoxBounds(obj:GetObjectBBox())
	local delta={bounds[1]-original[1],bounds[2]-original[2],bounds[3]-original[3]}
	local moved,transforms={},{}
	for _,own in ipairs(record.nodes) do
		local source=rotation and rotation.record or own.transform_record or record
		-- All rigid pieces in this proposal share one captured pose. Share its
		-- transformed-vertex/BVH caches too; discard them for the next proposal.
		local transform=transforms[source]
		if not transform then
			transform={obj=obj,pose={matrix=Matrix(source),scale=source.pose.scale,shift={}}}
			for i=1,3 do transform.pose.shift[i]=source.pose.shift[i]+delta[i] end
			transforms[source]=transform
		end
		moved[#moved+1]={record=record,transform_record=transform,geometry=own.geometry,component=own.component,lod=own.lod,original=own}
	end
	-- The rejecting member of a rigid group is often the same across adjacent
	-- proposals. Try that member first at the NEW pose, just as we already try
	-- the last blocking neighbour first. This retains every check on accepted
	-- placements and caches no collision/support verdict across movement.
	if search and search.blocking_component then
		for i,own in ipairs(moved) do
			if own.component==search.blocking_component and own.geometry==search.blocking_geometry then
				moved[1],moved[i]=own,moved[1];break
			end
		end
	end
	local neighbours=PlacementNeighbours(context,bounds,2)
	-- Adjacent search positions often encounter the same obstruction. Test that
	-- captured node first, but only if the NEW bounds query still includes it.
	-- This is ordering, not a cached collision verdict at a different pose.
	if search and search.blocker then
		for i,node in ipairs(neighbours) do if node==search.blocker then
			neighbours[1],neighbours[i]=node,neighbours[1];break
		end end
	end
	local function reject(node,reason,own)
		if search then
			search.blocker=node
			search.blocking_component=own and own.component
			search.blocking_geometry=own and own.geometry
		end
		return false,node.record.obj:GetEntity(),reason
	end
	if record.foundation then
		-- Preserve every incoming support edge, even when its dependent lies
		-- outside the new bounds. Later independent graph validation also checks
		-- the actual native poses and the complete transitive dependent set.
		for _,dependent in ipairs(context.index:Query(original,Global("const").HeightTileSize)) do
			if dependent.record~=record and not (search and search.group_members and search.group_members[dependent.record.obj]) then
				for _,edge in ipairs(dependent.edges or {}) do if edge.record==record then
					local retained=false
					for _,own in ipairs(moved) do
						if own.component==edge.component and own.geometry==edge.geometry
							and ComponentContact(dependent,own,2) then retained=true;break end
					end
					if not retained then return reject(dependent,"dependent support would be lost") end
				end end
			end
		end
	end
	for _,node in ipairs(neighbours) do
		local nonphysical=node.record.nonphysical
		if node.unknown and not nonphysical then
			-- Foundation-only nomination deliberately avoids expanding unrelated
			-- neighbour meshes. Resolve actual non-rendering logical markers on
			-- demand; their bookkeeping bounds are not a physical obstruction.
			local ok,asset=pcall(Geometry.Instance,node.record.obj)
			if ok and asset and asset.complete and (asset.render_kind=="native non-rendering logical marker"
				or asset.render_kind=="native non-rendering entity") then
				nonphysical=asset.render_kind;node.record.nonphysical=nonphysical
			end
		end
		if node.record.obj~=obj and not nonphysical and not (search and search.group_members and search.group_members[node.record.obj]) then
			-- Cosmetic rocks may overlap to form a larger natural formation. This
			-- is not permission to intersect gameplay objects: use the same strict
			-- eligibility predicate as the correction service for BOTH objects.
			-- The moving formation still needs complete geometry. A permitted
			-- overlap need not decode the neighbour, but may NOT supply a support
			-- witness: independent rooted-support/visibility checks still apply.
			local eligible=SBM.RockGrounding and SBM.RockGrounding.Eligible
			local cosmetic_overlap=eligible and eligible(obj) and eligible(node.record.obj)
			if cosmetic_overlap then
				local other=BoxBounds(node.record.obj:GetObjectBBox())
				local function contains(a,b)
					return a[1]<=b[1] and a[2]<=b[2] and a[3]<=b[3]
						and a[4]>=b[4] and a[5]>=b[5] and a[6]>=b[6]
				end
				-- An enclosing world box is only a nomination. Require positive
				-- rendered visibility before allowing overlap inside that box.
				-- Pure downward translation cannot newly cover an unchanged
				-- neighbour from above: every point of the moving surface decreases
				-- in Z at the same XY. Preserve its incoming support edges separately.
				-- The moving formation still needs its own exterior witness if the
				-- neighbour encloses it; upward/XY/rotated moves have no such proof.
				local downward=not rotation and delta[1]==0 and delta[2]==0 and delta[3]<0
				local inspect_inner=contains(other,bounds)
				local inspect_other=contains(bounds,other) and not downward
				if inspect_inner or inspect_other then
					local nearby=node.record
					if not nearby.complete or not nearby.nodes or #nearby.nodes==0 then
						search=search or {};search.exterior_records=search.exterior_records or {}
						nearby=search.exterior_records[node.record]
						if not nearby then
							nearby={obj=node.record.obj,pose=Pose(node.record.obj)};BuildNodes(nearby)
							search.exterior_records[node.record]=nearby
						end
					end
					cosmetic_overlap=nearby.complete and nearby.nodes and #nearby.nodes>0
						and (not inspect_inner or CosmeticExteriorWitness(map,moved,nearby.nodes))
						and (not inspect_other or CosmeticExteriorWitness(map,nearby.nodes,moved))
				end
			end
			if not cosmetic_overlap then
			if node.unknown or node.partial or not node.record.complete then return reject(node,"neighbour geometry unavailable") end
			for _,own in ipairs(moved) do
				-- Shared BVHs prune irrelevant triangle pairs. Empty placement needs
				-- proven separation, including containment, not just no crossing faces.
				local contact,separated=ComponentContact(own,node,2)
				if contact then
					-- A native formation may already intersect its neighbouring rocks.
					-- A vertical seating must not invent a new intersecting component pair.
					-- Retain an existing pair only with actual current AND native contact
					-- proofs; the planner and post-move validator still enforce visibility
					-- and rooted support for every component of the rigid assembly.
					local movement=rotation and rotation.movement or delta
					if movement[1]~=0 or movement[2]~=0 or movement[3]>=0 or obj.SuperBigMapDecorEnginePass then
						return reject(node,"intersection during relocation or upward move",own) end
					local proofs=search and search[own.original]
					local proof=proofs and proofs[node]
					if not proof then
						proof={}
						if not ComponentContact(own.original,node,2) then proof.reason="new current component intersection"
						else
							local a,b=NativeComponent(own.original),NativeComponent(node)
							if not a or not b then proof.reason="native component frame unavailable"
							elseif not ComponentContact(a,b,2) then proof.reason="native component pair did not intersect" end
						end
						if search then proofs=proofs or {};search[own.original]=proofs;proofs[node]=proof end
					end
					if proof.reason then return reject(node,proof.reason,own) end
				elseif not separated then return reject(node,"open containment unresolved",own) end
			end
			end
		end
	end
	return true
end

-- Confirm the actual native pose, not merely the planner's affine rotation.
-- Retained intersections require the same current AND native pair proofs;
-- local XY moves may not introduce or retain an intersecting pair.
function Validator.SeatingCurrentPoseClear(map,obj,from,search)
	local context=contexts[map];local original=context and context.by_object[obj]
	if not original or not original.complete then return false end
	local bounds=BoxBounds(obj:GetObjectBBox())
	local x,y,z=obj:GetPosXYZ()
	local movement=from and {x-from[1],y-from[2],z-from[3]} or {0,0,0}
	return Validator.SeatingPlacementClear(map,obj,bounds,{bounds=bounds,movement=movement,record={obj=obj,pose=Pose(obj)}},search)
end

-- A stone supported by a cliff in vanilla must stop at the cliff, not be driven
-- through it to the terrain. Sweep the entire rigid rendered geometry through
-- the proposed downward move and return the first detailed-mesh contact. All
-- unknown bounds still veto; independent rooted-support validation after the
-- move decides whether this is a usable support, never this proposal alone.
function Validator.SeatingVerticalContact(map,obj,bounds,maximum)
	local context=contexts[map]
	local record=context and context.by_object[obj]
	if not context or not context.index or not record or not record.complete
		or type(maximum)~="number" or maximum<=0 or maximum>=math.huge then return nil end
	local swept={bounds[1],bounds[2],bounds[3]-maximum,bounds[4],bounds[5],bounds[6]}
	local near=PlacementNeighbours(context,swept,2)
	local best,found,best_node=maximum,false,nil
	local function can_meet(a,b)
		return a[1]<=b[4] and b[1]<=a[4] and a[2]<=b[5] and b[2]<=a[5]
			and a[3]-best<=b[6] and b[3]<=a[6]
	end
	for _,other in ipairs(near) do if other.record.obj~=obj then
		if other.unknown or other.partial or not other.record.complete then return nil,"unknown swept neighbour" end
		-- The same detailed neighbour mesh supplies physical support in Scan.
		-- Lower LODs are alternative visuals, not simultaneous stacked solids.
		if other.lod==0 then
		for _,own in ipairs(record.nodes) do
			local retained=false
			if not obj.SuperBigMapDecorEnginePass and ComponentContact(own,other,2) then
				local a,b=NativeComponent(own),NativeComponent(other)
				retained=a and b and ComponentContact(a,b,2) or false
			end
			if not retained then
			local ar,br=own.transform_record or record,other.transform_record or other.record
			local av,bv,ab,bb={},{},{},{}
			local function vertex(node,r,cache,i)
				if not cache[i] then cache[i]=World(r,node.geometry.vertices[i]) end
				return cache[i]
			end
			local function world_box(r,tree,cache)
				if not cache[tree] then cache[tree]=WorldBounds(r,tree.bounds) end
				return cache[tree]
			end
			local function visit(a,b)
				if not can_meet(world_box(ar,a,ab),world_box(br,b,bb)) then return end
				if a.items and b.items then
					for _,ai in ipairs(a.items) do for _,bi in ipairs(b.items) do
						if can_meet(world_box(ar,ai,ab),world_box(br,bi,bb)) then
							local x,y={},{}
							for i=1,3 do x[i]=vertex(own,ar,av,ai.triangle[i]);y[i]=vertex(other,br,bv,bi.triangle[i]) end
							local distance=Geometry.VerticalTriangleContact(x,y,best)
							if distance then best=distance;found=true;best_node=own end
						end
					end end
				elseif a.items then visit(a,b.left);visit(a,b.right)
				elseif b.items then visit(a.left,b);visit(a.right,b)
				else visit(a.left,b.left);visit(a.left,b.right);visit(a.right,b.left);visit(a.right,b.right) end
			end
			visit(Geometry.TriangleTree(own.geometry,own.component),Geometry.TriangleTree(other.geometry,other.component))
			end
		end
		end
	end end
	if not found then return nil,"no rendered support along vertical move" end
	if best_node and best_node.supported then return nil,"new contact blocks the grounded member before its floating neighbour seats" end
	-- Native Z is integral. Stop just BEFORE contact, within the validator's
	-- two-unit contact tolerance; never round down through the supporting mesh.
	local drop=floor(best-1e-6)
	if drop<=0 then return nil,"no safe nonzero vertical move" end
	return -drop
end
-- The diagnostic switch must not disable production fixes. A correction-only
-- scope inspects candidate placements and nearby support, not source history,
-- distant wonders, animated cave-ins or every object on map load/switch. Bounds
-- of ALL other objects remain in the index, so omitted geometry can veto a
-- correction but can never become evidence of empty space.
local function MultipleRenderedComponents(asset)
	if not asset or not asset.complete then return false end
	local counts={}
	for _,part in ipairs(asset.parts or {}) do
		local geometry=part.mesh and part.mesh.geometry
		if not geometry then return false end
		-- LODs are alternative renderings, not simultaneous fragments of a
		-- native assembly. Only a single rendered LOD can contain both an
		-- authored gap and its retained root. Current support still checks ALL
		-- LODs; this narrows only pre-expansion composition capture.
		local lod=part.lod or 0
		counts[lod]=(counts[lod] or 0)+#geometry.components
		if counts[lod]>1 then return true end
	end
	return false
end

local function SharedTerrainWitness(asset,unit)
	if asset.shared_terrain_witness~=nil then return asset.shared_terrain_witness or nil end
	asset.shared_terrain_witness=false
	local components={}
	for _,part in ipairs(asset.parts or {}) do
		local geometry=part.mesh and part.mesh.geometry
		if not geometry or geometry.animated or part.material_complete==false then return nil end
		for _,component in ipairs(geometry.components) do
			components[#components+1]={geometry=geometry,component=component}
		end
	end
	if #components<2 then return nil end
	local first=components[1].component;local candidates,buckets={},{}
	for _,p in ipairs(first.samples or {}) do
		-- This band only chooses promising witnesses. A point still must be an
		-- EXACT vertex of every component and LOD before it can prove anything.
		if p[3]<=first.bounds[3]+(first.bounds[6]-first.bounds[3])*.05 then
			local xs=buckets[p[1]] or {};buckets[p[1]]=xs
			local ys=xs[p[2]] or {};xs[p[2]]=ys
			if not ys[p[3]] then local row={point=p};ys[p[3]]=row;candidates[#candidates+1]=row end
		end
	end
	for _,entry in ipairs(components) do
		local present={}
		for _,vi in ipairs(entry.component.vertices) do
			local p=entry.geometry.vertices[vi];local xs=buckets[p[1]];local ys=xs and xs[p[2]]
			local row=ys and ys[p[3]];if row then present[row]=true end
		end
		local retained={}
		for _,row in ipairs(candidates) do if present[row] then retained[#retained+1]=row end end
		candidates=retained;if #candidates==0 then return nil end
	end
	table.sort(candidates,function(a,b)
		local p,q=a.point,b.point
		if p[3]~=q[3] then return p[3]<q[3] end
		if p[1]~=q[1] then return p[1]<q[1] end
		return p[2]<q[2]
	end)
	local p=candidates[1].point
	asset.shared_terrain_witness=Point({p[1]*unit,p[2]*unit,p[3]*unit})
	return asset.shared_terrain_witness
end

local function GroundedRigidInstance(obj,map,width,height,tolerance,asset,visible,projected,terrain,unit)
	asset=asset or Geometry.Instance(obj)
	-- These values were read immediately before this call in the same
	-- non-yielding nomination. Do not repeat projection/global queries per rock.
	if not asset.complete or asset.animated or projected or obj:GetClipPlane()~=0
		or (type(obj.GetSkewX)=="function" and obj:GetSkewX()~=0)
		or (type(obj.GetSkewY)=="function" and obj:GetSkewY()~=0)
		or (type(obj.GetWarped)=="function" and obj:GetWarped())
		or type(obj.GetTerrainDistortedSupport)~="function" then return false,asset end
	local distorted=obj:GetTerrainDistortedSupport()
	if distorted~=false and distorted~="disabled" then return false,asset end
	local count=0;local previous_x,previous_y,previous_height
	local function grounded(local_point)
		local p=obj:GetRelativePoint(local_point);local x,y,z=p:xyz()
		if x<0 or y<0 or x>=width or y>=height or (visible and not visible(x,y)) then return false end
		-- Alternative LOD bottoms often have different Z but the same actual
		-- integer XY. Reuse only the terrain height at that identical coordinate
		-- within this synchronous instance inspection, never a contact decision.
		if x~=previous_x or y~=previous_y then
			previous_x,previous_y,previous_height=x,y,terrain.GetHeight(map,p)
		end
		return z<=previous_height+tolerance
	end
	-- Some static LODs retain the identical bottom vertex. One actual terrain
	-- contact then proves every component at once; nonmatching assets and misses
	-- retain the complete original per-component path below.
	local shared=SharedTerrainWitness(asset,unit)
	if shared and grounded(shared) then return true,asset end
	for _,part in ipairs(asset.parts) do
		local geometry=part.mesh.geometry
		if not geometry or geometry.animated or part.material_complete==false then return false,asset end
		for _,component in ipairs(geometry.components) do
			count=count+1
			local bottom=component.bottom or component.samples[1]
			if not component.bottom_point then component.bottom_point=Point({bottom[1]*unit,bottom[2]*unit,bottom[3]*unit}) end
			local supported=grounded(component.bottom_point)
			if not supported then
				local points=component.extrema_points
				if not points then
					points={};component.extrema_points=points
					for _,p in ipairs(component.samples) do points[#points+1]=Point({p[1]*unit,p[2]*unit,p[3]*unit}) end
				end
				for _,p in ipairs(points) do if grounded(p) then supported=true;break end end
			end
			if not supported then return false,asset end
		end
	end
	return count>0,asset
end

function Validator.Correction(map,layer,apply,native_capture)
	local prior=contexts[map]
	local old_report,old_progress=map.SuperBigMapDecorationValidation,map.SuperBigMapDecorationValidationProgress
	-- Native history is retained only to protect real authored intersections.
	-- Proving native gaps is redundant now: they no longer exempt a floating
	-- expanded component. Current geometry still receives the full gap proof.
	local context={map=map,list={},by_object={},capture_ms=0,correction_only=true,repair_targets={},positive_only=layer=="Underground" or native_capture,native_capture=native_capture}
	local correction_started=Tick()
	-- Nomination and its initial scans are one synchronous, read-only phase.
	-- Reuse its complete native world bounds and hole census only in that phase;
	-- discard the permission BEFORE the correction callback can move anything.
	context.preparation_snapshot=true
	contexts[map]=context
	local ok,result=pcall(function()
		if native_capture then
			-- A map with no multi-piece rendered assemblies cannot need a
			-- rooted-plus-gap native-composition baseline. Avoid constructing an
			-- unused map-wide bounds index and thousands of record tables there.
			-- Inspect actual instance assets (including overrides), never infer
			-- this from entity names. Any eligible assembly keeps the full path.
			local found=false;local eligible=SBM.RockGrounding and SBM.RockGrounding.Eligible
			map:MapForEach("map","CObject",function(obj)
				if not found and IsValid(obj) and eligible and eligible(obj)
					and MultipleRenderedComponents(Geometry.Instance(obj)) then found=true end
			end)
			if not found then return {captured=true,candidates=0,total_ms=Tick()-correction_started} end
		end
		local bounds_index=Validator.Index(6400)
		-- During this synchronous source capture, decoded asset descriptors are
		-- immutable and shared by many instances. A one-piece asset cannot need
		-- an authored assembly baseline. Establish that before invoking the full
		-- gameplay-object classifier, but keep every object's bounds in the index.
		-- The live instance descriptor (including forced LOD/replacements) is still
		-- read for every object; this caches only the asset's component count.
		local native_assemblies={}
		local function native_assembly(obj)
			local asset=Geometry.Instance(obj)
			local multiple=native_assemblies[asset]
			if multiple==nil then multiple=MultipleRenderedComponents(asset);native_assemblies[asset]=multiple end
			return multiple,asset
		end
		local terrain=Global("terrain");local width,height=map:GetMapSize()
		local unit,kind=Global("guim"),Global("IsKindOf")
		local tolerance=min(2,Global("const").HeightTileSize/50.0)
		-- A native height value under a terrain-cutting entrance/wonder is not
		-- visible ground. Nomination must not certify such a rock before Scan's
		-- exact hole-triangle and rendered-neighbour checks can run. This census
		-- precedes EVERY nomination, independent of object enumeration order.
		local cuts={}
		local hole_flag=(Global("EntitySurfaces") or {}).TerrainHole
		local has_surfaces=Global("HasAnySurfaces")
		if layer=="Surface" and hole_flag and type(has_surfaces)=="function" then
			context.cut_snapshot={}
			map:MapForEach("map","CObject",function(obj)
				if IsValid(obj) and has_surfaces(obj,hole_flag,true) then
					context.cut_snapshot[obj]=true
					local cut=BoxBounds(obj:GetObjectBBox());cut.obj=obj;cuts[#cuts+1]=cut
				end
			end)
		end
		local function visible_terrain(x,y)
			for _,cut in ipairs(cuts) do
				if x>=cut[1] and x<=cut[4] and y>=cut[2] and y<=cut[5] then
					-- A whole-object box nominates possible cuts, not hidden ground.
					-- Decode projected cut faces lazily, once in this read-only phase.
					-- Missing/degenerate coverage retains the conservative box veto.
					if cut.triangles==nil then
						local triangles={};local for_each=Global("ForEachSurface")
						local ok=type(for_each)=="function" and pcall(for_each,cut.obj,hole_flag,function(a,b,c)
							local ax,ay=a:xy();local bx,by=b:xy();local cx,cy=c:xy()
							if (bx-ax)*(cy-ay)-(by-ay)*(cx-ax)~=0 then
								triangles[#triangles+1]={ax,ay,bx,by,cx,cy}
							end
						end)
						cut.triangles=ok and #triangles>0 and triangles or false
					end
					if not cut.triangles then return false end
					for _,t in ipairs(cut.triangles) do
						local a=(x-t[3])*(t[2]-t[4])-(t[1]-t[3])*(y-t[4])
						local b=(x-t[5])*(t[4]-t[6])-(t[3]-t[5])*(y-t[6])
						local c=(x-t[1])*(t[6]-t[2])-(t[5]-t[1])*(y-t[2])
						if not ((a<0 or b<0 or c<0) and (a>0 or b>0 or c>0)) then return false end
					end
				end
			end
			return true
		end
		local candidates={};local evidence_profiles={};local eligible=SBM.RockGrounding and SBM.RockGrounding.Eligible
		context.eligibility_function=eligible
		map:MapForEach("map","CObject",function(obj)
			if not IsValid(obj) then return end
			local record={obj=obj,relevant=false,projected=Projected(obj),
				editor_only=type(kind)=="function" and kind(obj,"EditorVisibleObject") or false}
			if layer=="Surface" then record.eligible_rock=false end
			context.list[#context.list+1]=record;context.by_object[obj]=record
			local object_bounds=BoxBounds(obj:GetObjectBBox())
			record.nomination_bounds=object_bounds
			bounds_index:Add({bounds=object_bounds,record=record})
			local near_cut=false
			for _,b in ipairs(cuts) do
				if object_bounds[1]<=b[4] and b[1]<=object_bounds[4]
					and object_bounds[2]<=b[5] and b[2]<=object_bounds[5] then near_cut=true;break end
			end
			local candidate=false
			local native_multiple,native_asset
			if native_capture and layer=="Surface" then native_multiple,native_asset=native_assembly(obj) end
			if layer=="Underground" then
				candidate=obj.class=="TunnelBlockerRubble" and obj:GetEntity()=="CaveIn_TunnelBlocker_1"
					and not obj.SuperBigMapSupportRepair and not obj.clear_request
					and obj.remaining_work_to_clear==obj.required_work_to_clear
			elseif layer=="Surface" and (not native_capture or native_multiple) and eligible and eligible(obj) then
				record.eligible_rock=true
				-- A one-component rendered LOD cannot have BOTH an inherited gap and a
				-- retained native root. It needs no native-composition nomination.
				-- Such objects still enter the bounds index and are fully inspected
				-- when a multi-component neighbour needs their support evidence.
				if not native_capture or native_multiple then
				-- Most rocks have direct terrain witnesses. Probe those actual vertices
				-- without allocating a full support graph/pose per grounded instance.
				-- A failed/unsupported probe still takes the complete existing path.
				local grounded_instance,asset=false,native_asset
				grounded_instance,asset=GroundedRigidInstance(obj,map,width,height,tolerance,native_asset,
					near_cut and visible_terrain or nil,record.projected,terrain,unit)
				if not native_capture then
					local foundation=FoundationEvidence(map,obj,asset)
					if foundation and (foundation.incomplete or foundation.gap>2) then
						record.foundation=foundation;record.foundation_only=grounded_instance
						candidate=true;grounded_instance=false
					end
				end
				record.support_terrain_witness=grounded_instance or false
				if not grounded_instance then
				-- Only real mesh vertices can prove that every connected component touches
				-- terrain. An object's origin can lie below terrain while its mesh floats.
				-- Try the six component extrema when the local bottom misses on a slope;
				-- these are the same positive witnesses used by Scan, so they avoid expanding
				-- a full nearby support search for already-grounded objects.
				record.pose=Pose(obj);BuildNodes(record,asset)
				if record.complete and #record.nodes>0 then
					local all_grounded=true
					local function grounded(p)
						return (not near_cut or visible_terrain(p[1],p[2])) and p[1]>=0 and p[2]>=0 and p[1]<width and p[2]<height
							and p[3]<=terrain.GetHeight(map,Point(p))+tolerance
					end
					for _,node in ipairs(record.nodes) do
						if node.geometry.animated or node.partial then candidate=false;all_grounded=false;break end
						local supported=grounded(node.samples[1])
						if not supported then
							for _,p in ipairs(node.component.samples or {}) do
								if grounded(World(node.transform_record or record,p)) then supported=true;break end
							end
						end
						if not supported then candidate=true;all_grounded=false end
					end
					record.support_terrain_witness=all_grounded
				end
				record.correction_prebuilt=true
				end
				end
			end
			if candidate then candidates[#candidates+1]=record;context.repair_targets[obj]=true end
		end)
		local nomination_ms=Tick()-correction_started
		local selected={};local c=SBM.ObjectClone
		local function select_near(node)
			local near=node.record
			if not near.relevant then
				if near.eligible_rock and not near.editor_only then near.relevant=true
				else near.relevant=Relevant(near.obj,c.ShouldSkipObject(near.obj),c.IsImportantSectorObject(near.obj)) end
				if not near.relevant and not near.nonphysical then
					local asset=Geometry.Instance(near.obj)
					if asset.complete and (asset.render_kind=="native non-rendering logical marker"
						or asset.render_kind=="native non-rendering entity") then
						near.nonphysical=asset.render_kind;near.complete=true
					end
				end
			end
		end
		for _,record in ipairs(candidates) do
			record.relevant=true
			local b=BoxBounds(record.obj:GetObjectBBox())
			local range=2
			local region={b[1]-range,b[2]-range,-1e12,b[4]+range,b[5]+range,1e12}
			if layer=="Surface" then
				if not record.foundation_only then bounds_index:QueryOnce(region,2,selected,select_near)
				else
					-- A terrain witness does not disprove an additional native rock
					-- support. Decode just the overlapping cosmetic neighbours before
					-- deciding that this exposed foundation needs to move.
					for _,near in ipairs(bounds_index:Query(b,2)) do
						if near.record.eligible_rock then select_near(near) end
					end
				end
			end
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
				if native_capture then
					-- New policy needs the original mesh/rigid frame to protect authored
					-- intersections, not a second terrain-support census. Reconstruct
					-- only the selected source geometry; source support remains explicitly
					-- unclassified and can never exempt current floating geometry.
					context.native_geometry_only=true
					for _,record in ipairs(context.list) do if record.relevant and IsValid(record.obj) then
						if not record.nodes then record.pose=Pose(record.obj);BuildNodes(record) end
					end end
					StoreBaselines(context)
					return {captured=true,geometry_only=true,candidates=#candidates,total_ms=Tick()-correction_started,
						nomination_ms=nomination_ms,evidence_ms=Tick()-correction_started-nomination_ms}
				end
				Validator.Validate(map,"correction-only placement evidence")
				evidence_profiles[#evidence_profiles+1]=context.profile
				for _,record in ipairs(candidates) do record.correction_complete=record.complete end
				-- Build exact neighbour geometry only around confirmed correction
				-- candidates. Native float repairs have a tightly bounded local search;
				-- top-ups retain their original wider relocation neighbourhood.
				-- All other objects remain conservative unknown bounds.
				local expansion={}
				for _,entry in ipairs(Validator.SeatingEvidence(map,true)) do
					if not entry.foundation then
						local b=entry.bounds;local range=32*5*Global("const").HeightTileSize
						if not entry.obj.SuperBigMapDecorEnginePass then range=16*Global("const").HeightTileSize end
						local region={b[1]-range,b[2]-range,-1e12,b[4]+range,b[5]+range,1e12}
						bounds_index:QueryOnce(region,2,selected,function(node)
							local before=node.record.relevant
							select_near(node)
							if not before and node.record.relevant then expansion[node.record]=true end
						end)
					end
				end
				if next(expansion) then
					-- Cached initial findings are retained for unchanged instances; newly loaded
					-- neighbours receive full geometry/support inspection before any move.
					context.selection=expansion
					Validator.Validate(map,"correction relocation neighbourhood")
					evidence_profiles[#evidence_profiles+1]=context.profile
				end
			end
		end
		local evidence_ms=Tick()-correction_started-nomination_ms
		if native_capture then return {captured=true,candidates=0,total_ms=Tick()-correction_started} end
		context.preparation_snapshot=nil;context.cut_snapshot=nil
		local result=apply(map)
		if type(result)=="table" then
			result.nomination_ms=nomination_ms;result.evidence_ms=evidence_ms
			result.total_ms=Tick()-correction_started;result.candidates=#candidates
			result.evidence_profiles=evidence_profiles
		end
		return result
	end)
	contexts[map]=prior
	map.SuperBigMapDecorationValidation=old_report
	map.SuperBigMapDecorationValidationProgress=old_progress
	if not ok then error(result) end
	return result
end

function Validator.CaptureNativeCompositions(map)
	return Protected("Correction",map,"Surface",nil,true)
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
