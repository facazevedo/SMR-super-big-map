-- Compare all decoded values/topology/witnesses to the pre-optimization decoder.
local function module(source)
 local env=setmetatable({SuperBigMap={Engine={Global=function()end}}},{__index=_G});env._G=env
 assert(load(source,'mesh decoder oracle','t',env))()
 return env.SuperBigMap.DecorationGeometry.Decode
end
local p=assert(io.popen('git show d753556:Code/sbm_decoration_geometry.lua','r'))
local legacy=module(p:read('*a'));assert(p:close())
local f=assert(io.open('Code/sbm_decoration_geometry.lua','r'));local current=module(f:read('*a'));f:close()
local formats={fmt_sint16_c2=28,fmt_sint16_c1=26,fmt_uint8_c4=7,fmt_unorm8_c4=8}
local function same(a,b)
 if type(a)~=type(b) then return false end
 if type(a)~='table' then return a==b end
 for k,v in pairs(a) do if not same(v,b[k]) then return false end end
 for k in pairs(b) do if a[k]==nil then return false end end
 return true
end
math.randomseed(380)
for trial=1,300 do
 local bytes,indices={},{}
 local skinned=trial%3==0
 local stride=skinned and 14 or 6
 for i=1,180 do
  local q={math.random(-3,3)*10922,math.random(-3,3)*10922,math.random(-3,3)*10922}
  if i==1 then q={-32767,-32767,-32767} elseif i==2 then q={32767,32767,32767} end
  for _,v in ipairs(q) do local s=string.pack('<i2',v);bytes[#bytes+1]=s:byte(1);bytes[#bytes+1]=s:byte(2) end
  if skinned then
   bytes[#bytes+1]=math.floor((i-1)/30)%2
   for j=1,3 do bytes[#bytes+1]=0 end
   bytes[#bytes+1]=255;for j=1,3 do bytes[#bytes+1]=0 end
  end
 end
 for i=0,179,3 do indices[#indices+1]=i;indices[#indices+1]=i+1;indices[#indices+1]=i+2 end
 local attrs={{name='pos_xy',format=28,offset=0},{name='pos_z',format=26,offset=4}}
 if skinned then attrs[#attrs+1]={name='bone_indices_1',format=7,offset=6};attrs[#attrs+1]={name='bone_weights_1',format=8,offset=10} end
 local data={maxBonesPerVertex=skinned and 1 or 0,geom={vertices=bytes,indices=indices,numVertices=180,
  vertexLayout={streams={{stride=stride}},attributes=attrs}}}
 -- Large offsets exercise the old decimal-key path when numeric uniqueness
 -- cannot be certified; ordinary packed meshes exercise exact 48-bit keys.
 local offset=trial%5==0 and 1e12 or trial*13
 local bounds={offset-3,-3,-3,offset+3,3,3}
 local a,ae=legacy(data,bounds,formats);local b,be=current(data,bounds,formats)
 assert(same(a,b) and ae==be,'full mesh decoder mismatch at trial '..trial)
 assert(a,'fixture failed to exercise successful decoding')
end
print('PASS 300 packed/skinned/large-offset meshes: all decoded topology, bounds and witness values match d753556')
