-- Read-only mesh inspection. Never uploads/replaces a mesh or mutates a resource.
-- A missing/unsupported layout is evidence of incomplete coverage, not a pass.
local SBM = rawget(_G, "SuperBigMap")
local Global = SBM.Engine.Global
local Geometry = {}
local mesh_cache, material_cache, entity_cache, override_cache = {}, {}, {}, {}
local type,tostring,ipairs,pairs,pcall=type,tostring,ipairs,pairs,pcall
local math,string,table=math,string,table

local function Finite(n)
	return type(n) == "number" and n == n and n > -math.huge and n < math.huge
end

local function Bounds()
	return { math.huge, math.huge, math.huge, -math.huge, -math.huge, -math.huge }
end

local function Extend(b, p)
	for a = 1, 3 do b[a] = math.min(b[a], p[a]); b[a+3] = math.max(b[a+3], p[a]) end
end

-- The split signed-16 position format stores offsets from the native AABB centre.
-- Its common quantization step is ceil(max half-extent)/32767. Recovered from
-- reVertexAccess (14092b560); VertexFormat.fh confirms signed pos_xy/pos_z.
-- Check decoded extrema against the resource bounds too: changed encodings fail
-- closed. This is not the fixed 1/16384 approximation used by older mesh tools.
function Geometry.Decode(data, bounds, formats)
	local geom = data and data.geom
	if not data or not Finite(data.maxBonesPerVertex) then return nil,"animation metadata unavailable" end
	if type(formats)~="table" then return nil,"format metadata unavailable" end
	if type(geom) ~= "table" or type(geom.vertices) ~= "table" or type(geom.indices) ~= "table"
		or type(geom.vertexLayout) ~= "table" then return nil, "CPU geometry unavailable" end
	local layout = geom.vertexLayout
	if type(layout.streams) ~= "table" or #layout.streams ~= 1 then return nil, "unsupported vertex streams" end
	local stride, count = layout.streams[1].stride, geom.numVertices
	if not Finite(stride) or stride <= 0 or stride%1~=0 or not Finite(count) or count <= 0 or count%1~=0
		or #geom.vertices ~= stride * count or #geom.indices == 0 or #geom.indices % 3 ~= 0 then
		return nil, "incomplete vertex/index buffer"
	end
	local attrs = {}
	for _, a in ipairs(layout.attributes or {}) do attrs[a.name] = a end
	local xy, z, pos = attrs.pos_xy, attrs.pos_z, attrs.pos
	local packed = xy and z and xy.format == formats.fmt_sint16_c2 and z.format == formats.fmt_sint16_c1
	local floating = pos and pos.format == formats.fmt_float32_c3 and type(string.unpack) == "function"
	if not packed and not floating then return nil, "unsupported position encoding" end
	local function offset_ok(attr,size)
		return Finite(attr.offset) and attr.offset>=0 and attr.offset%1==0 and attr.offset+size<=stride
	end
	if (packed and (not offset_ok(xy,4) or not offset_ok(z,2)))
		or (floating and not offset_ok(pos,12)) then return nil,"invalid position layout" end
	local bones,skin_reason
	local bi,bw=attrs.bone_indices_1,attrs.bone_weights_1
	if data.maxBonesPerVertex>0 then
		if data.maxBonesPerVertex==1 and bi and bw and bi.format==formats.fmt_uint8_c4
			and bw.format==formats.fmt_unorm8_c4 and offset_ok(bi,4) and offset_ok(bw,4) then bones={}
		else skin_reason="unsupported skinning layout" end
	end
	if type(bounds) ~= "table" then return nil, "mesh bounds unavailable" end
	local center, half = {}, 0
	for a = 1, 3 do
		if not Finite(bounds[a]) or not Finite(bounds[a+3]) or bounds[a] > bounds[a+3] then return nil, "invalid bounds" end
		center[a] = (bounds[a] + bounds[a+3]) * 0.5
		half = math.max(half, (bounds[a+3] - bounds[a]) * 0.5)
	end
	local quantum = packed and math.ceil(half) / 32767.0 or 0
	local bytes, vertices, decoded_bounds = geom.vertices, {}, Bounds()
	local function s16(i)
		local a,b = bytes[i],bytes[i+1]
		if not Finite(a) or not Finite(b) or a<0 or a>255 or b<0 or b>255 then return nil end
		local n = a + 256*b
		return n >= 32768 and n-65536 or n
	end
	for i = 0, count-1 do
		local p, base = {}, i*stride+1
		if bones then
			local index=bytes[base+bi.offset]
			local rigid=Finite(index) and index>=0 and index<256 and index%1==0 and bytes[base+bw.offset]==255
			for j=1,3 do if bytes[base+bw.offset+j]~=0 then rigid=false end end
			if not rigid then bones=nil;skin_reason="non-rigid vertex weights"
			else bones[i+1]=index+1 end
		end
		if packed then
			local q = { s16(base+xy.offset), s16(base+xy.offset+2), s16(base+z.offset) }
			for a = 1, 3 do if q[a] == nil then return nil, "invalid position bytes" end; p[a] = center[a]+q[a]*quantum end
		else
			if pos.offset < 0 or pos.offset+12 > stride then return nil, "invalid float position offset" end
			local chars = {}
			for j=0,11 do chars[#chars+1]=string.char(bytes[base+pos.offset+j]) end
			p[1],p[2],p[3] = string.unpack("<fff",table.concat(chars))
		end
		for a=1,3 do if not Finite(p[a]) then return nil, "non-finite vertex" end end
		vertices[i+1]=p;Extend(decoded_bounds,p)
	end
	local tolerance = math.max(quantum*2, 0.0001)
	for a=1,6 do
		if math.abs(decoded_bounds[a]-bounds[a]) > tolerance then return nil, "decoded bounds disagree with native mesh" end
	end
	local parent, used, coincident = {}, {}, {}
	local function root(i)
		local p=parent[i]
		while p~=parent[p] do parent[p]=parent[parent[p]];p=parent[p] end
		parent[i]=p;return p
	end
	local function join(a,b)
		a,b=root(a),root(b);if a~=b then parent[b]=a end
	end
	for i,p in ipairs(vertices) do
		parent[i]=i
		-- Exact seams, not approximate welding that could connect detached fragments.
		local key=string.format("%.12g,%.12g,%.12g:%s",p[1],p[2],p[3],bones and bones[i] or "static")
		if coincident[key] then join(i,coincident[key]) else coincident[key]=i end
	end
	local rendered_triangles={}
	for i=1,#geom.indices,3 do
		for j=i,i+2 do if not Finite(geom.indices[j]) or geom.indices[j]%1~=0 then return nil,"invalid triangle index" end end
		local a,b,c=geom.indices[i]+1,geom.indices[i+1]+1,geom.indices[i+2]+1
		if a<1 or b<1 or c<1 or a>count or b>count or c>count then return nil,"out-of-range triangle index" end
		local p,q,r=vertices[a],vertices[b],vertices[c]
		local ax,ay,az=q[1]-p[1],q[2]-p[2],q[3]-p[3]
		local bx,by,bz=r[1]-p[1],r[2]-p[2],r[3]-p[3]
		local nx,ny,nz=ay*bz-az*by,az*bx-ax*bz,ax*by-ay*bx
		-- Degenerate connector triangles have no rendered area and cannot support
		-- a disconnected fragment merely because their indices share a vertex.
		if nx*nx+ny*ny+nz*nz>1e-20 then
			used[a],used[b],used[c]=true,true,true;join(a,b);join(a,c)
			rendered_triangles[#rendered_triangles+1]={a,b,c}
		end
	end
	local components, groups = {}, {}
	for i=1,count do if used[i] then
		local r=root(i);local component=groups[r]
		if not component then component={bounds=Bounds(),vertices={},triangles={}};groups[r]=component;components[#components+1]=component end
		component.vertices[#component.vertices+1]=i;Extend(component.bounds,vertices[i])
	end end
	for _,t in ipairs(rendered_triangles) do
		local a,b,c=t[1],t[2],t[3]
		local triangles=groups[root(a)].triangles
		triangles[#triangles+1]={a,b,c}
	end
	for _,component in ipairs(components) do
		if bones then
			local bone=bones[component.vertices[1]]
			for _,i in ipairs(component.vertices) do if bones[i]~=bone then bone=false;break end end
			component.bone=bone
			if not bone then skin_reason="component spans multiple bones" end
		end
		-- Retain representative real vertices for positive contact witnesses. Failure
		-- to find a witness here NEVER proves that a component is unsupported.
		local samples,seen={},{}
		for axis=1,3 do for _,sign in ipairs({-1,1}) do
			local best
			for _,i in ipairs(component.vertices) do if not best or vertices[i][axis]*sign>vertices[best][axis]*sign then best=i end end
			if best and not seen[best] then samples[#samples+1]=vertices[best];seen[best]=true end
		end end
		component.samples=samples
		local bottom
		for _,i in ipairs(component.vertices) do if not bottom or vertices[i][3]<vertices[bottom][3] then bottom=i end end
		component.bottom=vertices[bottom]
	end
	return {vertices=vertices,components=components,quantum=quantum,bounds=bounds,
		animated=data.maxBonesPerVertex>0,rigid_skin=bones~=nil and not skin_reason,skin_reason=skin_reason,
		vertex_count=count,index_count=#geom.indices}
end

local function ReadMesh(path)
	if mesh_cache[path] then return mesh_cache[path] end
	local result={path=path,status="inconclusive"};mesh_cache[path]=result
	local resources,properties=Global("ResourceManager"),Global("GetRenderMeshProperties")
	if not resources or type(resources.LoadToolResource)~="function" or type(properties)~="function" then
		result.reason="read-only CPU mesh API unavailable";return result
	end
	local ok,err=pcall(function()
		local id=resources.GetResourceID(path);local props=properties(id)
		if not props or not props.Box then result.reason="native mesh bounds unavailable";return end
		local lo,hi=props.Box:min(),props.Box:max()
		local bounds={lo:x(),lo:y(),lo:z(),hi:x(),hi:y(),hi:z()}
		local resource=resources.LoadToolResource(id)
		if not resource then result.reason="CPU mesh resource unavailable";return end
		local data=resource:AsAnyRef():get()
		local decoded,why=Geometry.Decode(data,bounds,Global("const"))
		if decoded and decoded.rigid_skin then
			local skin=data.skeleton
			local path=skin and tostring(skin.skeleton):match("^TResRef%('([^']+)'%)$")
			local skeleton=path and resources.LoadToolResource(resources.GetResourceID(path))
			local skeleton_data=skeleton and skeleton:AsAnyRef():get()
			if type(skeleton_data)=="table" and type(skeleton_data.bones)=="table" and type(skin.bindPose)=="table" then
				decoded.bones=skeleton_data.bones;decoded.bind_pose=skin.bindPose
			else decoded.rigid_skin=false;decoded.skin_reason="skeleton binding unavailable" end
		end
		result.geometry=decoded;result.reason=why
		if decoded then result.status="decoded" end
	end)
	if not ok then result.reason="mesh inspection failed: "..tostring(err) end
	return result
end

-- Native matrices use row-vector multiplication: rest * inverseBind * visualBone.
-- Convert once per instance/bone; decoded triangles and their BVHs remain shared.
function Geometry.BoneMatrix(obj,geometry,bone)
	if not geometry.rigid_skin or not geometry.bones or not geometry.bind_pose
		or not geometry.bones[bone] or type(geometry.bones[bone].name)~="string"
		or not geometry.bind_pose[bone] or type(obj.GetVisualBoneTransform)~="function" then
		return nil,"bone binding unavailable"
	end
	local ok,matrix=pcall(function()
		local visual=obj:GetVisualBoneTransform(geometry.bones[bone].name)
		if not visual then return nil end
		local c={(geometry.bind_pose[bone]*visual):values()}
		if #c~=4 then return nil end
		local unit=Global("guim")
		local result={origin={c[1]:w()*unit,c[2]:w()*unit,c[3]:w()*unit},columns={}}
		result.columns[1]={c[1]:x()*unit,c[2]:x()*unit,c[3]:x()*unit}
		result.columns[2]={c[1]:y()*unit,c[2]:y()*unit,c[3]:y()*unit}
		result.columns[3]={c[1]:z()*unit,c[2]:z()*unit,c[3]:z()*unit}
		if math.abs(c[4]:x())+math.abs(c[4]:y())+math.abs(c[4]:z())>1e-5 or math.abs(c[4]:w()-1)>1e-5 then return nil end
		if not Geometry.RigidMatrix(result) then return nil end
		-- The renderer can lag a just-scaled object during preparation. Do not
		-- validate the old pose as if it described the new instance. Bone-local
		-- animation scaling also needs a richer decoder and fails closed here.
		if type(obj.GetWorldScale)~="function" then return nil end
		local column=result.columns[1]
		local scale=math.sqrt(column[1]^2+column[2]^2+column[3]^2)
		local expected=obj:GetWorldScale()*unit/100.0
		if not Finite(expected) or expected<=0 or math.abs(scale-expected)>expected*1e-4 then return nil end
		return result
	end)
	if not ok or not matrix then return nil,"current rigid bone pose unavailable" end
	return matrix
end

function Geometry.RigidMatrix(matrix)
	local columns=matrix and matrix.columns
	if not columns or #columns~=3 or not matrix.origin then return false end
	local lengths={}
	for i=1,3 do
		if not Finite(matrix.origin[i]) then return false end
		local length=0
		for a=1,3 do if not Finite(columns[i][a]) then return false end;length=length+columns[i][a]^2 end
		if length<1e-12 then return false end
		lengths[i]=length
	end
	for i=1,3 do for j=i+1,3 do
		local dot=0;for a=1,3 do dot=dot+columns[i][a]*columns[j][a] end
		if math.abs(dot)>math.sqrt(lengths[i]*lengths[j])*1e-4
			or math.abs(lengths[i]-lengths[j])>math.max(lengths[i],lengths[j])*1e-4 then return false end
	end end
	return true
end

function Geometry.Material(path)
	if type(path)~="string" or path=="" then return {complete=false,reason="material identity unavailable"} end
	if material_cache[path] then return material_cache[path] end
	local result={complete=false,path=path};material_cache[path]=result
	local ok,err=pcall(function()
		local resources=Global("ResourceManager")
		if not resources or type(resources.LoadToolResource)~="function" then result.reason="material API unavailable";return end
		local resource=resources.LoadToolResource(resources.GetResourceID(path))
		if not resource then result.reason="material resource unavailable";return end
		local data=resource:AsAnyRef():get()
		-- Alpha cutouts, projection and vertex deformation change the rendered
		-- coverage of CPU triangles. They need a separate decoder, not a solid
		-- support witness inferred from the undeformed/projection mesh.
		if type(data)~="table" or data.BlendType~="blendNone" or data.AlphaTestValue~=0
			or data.VertexNoise~="noiseNone" or data.SpecialType~="specialNone"
			or data.TerrainDistortedMode~="TerrainDistortedModeDisabled"
			or tostring(data.Displacement)~="TResRef('')" or data.Distortion~=false
			or data.ViewDependentOpacity~=0 or data.Terrain~=false then
			result.reason="material rendering coverage requires a separate decoder";return
		end
		result.complete=true
	end)
	if not ok then result.reason="material inspection failed: "..tostring(err) end
	return result
end

function Geometry.Entity(entity,state)
	local valid=Global("IsValidEntity")
	if type(entity)~="string" or entity=="" or (type(valid)=="function" and not valid(entity)) then
		return {parts={},complete=false,reason="entity geometry unavailable"}
	end
	local key=entity..":"..tostring(state)
	if entity_cache[key] then return entity_cache[key] end
	local result={parts={},complete=true,reason=false};entity_cache[key]=result
	local count,parts=Global("GetStateLODCount"),Global("GetStateLODMeshData")
	if type(count)~="function" or type(parts)~="function" then result.complete=false;result.reason="LOD API unavailable";return result end
	local ok,err=pcall(function()
		local n=count(entity,state)
		if type(n)~="number" or n<1 then result.complete=false;result.reason="no mesh LODs";return end
		for lod=0,n-1 do
			local list=parts(entity,state,lod)
			if type(list)~="table" or #list==0 then result.complete=false;result.reason="missing LOD meshes"
			else for _,part in ipairs(list) do
				local mesh=ReadMesh(part.mesh)
				local material=Geometry.Material(part.material)
				result.parts[#result.parts+1]={lod=lod,mesh=mesh,material=part.material,material_complete=material.complete}
				if not material.complete then result.complete=false;result.reason=material.reason end
				if not mesh.geometry then result.complete=false;result.reason=mesh.reason
				elseif mesh.geometry.animated and not mesh.geometry.rigid_skin then result.complete=false;result.reason=mesh.geometry.skin_reason end
				if mesh.geometry and mesh.geometry.animated then result.animated=true end
			end end
		end
	end)
	if not ok then result.complete=false;result.reason="entity inspection failed: "..tostring(err) end
	return result
end

function Geometry.Instance(obj)
	local get=Global("GetRenderingMeshLods")
	if type(get)~="function" then return {parts={},complete=false,reason="instance rendering descriptor unavailable"} end
	local ok,data=pcall(function()
		local descriptor=get(obj)
		return descriptor and descriptor:get()
	end)
	if not ok then return {parts={},complete=false,reason="instance rendering descriptor unreadable"} end
	-- A null override means the native entity/state descriptor is being rendered.
	if not data then return Geometry.Entity(obj:GetEntity(),obj:GetState()) end
	if type(data)~="table" or type(data.lods)~="table" or #data.lods==0 then
		return {parts={},complete=false,reason="instance rendering descriptor incomplete"}
	end
	local paths,key={},{}
	for lod,list in ipairs(data.lods) do
		if type(list.meshes)~="table" or #list.meshes==0 then return {parts={},complete=false,reason="instance LOD empty"} end
		for _,part in ipairs(list.meshes) do
			-- TResRef's read-only representation includes the exact resource name.
			-- Unknown representations fail closed; never infer an entity's original
			-- mesh when a per-instance replacement is actually being rendered.
			local path=tostring(part.mesh):match("^TResRef%('([^']+)'%)$")
			if not path then return {parts={},complete=false,reason="instance resource identity unavailable"} end
			local material=tostring(part.material):match("^TResRef%('([^']+)'%)$")
			paths[#paths+1]={lod=lod-1,path=path,material=material};key[#key+1]=lod..":"..path..":"..tostring(material)
		end
	end
	key=table.concat(key,"|")
	if override_cache[key] then return override_cache[key] end
	local result={parts={},complete=true};override_cache[key]=result
	for _,part in ipairs(paths) do
		local mesh=ReadMesh(part.path);local material=Geometry.Material(part.material)
		result.parts[#result.parts+1]={lod=part.lod,mesh=mesh,material=part.material,material_complete=material.complete}
		if not material.complete then result.complete=false;result.reason=material.reason end
		if not mesh.geometry then result.complete=false;result.reason=mesh.reason
		elseif mesh.geometry.animated and not mesh.geometry.rigid_skin then result.complete=false;result.reason=mesh.geometry.skin_reason end
		if mesh.geometry and mesh.geometry.animated then result.animated=true end
	end
	return result
end

-- Shared-asset triangle BVH. Instance checks transform only the query point;
-- they do not walk every triangle of a neighbouring cliff or wonder.
function Geometry.TriangleTree(geometry,component)
	if component.triangle_tree then return component.triangle_tree end
	local entries={};local vertices=geometry.vertices
	for _,triangle in ipairs(component.triangles) do
		local b=Bounds()
		for _,i in ipairs(triangle) do Extend(b,vertices[i]) end
		entries[#entries+1]={bounds=b,triangle=triangle}
	end
	local function build(items)
		local b=Bounds()
		for _,item in ipairs(items) do
			Extend(b,{item.bounds[1],item.bounds[2],item.bounds[3]})
			Extend(b,{item.bounds[4],item.bounds[5],item.bounds[6]})
		end
		local node={bounds=b}
		if #items<=12 then node.items=items;return node end
		local axis=1
		for a=2,3 do if b[a+3]-b[a]>b[axis+3]-b[axis] then axis=a end end
		table.sort(items,function(a,c)return a.bounds[axis]+a.bounds[axis+3]<c.bounds[axis]+c.bounds[axis+3] end)
		local left,right={},{};local middle=math.floor(#items/2.0)
		for i,item in ipairs(items) do local list=i<=middle and left or right;list[#list+1]=item end
		node.left,node.right=build(left),build(right);return node
	end
	component.triangle_tree=build(entries);return component.triangle_tree
end

-- Separating-axis proof for two rigid triangles, including the coplanar case.
-- True means the rendered triangles are disjoint by more than the tolerance.
function Geometry.TrianglesSeparated(a,b,tolerance)
	local function sub(p,q)return {p[1]-q[1],p[2]-q[2],p[3]-q[3]}end
	local function cross(p,q)return {p[2]*q[3]-p[3]*q[2],p[3]*q[1]-p[1]*q[3],p[1]*q[2]-p[2]*q[1]}end
	local function separated(axis)
		local length=math.sqrt(axis[1]^2+axis[2]^2+axis[3]^2)
		if length<1e-12 then return false end
		local al,ah,bl,bh=math.huge,-math.huge,math.huge,-math.huge
		for i=1,3 do
			local x=a[i][1]*axis[1]+a[i][2]*axis[2]+a[i][3]*axis[3]
			local y=b[i][1]*axis[1]+b[i][2]*axis[2]+b[i][3]*axis[3]
			al=math.min(al,x);ah=math.max(ah,x);bl=math.min(bl,y);bh=math.max(bh,y)
		end
		return al>bh+tolerance*length or bl>ah+tolerance*length
	end
	local ae={sub(a[2],a[1]),sub(a[3],a[2]),sub(a[1],a[3])}
	local be={sub(b[2],b[1]),sub(b[3],b[2]),sub(b[1],b[3])}
	local an,bn=cross(ae[1],ae[2]),cross(be[1],be[2])
	if separated(an) or separated(bn) then return true end
	for i=1,3 do
		if separated(cross(an,ae[i])) or separated(cross(bn,be[i])) then return true end
		for j=1,3 do if separated(cross(ae[i],be[j])) then return true end end
	end
	return false
end

Geometry.ReadMesh=ReadMesh
Geometry.Bounds=Bounds
Geometry.Extend=Extend
function Geometry.RetryIncomplete()
	-- Loading/switching can make previously unavailable resources readable. Keep
	-- successful shared decodes/BVHs, but never freeze missing data into a pass or
	-- permanently skip retrying an unverifiable asset.
	for key,row in pairs(mesh_cache) do if not row.geometry then mesh_cache[key]=nil end end
	for key,row in pairs(material_cache) do if not row.complete then material_cache[key]=nil end end
	for key,row in pairs(entity_cache) do if not row.complete then entity_cache[key]=nil end end
	for key,row in pairs(override_cache) do if not row.complete then override_cache[key]=nil end end
end
Geometry.ClearCache=function()mesh_cache={};material_cache={};entity_cache={};override_cache={}end
SBM.DecorationGeometry=Geometry
