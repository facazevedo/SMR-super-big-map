-- Read-only mesh inspection. Never uploads/replaces a mesh or mutates a resource.
-- A missing/unsupported layout is evidence of incomplete coverage, not a pass.
local SBM = rawget(_G, "SuperBigMap")
local Global = SBM.Engine.Global
local Geometry = {}
local mesh_cache, material_cache, entity_cache, override_cache = {}, {}, {}, {}
local verified_poses, decoded_poses = {}, {}
local preparing_poses = false
-- Retain ownership after failed native removal, including across cache clears.
-- A retry must clean these references before creating another diagnostic batch.
local pending_pose_references = {}
local type,tostring,ipairs,pairs,pcall=type,tostring,ipairs,pairs,pcall
local math,string,table=math,string,table

local function Finite(n)
	return type(n) == "number" and n == n and n > -math.huge and n < math.huge
end

local function Bounds()
	return { math.huge, math.huge, math.huge, -math.huge, -math.huge, -math.huge }
end

local function Extend(b, p)
	for a = 1, 3 do
		local value=p[a]
		if value<b[a] then b[a]=value end
		if value>b[a+3] then b[a+3]=value end
	end
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
	-- A 48-bit key represents the three signed-16 coordinates exactly. Use it
	-- only when adjacent quantization steps are comfortably farther apart than
	-- the old 12-significant-digit string key's rounding. Otherwise retain that
	-- key verbatim. This avoids decimal formatting for every ordinary packed
	-- vertex without changing which UV seams are joined.
	local largest=0
	for a=1,6 do largest=math.max(largest,math.abs(bounds[a])) end
	local packed_keys=packed and quantum>0 and quantum>largest*1e-10 and {} or nil
	local bytes, vertices, decoded_bounds = geom.vertices, {}, Bounds()
	local function s16(i)
		local a,b = bytes[i],bytes[i+1]
		if type(a)~="number" or type(b)~="number"
			or not (a>=0 and a<=255 and b>=0 and b<=255) then return nil end
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
			local qx,qy,qz=s16(base+xy.offset),s16(base+xy.offset+2),s16(base+z.offset)
			if qx==nil or qy==nil or qz==nil then return nil,"invalid position bytes" end
			p[1],p[2],p[3]=center[1]+qx*quantum,center[2]+qy*quantum,center[3]+qz*quantum
			if packed_keys and (qx%1~=0 or qy%1~=0 or qz%1~=0) then packed_keys=nil end
			if packed_keys then packed_keys[i+1]=(qx+32768)+(qy+32768)*65536+(qz+32768)*4294967296 end
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
	local parent, used, coincident, bone_coincident = {}, {}, {}, {}
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
		local key=packed_keys and packed_keys[i]
		local lookup=coincident
		if key and bones then
			lookup=bone_coincident[bones[i]]
			if not lookup then lookup={};bone_coincident[bones[i]]=lookup end
		elseif not key then
			key=string.format("%.12g,%.12g,%.12g:%s",p[1],p[2],p[3],bones and bones[i] or "static")
		end
		if lookup[key] then join(i,lookup[key]) else lookup[key]=i end
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
		if not component then component={bounds=Bounds(),vertices={},triangles={},extrema_indices={}};groups[r]=component;components[#components+1]=component end
		component.vertices[#component.vertices+1]=i
		-- This visit already calculates every component extremum. Keep the first
		-- attaining vertex too, instead of scanning the same vertex list seven
		-- more times for six contact witnesses and the bottom witness below.
		local p,b,extrema=vertices[i],component.bounds,component.extrema_indices
		for axis=1,3 do
			if p[axis]<b[axis] then b[axis]=p[axis];extrema[2*axis-1]=i end
			if p[axis]>b[axis+3] then b[axis+3]=p[axis];extrema[2*axis]=i end
		end
	end end
	for _,t in ipairs(rendered_triangles) do
		local a,b,c=t[1],t[2],t[3]
		local triangles=groups[root(a)].triangles
		triangles[#triangles+1]=t
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
		for _,best in ipairs(component.extrema_indices) do
			if best and not seen[best] then samples[#samples+1]=vertices[best];seen[best]=true end
		end
		component.samples=samples
		component.bottom=vertices[component.extrema_indices[5]]
		component.extrema_indices=nil
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
				decoded.bones=skeleton_data.bones;decoded.bind_pose=skin.bindPose;decoded.skeleton_path=path
			else decoded.rigid_skin=false;decoded.skin_reason="skeleton binding unavailable" end
		end
		if decoded then decoded.resource_path=path end
		result.geometry=decoded;result.reason=why
		if decoded then result.status="decoded" end
	end)
	if not ok then result.reason="mesh inspection failed: "..tostring(err) end
	return result
end

local function DecodeKnownPose(name)
	if decoded_poses[name] then return decoded_poses[name] end
	local bank=SBM.DecorationKnownPoses;local pose=bank and bank.poses[name]
	if not pose then return nil end
	local matrices={};local bytes=pose.hex:gsub("..",function(h)return string.char(tonumber(h,16))end)
	if #bytes~=pose.count*49 then return nil end
	for offset=1,#bytes,49 do
		local n,x,y,z,a,b,c,d,e,f,g,h,i=string.unpack("<Bffffffffffff",bytes,offset)
		matrices[n]={origin={x,y,z},columns={{a,b,c},{d,e,f},{g,h,i}}}
		if not Geometry.RigidMatrix(matrices[n]) then return nil end
	end
	decoded_poses[name]=matrices;return matrices
end

local function CleanupPoseReferences()
	if #pending_pose_references==0 then return true end
	local valid,done=Global("IsValid"),Global("DoneObject")
	if type(valid)~="function" or type(done)~="function" then return false,"reference cleanup API unavailable" end
	local remaining,errors={},{}
	for _,obj in ipairs(pending_pose_references) do
		local checked,alive=pcall(valid,obj)
		if checked and alive==true then
			local removed,why=pcall(done,obj)
			if not removed then errors[#errors+1]=tostring(why) end
			checked,alive=pcall(valid,obj)
		end
		if not checked or type(alive)~="boolean" or alive then
			remaining[#remaining+1]=obj
			errors[#errors+1]="reference survived cleanup or validity unavailable"
		end
	end
	pending_pose_references=remaining
	return #errors==0,table.concat(errors,"; ")
end

-- The renderer does not expose bone transforms on every inactive/off-screen
-- instance. Before using this cache, compare every component against native
-- rendering at EVERY integer idle phase and the one terminal falling phase.
-- This uses only public mod APIs; native animation file reads are sandboxed.
-- Disposable references have no collision, grid, selection or shadow flags and
-- sit below terrain. No player object or shared rendering resource is modified.
function Geometry.PrepareKnownPoses(reference_position)
	local bank=SBM.DecorationKnownPoses
	if not bank then return false,"known pose data unavailable" end
	local geometry=ReadMesh(bank.mesh).geometry
	if not geometry or not geometry.rigid_skin or not geometry.bones or #geometry.bones~=bank.bone_count then
		return false,"known pose geometry unavailable"
	end
	if verified_poses[geometry] and #pending_pose_references==0 then return true end
	local sleep,can_yield=Global("Sleep"),Global("CanYield")
	if type(sleep)~="function" or type(can_yield)~="function" or not can_yield() then return false,"pose preparation needs a yielding thread" end
	while preparing_poses do sleep(10) end
	if verified_poses[geometry] and #pending_pose_references==0 then return true end
	local map=Global("CurrentMap");if not map then return false,"no active render map" end
	preparing_poses=true
	local cleaned,cleanup_error=CleanupPoseReferences()
	if not cleaned then preparing_poses=false;return false,"reference cleanup failed: "..tostring(cleanup_error) end
	local created,prepared={},{};local failure
	local ok,why=pcall(function()
		local c=Global("const");local point=Global("point");local unit=Global("guim")
		local origin={0,0,-10000}
		if reference_position then origin={reference_position:xyz()} end
		for i=1,3 do
			if type(origin[i])~="number" or origin[i]~=origin[i] or math.abs(origin[i])==math.huge then
				failure="invalid reference origin";return
			end
		end
		local excluded=c.efCollision+c.efWalkable+c.efApplyToGrids+c.efSelectable+c.efLightShadow+c.efSunShadow
		for name,pose in pairs(bank.poses) do
			local matrices=DecodeKnownPose(name);if not matrices then failure="invalid recorded pose";return end
			prepared[name]={}
			local first,last=pose.phase,pose.phase
			if name=="idle" then first,last=0,pose.duration-1 end
			local flags_to_verify=name=="falling" and {c.eDontLoop} or {0}
			if name=="falling" and c.eDontLoop~=32768 then failure="native terminal animation flag unavailable";return end
			for phase=first,last do for _,flags in ipairs(flags_to_verify) do
				prepared[name][phase]=prepared[name][phase] or {}
				local obj=Global("PlaceObject")("Shapeshifter",nil,map);created[#created+1]={obj=obj,name=name,phase=phase,flags=flags}
				pending_pose_references[#pending_pose_references+1]=obj
				obj:ClearEnumFlags(excluded);obj:ChangeEntity(bank.entity);obj:ClearEnumFlags(excluded)
				obj:SetGameFlags(c.gofPriorityAnim)
				obj:SetPos(point(table.unpack(origin)));obj:SetAngle(0);obj:SetScale(100)
				-- Native state metadata supplies eDontLoop for falling; SetStateText's
				-- arguments are not permission to invent another flag variant.
				obj:SetStateText(name,0,0);obj:SetAnimPhase(1,phase);obj:SetAnimSpeed(1,0)
				local actual_flags=obj:GetAnimFlags(1)
				if actual_flags~=flags and not (flags==32768 and actual_flags==-32768) then failure="native reference animation flags differ";return end
				if Global("GetAnimDuration")(bank.entity,obj:GetState())~=pose.duration
					or Global("GetStateAnimFile")(bank.entity,obj:GetState())~=pose.file then failure="native animation changed";return end
			end end
		end
		-- Render initialization is asynchronous. Retry unavailable poses, not a
		-- mismatching initialized pose, and publish nothing until all tests pass.
		for attempt=1,50 do
			sleep(20)
			if Global("CurrentMap")~=map then failure="render map changed during pose preparation";return end
			local complete=true
			for _,row in ipairs(created) do if not prepared[row.name][row.phase][row.flags] then
				if not Global("IsValid")(row.obj) then failure="reference object disappeared";return end
				local ready=true;local matrices=DecodeKnownPose(row.name)
				for _,component in ipairs(geometry.components) do
					local actual=Geometry.BoneMatrix(row.obj,geometry,component.bone)
					local cached=matrices[component.bone]
					if not cached then failure="recorded bone missing";return end
					if not actual then ready=false;break end
					for _,index in ipairs(component.vertices) do
						local p=geometry.vertices[index]
						for a=1,3 do
							local live=actual.origin[a]+actual.columns[1][a]*p[1]+actual.columns[2][a]*p[2]+actual.columns[3][a]*p[3]
							local expected=origin[a]+unit*(cached.origin[a]+cached.columns[1][a]*p[1]+cached.columns[2][a]*p[2]+cached.columns[3][a]*p[3])
							if math.abs(live-expected)>0.5 then failure="native settled pose differs from recorded geometry";return end
						end
					end
				end
				if ready then prepared[row.name][row.phase][row.flags]=true else complete=false end
			end end
			if complete then return end
		end
		failure="native reference poses unavailable"
	end)
	cleaned,cleanup_error=CleanupPoseReferences()
	if not cleaned then failure="reference cleanup failed: "..tostring(cleanup_error) end
	preparing_poses=false
	if not ok or failure then return false,failure or tostring(why) end
	verified_poses[geometry]=prepared
	return true
end

function Geometry.KnownBoneMatrix(obj,geometry,bone)
	local bank=SBM.DecorationKnownPoses
	if not bank or obj.class~="CaveInRubble" or obj:GetEntity()~=bank.entity
		or geometry.resource_path~=bank.mesh or geometry.skeleton_path~=bank.skeleton
		or #geometry.bones~=bank.bone_count or #geometry.bind_pose~=bank.bone_count
		or obj:GetParent() or obj:GetMirrored() or obj:GetWarped()
		or obj:GetSkewX()~=0 or obj:GetSkewY()~=0 then return nil end
	local name=obj:GetStateText();local pose=bank.poses[name]
	local flags=obj:GetAnimFlags(1)
	if name=="falling" and flags==-32768 then flags=32768 end
	if flags~=0 and not (name=="falling" and flags==32768 and (Global("const") or {}).eDontLoop==32768) then return nil end
	if not pose or obj:GetAnim(1)~=obj:GetState()
		or obj:GetAnimWeight(1)~=1000 or obj:GetAnimCrossfade(1)~=0 then return nil end
	local channels=(Global("const") or {}).MaxAnimChannels
	if type(channels)~="number" then return nil end
	for channel=2,channels do if obj:GetAnim(channel)~=-1 then return nil end end
	local phase=obj:GetAnimPhase(1)
	if (name=="falling" and phase~=pose.phase) or phase<0 or phase>=pose.duration then return nil end
	if Global("GetAnimDuration")(bank.entity,obj:GetState())~=pose.duration
		or Global("GetStateAnimFile")(bank.entity,obj:GetState())~=pose.file then return nil end
	local verified=verified_poses[geometry]
	if not verified or not verified[name] or not verified[name][phase] or not verified[name][phase][flags] then return nil end
	local matrices=DecodeKnownPose(name);if not matrices then return nil end
	local cached=matrices[bone];if not cached then return nil end
	local point=Global("point");local unit=Global("guim")
	local p=obj:GetRelativePoint(point(0,0,0));local origin={p:xyz()};local basis={}
	for a=1,3 do
		local q={0,0,0};q[a]=100*unit
		local v={obj:GetRelativePoint(point(q[1],q[2],q[3])):xyz()}
		basis[a]={(v[1]-origin[1])/100.0,(v[2]-origin[2])/100.0,(v[3]-origin[3])/100.0}
	end
	local result={origin={},columns={{},{},{}}}
	for a=1,3 do
		result.origin[a]=origin[a]+basis[1][a]*cached.origin[1]+basis[2][a]*cached.origin[2]+basis[3][a]*cached.origin[3]
		for c=1,3 do result.columns[c][a]=basis[1][a]*cached.columns[c][1]+basis[2][a]*cached.columns[c][2]+basis[3][a]*cached.columns[c][3] end
	end
	if not Geometry.RigidMatrix(result) then return nil end
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
	if not ok or not matrix then
		local known,cached=pcall(Geometry.KnownBoneMatrix,obj,geometry,bone)
		if known and cached then return cached end
		return nil,"current rigid bone pose unavailable"
	end
	return matrix
end

-- Read the native floating rigid transform, restoring the local-Y reflection
-- omitted by GetTransformMatrix's decomposition. Never accept a stale visual
-- pose: independently compare its origin and long basis with GetRelativePoint.
function Geometry.NativeRigidMatrix(obj)
	if type(obj.GetTransformMatrix)~="function" or type(obj.GetMirrored)~="function"
		or type(obj.GetRelativePoint)~="function" or obj:GetParent() then return nil end
	local ok,result=pcall(function()
		local rows={obj:GetTransformMatrix():values()};if #rows~=4 then return nil end
		local unit=Global("guim");local mirrored=obj:GetMirrored() and -1 or 1
		local matrix={origin={},columns={{},{},{}}}
		for a=1,3 do
			matrix.origin[a]=rows[a]:w()*unit
			matrix.columns[1][a]=rows[a]:x()*unit
			matrix.columns[2][a]=rows[a]:y()*unit*mirrored
			matrix.columns[3][a]=rows[a]:z()*unit
		end
		if math.abs(rows[4]:x())+math.abs(rows[4]:y())+math.abs(rows[4]:z())>1e-6
			or math.abs(rows[4]:w()-1)>1e-6 or not Geometry.RigidMatrix(matrix) then return nil end
		local expected=obj:GetWorldScale()*unit/100.0
		local column=matrix.columns[1]
		if not Finite(expected) or expected<=0 or math.abs(math.sqrt(column[1]^2+column[2]^2+column[3]^2)-expected)>expected*1e-4 then return nil end
		for basis=0,3 do
			local p={0,0,0};if basis>0 then p[basis]=100*unit end
			local native={obj:GetRelativePoint(Global("point")(p[1],p[2],p[3])):xyz()}
			for a=1,3 do
				local predicted=matrix.origin[a]+(basis>0 and matrix.columns[basis][a]*100 or 0)
				if not Finite(native[a]) or math.abs(predicted-native[a])>2 then return nil end
			end
		end
		return matrix
	end)
	return ok and result or nil
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
		-- TerrainBakedDecal renders into terrain splat textures, not a freestanding
		-- surface. Alpha/blending affect those textures, not physical support. Keep
		-- this evidence distinct from opaque solid geometry.
		if type(data)=="table" and data.SpecialType=="specialBakedDecal"
			and data.VertexNoise=="noiseNone" and data.TerrainDistortedMode=="TerrainDistortedModeDisabled"
			and tostring(data.Displacement)=="TResRef('')" and data.Distortion==false then
			result.render_kind="terrain texture projection"
		end
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
		if n==0 and entity=="InvisibleObject" then result.render_kind="native non-rendering entity";return end
		if type(n)~="number" or n<1 then result.complete=false;result.reason="no mesh LODs";return end
		local all_projected=true
		for lod=0,n-1 do
			local list=parts(entity,state,lod)
			if type(list)~="table" or #list==0 then result.complete=false;all_projected=false;result.reason="missing LOD meshes"
			else for _,part in ipairs(list) do
				local mesh=ReadMesh(part.mesh)
				local material=Geometry.Material(part.material)
				result.parts[#result.parts+1]={lod=lod,mesh=mesh,material=part.material,material_complete=material.complete,render_kind=material.render_kind}
				if not material.render_kind then all_projected=false end
				if not material.complete then result.complete=false;result.reason=material.reason end
				if not mesh.geometry then result.complete=false;result.reason=mesh.reason
				elseif mesh.geometry.animated and not mesh.geometry.rigid_skin then result.complete=false;result.reason=mesh.geometry.skin_reason end
				if mesh.geometry and mesh.geometry.animated then result.animated=true end
			end end
		end
		if all_projected and #result.parts>0 then result.render_kind="terrain texture projection" end
	end)
	if not ok then result.complete=false;result.reason="entity inspection failed: "..tostring(err) end
	return result
end

local logical_marker_asset={parts={},complete=true,render_kind="native non-rendering logical marker"}
-- Particle carriers have no solid mesh to seat. Verify their *native effect
-- recipe and ownership*, not an empty entity or a particular wonder's name.
-- This is effect-placement evidence, never a solid-support witness for rocks.
function Geometry.ParticleAttachment(obj)
	local kind,valid,is_particle=Global("IsKindOf"),Global("IsValid"),Global("IsParticleSystem")
	local get,rules,c=Global("GetRenderingMeshLods"),Global("FXLists"),Global("const")
	if type(kind)~="function" or not kind(obj,"ParSystem") or type(valid)~="function"
		or type(is_particle)~="function" or type(get)~="function" or not rules or not c then return nil end
	local ok,evidence=pcall(function()
		local parent=obj:GetParent();local name=obj:GetParticlesName()
		if not valid(parent) or obj:GetEntity()~="" or not is_particle(name) then return end
		local descriptor=get(obj);if not descriptor or descriptor:get()~=nil then return end
		if not c.efWalkable or not c.efCollision or not c.efApplyToGrids
			or obj:GetEnumFlags(c.efWalkable+c.efCollision+c.efApplyToGrids)~=0 then return end
		local actor=parent.fx_actor_class or parent.class
		local x,y,z=obj:GetAttachOffset():xyz();local spot=obj:GetAttachSpot()
		if obj:GetAttachAngle()~=0 then return end
		for _,rule in ipairs(rules.ActionFXParticles or {}) do
			if not rule.Disabled and rule.Attach==true and rule.Source=="Actor" and rule.SourceRemap==false
				and rule.Actor==actor and rule.Target=="any" and rule.ScaleMember=="" and rule.Flags==""
				and rule.Orientation=="" and rule.Scale==obj:GetScale() and type(rule.GetAssignedFX)=="function" then
				local assigned=rule:GetAssignedFX(parent,false);local owned=assigned==obj
				if type(assigned)=="table" and not owned then for _,o in ipairs(assigned) do if o==obj then owned=true;break end end end
				local asset=name==rule.Particles or name==rule.Particles2 or name==rule.Particles3 or name==rule.Particles4
				local a,b=parent:GetSpotRange(rule.Spot);local ox,oy,oz=rule.Offset:xyz()
				if owned and asset and type(a)=="number" and type(b)=="number" and spot>=a and spot<=b
					and parent:GetSpotName(spot)==rule.Spot and x==ox and y==oy and z==oz then
					return {rule=rule.id,particle=name,spot=spot,parent=actor,scope="native effect attachment and recipe"}
				end
			end
		end
	end)
	return ok and evidence or nil
end

local function InstanceAsset(obj)
	local get=Global("GetRenderingMeshLods")
	if type(get)~="function" then return {parts={},complete=false,reason="instance rendering descriptor unavailable"} end
	local ok,data=pcall(function()
		local descriptor=get(obj)
		return descriptor and descriptor:get()
	end)
	if not ok then return {parts={},complete=false,reason="instance rendering descriptor unreadable"} end
	-- A null override means the native entity/state descriptor is being rendered.
	if not data then
		local effect=Geometry.ParticleAttachment(obj)
		if effect then return {parts={},complete=true,render_kind="verified native particle attachment",effect=effect} end
		-- PrefabFeature creates entity-less SafariSight logic objects after the
		-- decoration capture. Confirm the absence of an instance override before
		-- classifying them: an absent entity alone is not missing-mesh evidence.
		-- MapSector also owns logical exploration bookkeeping, not the separate
		-- sector decal/scan objects. Its point bounds must not obstruct rocks.
		if (obj.class=="SafariSight" or obj.class=="MapSector") and obj:GetEntity()=="" then return logical_marker_asset end
		return Geometry.Entity(obj:GetEntity(),obj:GetState())
	end
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
	local all_projected=true
	for _,part in ipairs(paths) do
		local mesh=ReadMesh(part.path);local material=Geometry.Material(part.material)
		result.parts[#result.parts+1]={lod=part.lod,mesh=mesh,material=part.material,material_complete=material.complete,render_kind=material.render_kind}
		if not material.render_kind then all_projected=false end
		if not material.complete then result.complete=false;result.reason=material.reason end
		if not mesh.geometry then result.complete=false;result.reason=mesh.reason
		elseif mesh.geometry.animated and not mesh.geometry.rigid_skin then result.complete=false;result.reason=mesh.geometry.skin_reason end
		if mesh.geometry and mesh.geometry.animated then result.animated=true end
	end
	if all_projected then result.render_kind="terrain texture projection" end
	return result
end

function Geometry.Instance(obj)
	local asset=InstanceAsset(obj)
	local forced=type(obj.GetForcedLOD)=="function" and obj:GetForcedLOD()
	if type(forced)~="number" or forced<0 then return asset end
	asset.forced_views=asset.forced_views or {}
	if asset.forced_views[forced] then return asset.forced_views[forced] end
	local result={parts={},complete=true,forced_lod=forced,available_parts=#asset.parts}
	local projected=true
	for _,part in ipairs(asset.parts) do if part.lod==forced then
		result.parts[#result.parts+1]=part
		local g=part.mesh.geometry
		if not part.render_kind then projected=false end
		if not g or part.material_complete==false or (g.animated and not g.rigid_skin) then
			result.complete=false;result.reason=asset.reason or "forced LOD geometry unavailable"
		end
		if g and g.animated then result.animated=true end
	end end
	if #result.parts==0 then result.complete=false;result.reason="forced LOD does not have verified geometry"
	elseif projected then result.render_kind="terrain texture projection" end
	asset.forced_views[forced]=result
	return result
end

-- Shared-asset triangle BVH. Instance checks transform only the query point;
-- they do not walk every triangle of a neighbouring cliff or wonder.
-- UV/normal seams repeat the very same rendered position. Extrema, terrain
-- support and visible-height calculations can visit it once; triangles and
-- composition fingerprints continue to use the complete original buffers.
function Geometry.SupportVertices(geometry,component)
	if component.support_vertices then return component.support_vertices end
	local result,seen={},{}
	for _,i in ipairs(component.vertices) do
		local p=geometry.vertices[i]
		local xs=seen[p[1]];if not xs then xs={};seen[p[1]]=xs end
		local ys=xs[p[2]];if not ys then ys={};xs[p[2]]=ys end
		if not ys[p[3]] then ys[p[3]]=true;result[#result+1]=i end
	end
	component.support_vertices=result
	return result
end

function Geometry.TriangleTree(geometry,component)
	if component.triangle_tree then return component.triangle_tree end
	local entries={};local vertices=geometry.vertices
	for _,triangle in ipairs(component.triangles) do
		local a,b,c=vertices[triangle[1]],vertices[triangle[2]],vertices[triangle[3]]
		local b={math.min(a[1],b[1],c[1]),math.min(a[2],b[2],c[2]),math.min(a[3],b[3],c[3]),
			math.max(a[1],b[1],c[1]),math.max(a[2],b[2],c[2]),math.max(a[3],b[3],c[3])}
		entries[#entries+1]={bounds=b,triangle=triangle}
	end
	local function build(first,last)
		local b=Bounds()
		for i=first,last do
			local a=entries[i].bounds
			-- These entries already have complete finite bounds. Preserve the exact
			-- extrema while avoiding six library calls per entry at every tree level.
			if a[1]<b[1] then b[1]=a[1] end
			if a[2]<b[2] then b[2]=a[2] end
			if a[3]<b[3] then b[3]=a[3] end
			if a[4]>b[4] then b[4]=a[4] end
			if a[5]>b[5] then b[5]=a[5] end
			if a[6]>b[6] then b[6]=a[6] end
		end
		local node={bounds=b}
		-- Smaller leaves avoid the Cartesian product of up to 12 x 12 triangle
		-- boxes in paired-mesh queries. Every triangle remains in the hierarchy;
		-- this changes only the partition granularity, not the contact predicate.
		if last-first<4 then
			node.items={};for i=first,last do node.items[#node.items+1]=entries[i] end
			return node
		end
		local axis=1
		for a=2,3 do if b[a+3]-b[a]>b[axis+3]-b[axis] then axis=a end end
		local middle=math.floor((first+last)/2.0)
		-- Only the median partition is needed, not a full sort at every level.
		-- Partition one shared entry array in place; every original triangle still
		-- occurs exactly once and each node retains its complete geometric bounds.
		local function center(i)local a=entries[i].bounds;return a[axis]+a[axis+3] end
		local lo,hi=first,last
		while lo<hi do
			local pivot=center(math.floor((lo+hi)/2.0));local i,j=lo,hi
			while i<=j do
				while center(i)<pivot do i=i+1 end
				while center(j)>pivot do j=j-1 end
				if i<=j then entries[i],entries[j]=entries[j],entries[i];i,j=i+1,j-1 end
			end
			if middle<=j then hi=j elseif middle>=i then lo=i else break end
		end
		node.left,node.right=build(first,middle),build(middle+1,last);return node
	end
	component.triangle_tree=build(1,#entries);return component.triangle_tree
end

-- Separating-axis proof for two rigid triangles, including the coplanar case.
-- True means the rendered triangles are disjoint by more than the tolerance.
function Geometry.TrianglesSeparated(a,b,tolerance)
	-- Same axes, arithmetic order and thresholds; avoid allocating a vector for
	-- each edge/cross product in this triangle-pair hot path.
	-- The second result retains the zero-tolerance decision from these same
	-- projections, so contact callers need not repeat the entire SAT traversal.
	local strictly_separated=false
	-- Each of the seventeen candidate axes reads the same six vertices. Bind
	-- their scalar coordinates once, retaining the original projection arithmetic
	-- and comparison order without repeated nested-table reads or loop setup.
	local apx,apy,apz=a[1][1],a[1][2],a[1][3]
	local aqx,aqy,aqz=a[2][1],a[2][2],a[2][3]
	local arx,ary,arz=a[3][1],a[3][2],a[3][3]
	local bpx,bpy,bpz=b[1][1],b[1][2],b[1][3]
	local bqx,bqy,bqz=b[2][1],b[2][2],b[2][3]
	local brx,bry,brz=b[3][1],b[3][2],b[3][3]
	local function separated(ax,ay,az)
		local x,y=apx*ax+apy*ay+apz*az,bpx*ax+bpy*ay+bpz*az
		local al,ah,bl,bh=x,x,y,y
		x,y=aqx*ax+aqy*ay+aqz*az,bqx*ax+bqy*ay+bqz*az
		if x<al then al=x end;if x>ah then ah=x end
		if y<bl then bl=y end;if y>bh then bh=y end
		x,y=arx*ax+ary*ay+arz*az,brx*ax+bry*ay+brz*az
		if x<al then al=x end;if x>ah then ah=x end
		if y<bl then bl=y end;if y>bh then bh=y end
		-- Overlapping projections cannot separate at a nonnegative tolerance.
		-- Only a real gap needs axis normalization; keep the original square
		-- root and degeneracy threshold on that path (including tiny axes).
		if tolerance>=0 and al<=bh and bl<=ah then return false end
		local length=math.sqrt(ax^2+ay^2+az^2)
		if length<1e-12 then return false end
		if al>bh or bl>ah then strictly_separated=true end
		return al>bh+tolerance*length or bl>ah+tolerance*length
	end
	local a1x,a1y,a1z=a[2][1]-a[1][1],a[2][2]-a[1][2],a[2][3]-a[1][3]
	local a2x,a2y,a2z=a[3][1]-a[2][1],a[3][2]-a[2][2],a[3][3]-a[2][3]
	local b1x,b1y,b1z=b[2][1]-b[1][1],b[2][2]-b[1][2],b[2][3]-b[1][3]
	local b2x,b2y,b2z=b[3][1]-b[2][1],b[3][2]-b[2][2],b[3][3]-b[2][3]
	local anx,any,anz=a1y*a2z-a1z*a2y,a1z*a2x-a1x*a2z,a1x*a2y-a1y*a2x
	local bnx,bny,bnz=b1y*b2z-b1z*b2y,b1z*b2x-b1x*b2z,b1x*b2y-b1y*b2x
	if separated(anx,any,anz) or separated(bnx,bny,bnz) then return true,true end
	for i=1,3 do
		local ax,ay,az,bx,by,bz
		if i==1 then ax,ay,az,bx,by,bz=a1x,a1y,a1z,b1x,b1y,b1z
		elseif i==2 then ax,ay,az,bx,by,bz=a2x,a2y,a2z,b2x,b2y,b2z
		else ax,ay,az=a[1][1]-a[3][1],a[1][2]-a[3][2],a[1][3]-a[3][3]
			bx,by,bz=b[1][1]-b[3][1],b[1][2]-b[3][2],b[1][3]-b[3][3] end
		if separated(any*az-anz*ay,anz*ax-anx*az,anx*ay-any*ax)
			or separated(bny*bz-bnz*by,bnz*bx-bnx*bz,bnx*by-bny*bx) then return true,true end
		for j=1,3 do
			if j==1 then bx,by,bz=b1x,b1y,b1z
			elseif j==2 then bx,by,bz=b2x,b2y,b2z
			else bx,by,bz=b[1][1]-b[3][1],b[1][2]-b[3][2],b[1][3]-b[3][3] end
			if separated(ay*bz-az*by,az*bx-ax*bz,ax*by-ay*bx) then return true,true end
		end
	end
	return false,strictly_separated
end

Geometry.ReadMesh=ReadMesh

-- First contact while A translates vertically downward, with fixed orientation.
-- Intersect the continuous overlap intervals of every triangle SAT axis; this
-- cannot jump through a thin support as a sampled/binary height search could.
function Geometry.VerticalTriangleContact(a,b,maximum)
	local low,high=0,maximum
	local function axis(x,y,z)
		if x*x+y*y+z*z<1e-24 then return true end
		local al,ah,bl,bh=math.huge,-math.huge,math.huge,-math.huge
		for i=1,3 do
			local p=a[i][1]*x+a[i][2]*y+a[i][3]*z
			local q=b[i][1]*x+b[i][2]*y+b[i][3]*z
			al=math.min(al,p);ah=math.max(ah,p);bl=math.min(bl,q);bh=math.max(bh,q)
		end
		if z==0 then return al<=bh and bl<=ah end
		local enter,leave=(bl-ah)/(-z),(bh-al)/(-z)
		if enter>leave then enter,leave=leave,enter end
		low=math.max(low,enter);high=math.min(high,leave)
		return low<=high
	end
	local function sub(p,q)return {p[1]-q[1],p[2]-q[2],p[3]-q[3]}end
	local function cross(p,q)return {p[2]*q[3]-p[3]*q[2],p[3]*q[1]-p[1]*q[3],p[1]*q[2]-p[2]*q[1]}end
	local ae={sub(a[2],a[1]),sub(a[3],a[2]),sub(a[1],a[3])}
	local be={sub(b[2],b[1]),sub(b[3],b[2]),sub(b[1],b[3])}
	local an,bn=cross(ae[1],ae[2]),cross(be[1],be[2])
	if not axis(1,0,0) or not axis(0,1,0) or not axis(0,0,1)
		or not axis(table.unpack(an)) or not axis(table.unpack(bn)) then return nil end
	for i=1,3 do
		if not axis(table.unpack(cross(an,ae[i]))) or not axis(table.unpack(cross(bn,be[i]))) then return nil end
		for j=1,3 do if not axis(table.unpack(cross(ae[i],be[j]))) then return nil end end
	end
	return low
end

-- Value-only identity for comparison with a captured native composition. This
-- is not a support witness: matching a detached native piece never grounds it.
-- Hash decoded vertices/topology, not only the resource path or mesh bounds.
function Geometry.CompositionSignature(asset)
	if not asset or not asset.complete or #asset.parts==0 then return nil end
	local hash=Global("xxhash")
	if type(hash)~="function" or type(string.pack)~="function" then return nil end
	local parts={}
	for _,part in ipairs(asset.parts) do
		local g=part.mesh and part.mesh.geometry
		if not g or part.material_complete==false then return nil end
		if not g.composition_signature then
			local bytes={}
			for _,p in ipairs(g.vertices) do bytes[#bytes+1]=string.pack("<ddd",p[1],p[2],p[3]) end
			for _,c in ipairs(g.components) do
				bytes[#bytes+1]=string.pack("<i4I4",c.bone or 0,#c.triangles)
				for _,t in ipairs(c.triangles) do bytes[#bytes+1]=string.pack("<I4I4I4",t[1],t[2],t[3]) end
			end
			g.composition_signature=tostring(hash(table.concat(bytes)))
		end
		parts[#parts+1]=table.concat({part.lod,part.mesh.path,tostring(part.material),g.composition_signature},"|")
	end
	return table.concat(parts,"\n")
end
-- Negative support proof over EVERY triangle, not a set of sampled misses.
-- upper(bounds) must bound all terrain inside the XY rectangle (including
-- interpolation neighbours). Longest-edge subdivision tightens the independent
-- terrain/mesh intervals; exhausting the bounded work budget remains unknown.
-- A bounded, exhaustive integer-coordinate height query for a small rectangle.
-- This is not a sparse miss test: every native terrain coordinate in the padded
-- footprint is included. Large rectangles retain the conservative grid bound
-- and are subdivided by TrianglesAboveTerrain. The caller owns any height cache
-- for its single immutable-terrain transaction.
function Geometry.IntegerTerrainUpper(bounds,height_at,width,height,padding,budget)
	local x0,y0=math.max(0,math.floor(bounds[1]-padding)),math.max(0,math.floor(bounds[2]-padding))
	local x1,y1=math.min(width-1,math.ceil(bounds[4]+padding)),math.min(height-1,math.ceil(bounds[5]+padding))
	if x1<x0 or y1<y0 or (x1-x0+1)*(y1-y0+1)>budget then return nil end
	local high=-math.huge
	for x=x0,x1 do for y=y0,y1 do
		local z=height_at(x,y)
		if type(z)~="number" or z~=z or z==math.huge or z==-math.huge then return nil end
		if z>high then high=z end
	end end
	-- Retain a separate vertical budget for the native integral height result.
	return high+2
end

-- Same exhaustive integer footprint as IntegerTerrainUpper, with lazy aligned
-- 4x4/4x1/1x4 maxima. Only fully covered blocks are read, so this never samples
-- outside the requested rectangle or substitutes an interpolation assumption.
-- The caller must discard this closure before any terrain mutation.
function Geometry.CachedIntegerTerrainUpper(height_at,width,height)
	local pixels,rows,columns,blocks={},{},{},{}
	local floor,ceil,max,min=math.floor,math.ceil,math.max,math.min
	local function pixel(x,y)
		local key=x+y*width;local z=pixels[key]
		if z==nil then
			z=height_at(x,y)
			if type(z)~="number" or z~=z or z==math.huge or z==-math.huge then z=false end
			pixels[key]=z
		end
		return z
	end
	local function row(x,y)
		local key=x+y*width;local z=rows[key]
		if z==nil then
			local a,b,c,d=pixel(x,y),pixel(x+1,y),pixel(x+2,y),pixel(x+3,y)
			z=a and b and c and d and max(a,b,c,d) or false;rows[key]=z
		end
		return z
	end
	local function column(x,y)
		local key=x+y*width;local z=columns[key]
		if z==nil then
			local a,b,c,d=pixel(x,y),pixel(x,y+1),pixel(x,y+2),pixel(x,y+3)
			z=a and b and c and d and max(a,b,c,d) or false;columns[key]=z
		end
		return z
	end
	local function block(x,y)
		local key=x+y*width;local z=blocks[key]
		if z==nil then
			local a,b,c,d=row(x,y),row(x,y+1),row(x,y+2),row(x,y+3)
			z=a and b and c and d and max(a,b,c,d) or false;blocks[key]=z
		end
		return z
	end
	return function(bounds,padding,budget)
		local x0,y0=max(0,floor(bounds[1]-padding)),max(0,floor(bounds[2]-padding))
		local x1,y1=min(width-1,ceil(bounds[4]+padding)),min(height-1,ceil(bounds[5]+padding))
		if x1<x0 or y1<y0 or (x1-x0+1)*(y1-y0+1)>budget then return nil end
		local high=-math.huge;local y=y0
		while y<=y1 do
			local tall=y%4==0 and y+3<=y1;local x=x0
			while x<=x1 do
				local wide=x%4==0 and x+3<=x1
				local z
				if tall then
					if wide then z=block(x,y) else z=column(x,y) end
				else
					if wide then z=row(x,y) else z=pixel(x,y) end
				end
				if z==false then return nil end
				if z>high then high=z end
				x=x+(wide and 4 or 1)
			end
			y=y+(tall and 4 or 1)
		end
		return high+2
	end
end

-- Exact piecewise-planar heightfield bound. The native terrain cell is split
-- along (0,0)--(tile,tile), not bilinearly interpolated (native l_GetHeight;
-- separately checked against 2000 native queries). Clip each mesh triangle to
-- both terrain faces. Their height difference is affine, so polygon vertices
-- contain its extrema. Expand every clipping half-plane by the XY transform
-- uncertainty and subtract the corresponding slope/Z error, rather than losing
-- XY/Z correlation to independent rectangle extrema.
function Geometry.TrianglesAboveHeightfield(triangles,height,tile,width,height_limit,error_bound,budget,extrema)
	if #triangles==0 or not Finite(tile) or tile<=0 or not Finite(error_bound) or error_bound<0
		or not Finite(width) or not Finite(height_limit) or width<=0 or height_limit<=0 then return false end
	local remaining=budget or 4096
	local minimum,maximum=math.huge,-math.huge
	local function clip(poly,a,b)
		local dx,dy=b[1]-a[1],b[2]-a[2]
		local padding=error_bound*(math.abs(dx)+math.abs(dy))
		local function side(p)return dx*(p[2]-a[2])-dy*(p[1]-a[1])+padding end
		local out={};local previous=poly[#poly]
		if not previous then return out end
		local before=side(previous)
		for _,current in ipairs(poly) do
			local after=side(current)
			if (before>=0)~=(after>=0) then
				local t=before/(before-after)
				out[#out+1]={previous[1]+t*(current[1]-previous[1]),previous[2]+t*(current[2]-previous[2]),previous[3]+t*(current[3]-previous[3])}
			end
			if after>=0 then out[#out+1]=current end
			previous,before=current,after
		end
		return out
	end
	for _,triangle in ipairs(triangles) do
		if #triangle~=3 then return false end
		local bounds=Bounds()
		for _,p in ipairs(triangle) do
			for a=1,3 do if not Finite(p[a]) then return false end end
			Extend(bounds,p)
		end
		local x0=math.floor((bounds[1]-error_bound)/tile)*tile
		local y0=math.floor((bounds[2]-error_bound)/tile)*tile
		local x1=math.floor((bounds[4]+error_bound)/tile)*tile
		local y1=math.floor((bounds[5]+error_bound)/tile)*tile
		if x0<0 or y0<0 or x1+tile>=width or y1+tile>=height_limit then return false end
		for x=x0,x1,tile do for y=y0,y1,tile do
			remaining=remaining-1;if remaining<0 then return false end
			local h00,h10,h01,h11=height(x,y),height(x+tile,y),height(x,y+tile),height(x+tile,y+tile)
			if not Finite(h00) or not Finite(h10) or not Finite(h01) or not Finite(h11) then return false end
			local corners={{x,y},{x+tile,y},{x+tile,y+tile},{x,y+tile}}
			for half=1,2 do
				local face=half==1 and {corners[1],corners[2],corners[3]} or {corners[1],corners[3],corners[4]}
				local poly=triangle
				for i=1,3 do poly=clip(poly,face[i],face[i%3+1]) end
				local gx,gy
				if half==1 then gx,gy=(h10-h00)/tile,(h11-h10)/tile
				else gx,gy=(h11-h01)/tile,(h01-h00)/tile end
				local margin=error_bound*(1+math.abs(gx)+math.abs(gy))
				local roundoff=1e-7*math.max(1,math.abs(h00),math.abs(h10),math.abs(h01),math.abs(h11))
				for _,p in ipairs(poly) do
					local clearance=p[3]-(h00+gx*(p[1]-x)+gy*(p[2]-y))
					if extrema then
						minimum=math.min(minimum,clearance);maximum=math.max(maximum,clearance)
					elseif clearance<=margin+roundoff then return false end
				end
			end
		end end
	end
	if extrema then return minimum>0,minimum,maximum end
	return true
end

function Geometry.TrianglesAboveTerrain(triangles,upper,margin,budget)
	if #triangles==0 or type(margin)~="number" or margin<0 then return false end
	local remaining=budget or 4096
	local function length(a,b)
		return (a[1]-b[1])^2+(a[2]-b[2])^2+(a[3]-b[3])^2
	end
	local function above(a,b,c,depth)
		remaining=remaining-1;if remaining<0 then return false end
		local bounds={math.min(a[1],b[1],c[1]),math.min(a[2],b[2],c[2]),math.min(a[3],b[3],c[3]),
			math.max(a[1],b[1],c[1]),math.max(a[2],b[2],c[2]),math.max(a[3],b[3],c[3])}
		local high=upper(bounds)
		if type(high)~="number" or high~=high or high==math.huge or high==-math.huge then return false end
		if bounds[3]>high+margin then return true end
		if depth==0 then return false end
		local ab,bc,ca=length(a,b),length(b,c),length(c,a)
		if bc>ab and bc>ca then a,b,c=b,c,a elseif ca>ab then a,b,c=c,a,b end
		local m={(a[1]+b[1])*.5,(a[2]+b[2])*.5,(a[3]+b[3])*.5}
		return above(a,m,c,depth-1) and above(m,b,c,depth-1)
	end
	for _,t in ipairs(triangles) do if not above(t[1],t[2],t[3],12) then return false end end
	return true
end

-- A fragment embedded completely inside a solid rock has no surface/surface
-- intersection. Only a closed, consistently oriented two-manifold may supply
-- that additional witness; open meshes and ambiguous rays cannot pass here.
-- A separating projection proves a point is outside every possible solid
-- bounded by this mesh, including an open mesh whose volume is unspecified.
-- Face normals are candidate axes only; EVERY vertex must lie on the opposite
-- side. Failure finds no answer and never grants contact or containment.
local function HullInteriorWitness(geometry,component,p,epsilon)
	local vertices=geometry.vertices
	local cache=component.interior_tetrahedra
	if not cache or cache.geometry~=geometry or cache.vertices~=vertices
		or cache.indices~=component.vertices or cache.count~=#component.vertices
		or cache.triangles~=component.triangles or cache.faces~=#component.triangles then
		local first=vertices[component.vertices[1]];if not first then return false end
		local x,y,z=0,0,0;local members={}
		for _,vi in ipairs(component.vertices)do
			local v=vertices[vi];members[vi]=true
			x=x+v[1]-first[1];y=y+v[2]-first[2];z=z+v[3]-first[3]
		end
		local count=#component.vertices+0.0
		cache={geometry=geometry,vertices=vertices,indices=component.vertices,count=#component.vertices,
			triangles=component.triangles,faces=#component.triangles,members=members,
			center={first[1]+x/count,first[2]+y/count,first[3]+z/count},items={}}
		component.interior_tetrahedra=cache
	end
	local center=cache.center;local px,py,pz=p[1]-center[1],p[2]-center[2],p[3]-center[3]
	local function contains(t)
		if not t or p[1]<t[10] or p[2]<t[11] or p[3]<t[12]
			or p[1]>t[13] or p[2]>t[14] or p[3]>t[15] then return false end
		local u=t[1]*px+t[2]*py+t[3]*pz
		local v=t[4]*px+t[5]*py+t[6]*pz
		local w=t[7]*px+t[8]*py+t[9]*pz
		return u>t[16] and v>t[17] and w>t[18] and u+v+w<1-t[19]
	end
	if contains(cache.hint) then return true end
	for i,face in ipairs(component.triangles)do
		local t=cache.items[i]
		if t==nil then
			t=false
			if cache.members[face[1]] and cache.members[face[2]] and cache.members[face[3]] then
				local a,b,c=vertices[face[1]],vertices[face[2]],vertices[face[3]]
				local ax,ay,az=a[1]-center[1],a[2]-center[2],a[3]-center[3]
				local bx,by,bz=b[1]-center[1],b[2]-center[2],b[3]-center[3]
				local cx,cy,cz=c[1]-center[1],c[2]-center[2],c[3]-center[3]
				local ux,uy,uz=by*cz-bz*cy,bz*cx-bx*cz,bx*cy-by*cx
				local det=ax*ux+ay*uy+az*uz
				local extent=math.max(math.abs(ax),math.abs(ay),math.abs(az),math.abs(bx),math.abs(by),math.abs(bz),math.abs(cx),math.abs(cy),math.abs(cz))
				if math.abs(det)>1e-12*extent*extent*extent then
					local vx,vy,vz=(cy*az-cz*ay)/det,(cz*ax-cx*az)/det,(cx*ay-cy*ax)/det
					local wx,wy,wz=(ay*bz-az*by)/det,(az*bx-ax*bz)/det,(ax*by-ay*bx)/det
					ux,uy,uz=ux/det,uy/det,uz/det
					local e=epsilon*8
					t={ux,uy,uz,vx,vy,vz,wx,wy,wz,
						math.min(center[1],a[1],b[1],c[1]),math.min(center[2],a[2],b[2],c[2]),math.min(center[3],a[3],b[3],c[3]),
						math.max(center[1],a[1],b[1],c[1]),math.max(center[2],a[2],b[2],c[2]),math.max(center[3],a[3],b[3],c[3]),
						e*(math.abs(ux)+math.abs(uy)+math.abs(uz)),e*(math.abs(vx)+math.abs(vy)+math.abs(vz)),
						e*(math.abs(wx)+math.abs(wy)+math.abs(wz)),e*(math.abs(ux+vx+wx)+math.abs(uy+vy+wy)+math.abs(uz+vz+wz))}
				end
			end
			cache.items[i]=t
		end
		if contains(t) then cache.hint=t;return true end
	end
	return false
end
function Geometry.PointOutsideComponentHull(geometry,component,p)
	local vertices=geometry.vertices
	local epsilon=1e-8
	for a=1,6 do epsilon=math.max(epsilon,1e-8*math.abs(component.bounds[a])) end
	-- A complete all-vertex separating plane is a reusable geometric witness,
	-- not a cached answer for a different point. Re-evaluate its half-space at
	-- every query; interior/ambiguous points still take the full original path.
	local planes=component.outside_planes
	if planes and (planes.geometry~=geometry or planes.vertices~=vertices
		or planes.indices~=component.vertices or planes.count~=#component.vertices) then planes=nil end
	for _,plane in ipairs(planes or {}) do
		local distance=plane[1]*(p[1]-plane[4])+plane[2]*(p[2]-plane[5])+plane[3]*(p[3]-plane[6])
		if distance>plane[7]+4*epsilon then return true end
	end
	-- The mean of the mesh vertices is in their convex hull. Any tetrahedron
	-- formed from that mean and three actual vertices is a subset of the hull.
	-- Strict interior barycentrics therefore prove that no separating axis can
	-- exist, avoiding repeated full scans for the same open-cliff interior.
	-- This is NOT a solid-volume/contact witness: open meshes still return nil
	-- from PointInClosedComponent, and all surface-triangle checks remain intact.
	if HullInteriorWitness(geometry,component,p,epsilon) then return false end
	local function remember(dx,dy,dz)
		local norm=math.sqrt(dx*dx+dy*dy+dz*dz)
		if norm<=0 or norm>=math.huge then return end
		dx,dy,dz=dx/norm,dy/norm,dz/norm
		local anchor=vertices[component.vertices[1]];local high=-math.huge
		for _,vi in ipairs(component.vertices) do
			local v=vertices[vi]
			high=math.max(high,dx*(v[1]-anchor[1])+dy*(v[2]-anchor[2])+dz*(v[3]-anchor[3]))
		end
		planes=planes or {geometry=geometry,vertices=vertices,indices=component.vertices,count=#component.vertices};component.outside_planes=planes
		table.insert(planes,1,{dx,dy,dz,anchor[1],anchor[2],anchor[3],high})
		if #planes>64 then table.remove(planes) end
	end
	-- Gilbert's closest-convex-point iteration proposes additional separating
	-- directions, including hull faces absent from an open/concave mesh. Only
	-- the complete all-vertex projection is a verdict; non-convergence is unknown.
	local first=vertices[component.vertices[1]]
	local qx,qy,qz=first[1],first[2],first[3]
	for iteration=1,64 do
		local dx,dy,dz=p[1]-qx,p[2]-qy,p[3]-qz
		local length=math.sqrt(dx*dx+dy*dy+dz*dz)
		if length<=epsilon then break end
		local support,best=nil,-math.huge
		for _,vi in ipairs(component.vertices) do
			local v=vertices[vi];local projection=dx*(v[1]-p[1])+dy*(v[2]-p[2])+dz*(v[3]-p[3])
			if projection>best then best=projection;support=v end
		end
		if best < -epsilon*length then remember(dx,dy,dz);return true end
		local sx,sy,sz=support[1]-qx,support[2]-qy,support[3]-qz
		local squared=sx*sx+sy*sy+sz*sz
		if squared<=epsilon*epsilon then break end
		local t=math.max(0,math.min(1,(dx*sx+dy*sy+dz*sz)/squared))
		if t<=1e-12 then break end
		qx,qy,qz=qx+t*sx,qy+t*sy,qz+t*sz
	end
	for _,t in ipairs(component.triangles) do
		local a,b,c=vertices[t[1]],vertices[t[2]],vertices[t[3]]
		local ux,uy,uz=b[1]-a[1],b[2]-a[2],b[3]-a[3]
		local vx,vy,vz=c[1]-a[1],c[2]-a[2],c[3]-a[3]
		local nx,ny,nz=uy*vz-uz*vy,uz*vx-ux*vz,ux*vy-uy*vx
		local norm=math.sqrt(nx*nx+ny*ny+nz*nz)
		if norm>1e-12 then
			local distance=nx*(p[1]-a[1])+ny*(p[2]-a[2])+nz*(p[3]-a[3])
			local margin=epsilon*norm
			if math.abs(distance)>margin then
				local sign=distance>0 and 1 or -1
				local limit=sign*distance-margin;local separated=true
				for _,vi in ipairs(component.vertices) do
					local v=vertices[vi]
					if sign*(nx*(v[1]-a[1])+ny*(v[2]-a[2])+nz*(v[3]-a[3]))>=limit then separated=false;break end
				end
				if separated then remember(sign*nx,sign*ny,sign*nz);return true end
			end
		end
	end
	return false
end

-- Recognize an open foundation, not arbitrary holes/material seams. Its welded
-- boundary must be closed loops entirely within the bottom five percent of the
-- component. No entity names, source poses or scenario coordinates are used.
function Geometry.FoundationBoundary(geometry,component)
	if component.foundation_boundary~=nil then return component.foundation_boundary end
	component.foundation_boundary=false
	if geometry.animated or not component.bounds or not component.vertices or not component.triangles then return false end
	local b=component.bounds;local height=b[6]-b[3]
	if height<=0 then return false end
	local ids,canonical,edges={},{},{}
	for _,i in ipairs(component.vertices) do
		local v=geometry.vertices[i];local key=string.format("%.12g,%.12g,%.12g",v[1],v[2],v[3])
		canonical[key]=canonical[key] or i;ids[i]=canonical[key]
	end
	for _,t in ipairs(component.triangles) do for j=1,3 do
		local a,b=ids[t[j]],ids[t[j%3+1]]
		local lo,hi=math.min(a,b),math.max(a,b);local key=lo..":"..hi
		local e=edges[key] or {a=lo,b=hi,count=0,balance=0};edges[key]=e
		e.count=e.count+1;e.balance=e.balance+(a<b and 1 or -1)
	end end
	local result={edges={},vertices={}};local degree={}
	for _,e in pairs(edges) do
		if e.count==1 then
			for _,i in ipairs({e.a,e.b}) do
				if geometry.vertices[i][3]>b[3]+height*.05 then return false end
				degree[i]=(degree[i] or 0)+1
			end
			result.edges[#result.edges+1]={e.a,e.b}
		elseif e.count~=2 or e.balance~=0 then return false end
	end
	if #result.edges<3 then return false end
	for i,n in pairs(degree) do if n~=2 then return false end;result.vertices[#result.vertices+1]=i end
	table.sort(result.vertices)
	table.sort(result.edges,function(a,b)return a[1]<b[1] or (a[1]==b[1] and a[2]<b[2])end)
	component.foundation_boundary=result
	return result
end

-- A terrain grid is piecewise planar. Along an edge the clearance is linear
-- between X/Y grid lines and cell diagonals; inspect all crossings, not a sparse
-- sample that can miss a valley midway along an otherwise buried bottom edge.
function Geometry.FoundationClearance(points,edges,height,tile,width,map_height,maximum_allowed)
	local maximum=-math.huge
	local cache,cells={},{}
	local function h(x,y)
		local column=cache[x];if not column then column={};cache[x]=column end
		local v=column[y]
		if v==nil then v=height(x,y);column[y]=v end
		return v
	end
	local function inspect(a,b,t)
		local x,y,z=a[1]+(b[1]-a[1])*t,a[2]+(b[2]-a[2])*t,a[3]+(b[3]-a[3])*t
		local gx,gy=math.floor(x/tile)*tile,math.floor(y/tile)*tile
		if gx<0 or gy<0 or gx+tile>=width or gy+tile>=map_height then return false end
		local column=cells[gx];if not column then column={};cells[gx]=column end
		local cell=column[gy]
		if not cell then
			local h00,h10,h01,h11=h(gx,gy),h(gx+tile,gy),h(gx,gy+tile),h(gx+tile,gy+tile)
			if not Finite(h00) or not Finite(h10) or not Finite(h01) or not Finite(h11) then return false end
			cell={h00,h10-h00,h11-h10,h11-h01,h01-h00};column[gy]=cell
		end
		local fx,fy=(x-gx)/tile,(y-gy)/tile
		local ground=fx>=fy and (cell[1]+cell[2]*fx+cell[3]*fy)
			or (cell[1]+cell[4]*fx+cell[5]*fy)
		local clearance=z-ground;if clearance>maximum then maximum=clearance end
		-- One exact crossing above the planner's visibility budget already
		-- disproves this candidate. Never truncate a potentially accepted proof.
		return not maximum_allowed or maximum<=maximum_allowed
	end
	for _,e in ipairs(edges) do
		local a,b=points[e[1]],points[e[2]]
		if not a or not b then return nil end
		for i=1,3 do if not Finite(a[i]) or not Finite(b[i]) then return nil end end
		if not inspect(a,b,0) or not inspect(a,b,1) then return nil end
		for axis=1,3 do
			local u=axis==3 and a[1]-a[2] or a[axis]
			local v=axis==3 and b[1]-b[2] or b[axis]
			if u~=v then
				local lo,hi=math.min(u,v),math.max(u,v)
				for line=(math.floor(lo/tile)+1)*tile,hi,tile do
					local t=(line-u)/(v-u)
					if t>0 and t<1 and not inspect(a,b,t) then return nil end
				end
			end
		end
	end
	return maximum>-math.huge and maximum or nil
end

-- Integer height-tile translations preserve every edge/grid/diagonal crossing.
-- Cache that immutable geometric stencil once per original foundation pose;
-- each proposal still queries the actual destination terrain at every crossing.
function Geometry.FoundationTranslationClearance(f,dx,dy,height,maximum_allowed)
	local tile=f.tile
	if dx%tile~=0 or dy%tile~=0 then
		local shifted={};for i,p in pairs(f.points) do shifted[i]={p[1]+dx,p[2]+dy,p[3]} end
		return Geometry.FoundationClearance(shifted,f.edges,height,tile,f.width,f.height,maximum_allowed)
	end
	local stencil=f.translation_stencil
	if not stencil then
		stencil={cells={},bounds={math.huge,math.huge,-math.huge,-math.huge}};local seen,cells={},{}
		local function emit(a,b,t)
			local x,y,z=a[1]+(b[1]-a[1])*t,a[2]+(b[2]-a[2])*t,a[3]+(b[3]-a[3])*t
			local xs=seen[x] or {};seen[x]=xs;local ys=xs[y] or {};xs[y]=ys
			if ys[z] then return end;ys[z]=true
			local gx,gy=math.floor(x/tile)*tile,math.floor(y/tile)*tile
			local p={gx,gy,z,(x-gx)/tile,(y-gy)/tile};stencil[#stencil+1]=p
			local col=cells[gx];if not col then col={};cells[gx]=col end
			local cell=col[gy]
			if not cell then cell={x=gx,y=gy};col[gy]=cell;stencil.cells[#stencil.cells+1]=cell end
			cell[#cell+1]=p
			local bounds=stencil.bounds
			if gx<bounds[1] then bounds[1]=gx end;if gy<bounds[2] then bounds[2]=gy end
			if gx>bounds[3] then bounds[3]=gx end;if gy>bounds[4] then bounds[4]=gy end
		end
		for _,e in ipairs(f.edges) do
			local a,b=f.points[e[1]],f.points[e[2]]
			if not a or not b then return nil end
			for i=1,3 do if not Finite(a[i]) or not Finite(b[i]) then return nil end end
			emit(a,b,0);emit(a,b,1)
			for axis=1,3 do
				local u=axis==3 and a[1]-a[2] or a[axis]
				local v=axis==3 and b[1]-b[2] or b[axis]
				if u~=v then
					for line=(math.floor(math.min(u,v)/tile)+1)*tile,math.max(u,v),tile do
						local t=(line-u)/(v-u);if t>0 and t<1 then emit(a,b,t) end
					end
				end
			end
		end
		f.translation_stencil=stencil
	end
	local maximum=-math.huge;local bounds=stencil.bounds
	if bounds[1]+dx<0 or bounds[2]+dy<0 or bounds[3]+dx+tile>=f.width or bounds[4]+dy+tile>=f.height then return nil end
	-- Group immutable crossings by terrain cell once, rather than rebuilding
	-- a destination cell table and looking it up for every crossing on every
	-- candidate. All crossings remain; only the traversal order changes.
	-- Nearby rejected proposals commonly expose the same rim section. Try its
	-- last exact rejection cell first; never reuse the old height or verdict.
	-- A potentially accepted proposal still traverses every cell and crossing.
	local first=stencil.reject_cell or 1
	for visit=1,#stencil.cells do
		local index=visit==1 and first or (visit<=first and visit-1 or visit)
		local cell=stencil.cells[index]
		local gx,gy=cell.x+dx,cell.y+dy
		local h00,h10,h01,h11=height(gx,gy),height(gx+tile,gy),height(gx,gy+tile),height(gx+tile,gy+tile)
		if not Finite(h00) or not Finite(h10) or not Finite(h01) or not Finite(h11) then return nil end
		local ax,ay,bx,by=h10-h00,h11-h10,h11-h01,h01-h00
		for _,p in ipairs(cell) do
			local fx,fy=p[4],p[5]
			local ground=fx>=fy and (h00+ax*fx+ay*fy) or (h00+bx*fx+by*fy)
			local clearance=p[3]-ground;if clearance>maximum then maximum=clearance end
			if maximum_allowed and maximum>maximum_allowed then stencil.reject_cell=index;return nil end
		end
	end
	return maximum>-math.huge and maximum or nil
end

-- Positive visibility witness against actual rendered triangles, including open
-- cliffs. A missing face below a formation must not be mistaken for a closed
-- convex volume. This says only that this ray is clear, never that a mesh floats
-- or that it can support another object. Near-edge hits remain obstructed.
function Geometry.ComponentRayClear(geometry,component,p,dir,maximum_distance)
	if geometry.animated or not component.triangles then return false end
	local function visit(tree)
		local low,high=0,maximum_distance or math.huge
		for a=1,3 do
			if math.abs(dir[a])<1e-12 then
				if p[a]<tree.bounds[a]-1e-7 or p[a]>tree.bounds[a+3]+1e-7 then return true end
			else
				local u,v=(tree.bounds[a]-p[a])/dir[a],(tree.bounds[a+3]-p[a])/dir[a]
				low=math.max(low,math.min(u,v));high=math.min(high,math.max(u,v))
			end
		end
		if low>high+1e-7 then return true end
		if not tree.items then return visit(tree.left) and visit(tree.right) end
		for _,item in ipairs(tree.items) do
			local t=item.triangle;local a,b,c=geometry.vertices[t[1]],geometry.vertices[t[2]],geometry.vertices[t[3]]
			local e={b[1]-a[1],b[2]-a[2],b[3]-a[3]};local f={c[1]-a[1],c[2]-a[2],c[3]-a[3]}
			local h={dir[2]*f[3]-dir[3]*f[2],dir[3]*f[1]-dir[1]*f[3],dir[1]*f[2]-dir[2]*f[1]}
			local det=e[1]*h[1]+e[2]*h[2]+e[3]*h[3]
			if math.abs(det)>1e-12 then
				local s={p[1]-a[1],p[2]-a[2],p[3]-a[3]}
				local u=(s[1]*h[1]+s[2]*h[2]+s[3]*h[3])/det
				local q={s[2]*e[3]-s[3]*e[2],s[3]*e[1]-s[1]*e[3],s[1]*e[2]-s[2]*e[1]}
				local v=(dir[1]*q[1]+dir[2]*q[2]+dir[3]*q[3])/det
				local distance=(f[1]*q[1]+f[2]*q[2]+f[3]*q[3])/det
				if u>=-1e-7 and v>=-1e-7 and u+v<=1+1e-7 and distance>=-1e-7
					and (not maximum_distance or distance<=maximum_distance+1e-7) then return false end
			else
				local nx,ny,nz=e[2]*f[3]-e[3]*f[2],e[3]*f[1]-e[1]*f[3],e[1]*f[2]-e[2]*f[1]
				local norm=math.sqrt(nx*nx+ny*ny+nz*nz)
				if norm<1e-12 or math.abs((p[1]-a[1])*nx+(p[2]-a[2])*ny+(p[3]-a[3])*nz)<=1e-7*norm then return false end
			end
		end
		return true
	end
	return visit(Geometry.TriangleTree(geometry,component))
end

function Geometry.PointInClosedComponent(geometry,component,p,above_open_base)
	-- Outside a complete component's bounds cannot be inside its volume, even
	-- when the authoring mesh is open. Only an inside result needs closure proof.
	local b=component.bounds
	for a=1,3 do if p[a]<b[a] or p[a]>b[a+3] then return false end end
	if component.closed==nil then
		local canonical,ids,edges={},{},{}
		for _,i in ipairs(component.vertices) do
			local v=geometry.vertices[i];local key=string.format("%.12g,%.12g,%.12g",v[1],v[2],v[3])
			canonical[key]=canonical[key] or i;ids[i]=canonical[key]
		end
		for _,t in ipairs(component.triangles) do for j=1,3 do
			local a,b=ids[t[j]],ids[t[j%3+1]]
			local lo,hi=math.min(a,b),math.max(a,b);local key=lo..":"..hi
			local edge=edges[key] or {count=0,balance=0};edges[key]=edge
			edge.count=edge.count+1;edge.balance=edge.balance+(a<b and 1 or -1)
		end end
		component.closed=true
		for _,e in pairs(edges) do if e.count~=2 or e.balance~=0 then component.closed=false;break end end
	end
	if not component.closed then
		local upper_body=false
		if above_open_base then
			local rim=Geometry.FoundationBoundary(geometry,component)
			if rim then
				local maximum=rim.maximum_z
				if not maximum then
					maximum=-math.huge
					for _,vi in ipairs(rim.vertices) do maximum=math.max(maximum,geometry.vertices[vi][3]) end
					rim.maximum_z=maximum
				end
				upper_body=maximum<p[3]-1e-7
			end
		end
		-- All rays below have positive local Z. If the only open loops lie
		-- strictly below the query, closing them anywhere below that plane
		-- cannot change parity. This proves the actual upper body, not an
		-- invented convex hull or the unspecified volume beneath an open base.
		if not upper_body then
			if Geometry.PointOutsideComponentHull(geometry,component,p) then return false end
			return nil
		end
	end
	for _,dir in ipairs({{1,0.371390676,0.529150263},{0.618033989,1,0.414213562},{0.732050808,0.271828183,1}}) do
		local count,ambiguous=0,false
		local function visit(tree)
			local low,high=0,math.huge
			for a=1,3 do
				low=math.max(low,(tree.bounds[a]-p[a])/dir[a]);high=math.min(high,(tree.bounds[a+3]-p[a])/dir[a])
			end
			if low>high then return end
			if not tree.items then visit(tree.left);visit(tree.right);return end
			for _,item in ipairs(tree.items) do
				local t=item.triangle;local a,c,d=geometry.vertices[t[1]],geometry.vertices[t[2]],geometry.vertices[t[3]]
				local e={c[1]-a[1],c[2]-a[2],c[3]-a[3]};local f={d[1]-a[1],d[2]-a[2],d[3]-a[3]}
				local h={dir[2]*f[3]-dir[3]*f[2],dir[3]*f[1]-dir[1]*f[3],dir[1]*f[2]-dir[2]*f[1]}
				local det=e[1]*h[1]+e[2]*h[2]+e[3]*h[3]
				if math.abs(det)>1e-12 then
					local s={p[1]-a[1],p[2]-a[2],p[3]-a[3]}
					local u=(s[1]*h[1]+s[2]*h[2]+s[3]*h[3])/det
					local q={s[2]*e[3]-s[3]*e[2],s[3]*e[1]-s[1]*e[3],s[1]*e[2]-s[2]*e[1]}
					local v=(dir[1]*q[1]+dir[2]*q[2]+dir[3]*q[3])/det
					local distance=(f[1]*q[1]+f[2]*q[2]+f[3]*q[3])/det
					if u>=-1e-9 and v>=-1e-9 and u+v<=1+1e-9 and distance>=-1e-9 then
						if u<1e-9 or v<1e-9 or 1-u-v<1e-9 or distance<1e-9 then ambiguous=true
						else count=count+1 end
					end
				end
			end
		end
		visit(Geometry.TriangleTree(geometry,component))
		if not ambiguous then return count%2==1 end
	end
	return nil
end

function Geometry.SegmentInsideRenderedBody(geometry,component,a,b,cache)
	if geometry.animated then return false end
	local bounds=component.bounds
	for axis=1,3 do
		if a[axis]<=bounds[axis] or a[axis]>=bounds[axis+3]
			or b[axis]<=bounds[axis] or b[axis]>=bounds[axis+3] then return false end
	end
	cache=cache or {}
	for _,p in ipairs({a,b}) do
		if cache[p]==nil then cache[p]=Geometry.PointInClosedComponent(geometry,component,p,true)==true end
		if not cache[p] then return false end
	end
	-- Two interior endpoints alone do not prove containment in a concave body:
	-- the COMPLETE joining segment must avoid every actual boundary triangle.
	return Geometry.ComponentRayClear(geometry,component,a,{b[1]-a[1],b[2]-a[2],b[3]-a[3]},1)
end
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
Geometry.ClearCache=function()mesh_cache={};material_cache={};entity_cache={};override_cache={};verified_poses={};decoded_poses={}end
SBM.DecorationGeometry=Geometry
