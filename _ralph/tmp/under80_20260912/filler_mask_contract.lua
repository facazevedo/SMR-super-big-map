-- Mapless scratch-only native API contract; no RNG or game map access.
local r={status='setup',calls={},issues={}}
rawset(_G,'SBM_FILLER_MASK_CONTRACT',r)
local sbm
for _,mod in ipairs(ModsLoaded or {})do
 local value=mod.env and rawget(mod.env,'SuperBigMap')
 if value and value.Engine then sbm=value;break end
end
local function fail(why)r.issues[#r.issues+1]=tostring(why);r.status='fail' end
if not sbm then fail('mod unavailable');return end
local mask=sbm.Engine.Global('GridMask')
local create=sbm.Engine.Global('NewComputeGrid')
if type(mask)~='function' or type(create)~='function'then fail('native API unavailable');return end
local pack=function(...)return {n=select('#',...),...}end
local math_api=sbm.Engine.Global('math')
r.math_type_available=type(math_api)=='table' and type(math_api.type)=='function'
if r.math_type_available then
 r.integer_subtype=math_api.type(3);r.float_subtype=math_api.type(3.0)
end
local owned={}
local ok,why=pcall(function()
 local src=create(4,2,'U',16);if not src then fail('source allocation');return end;owned[#owned+1]=src
 local dst=create(4,2,'U',16);if not dst or dst==src then fail('destination allocation');return end;owned[#owned+1]=dst
 local values={0,1,2,3,4,5,10,65535}
 for i,v in ipairs(values)do src:set((i-1)%4,math.floor((i-1)/4),v)end
 for _,params in ipairs({{3,2147483647,1},{4,2147483647,1},{5,2147483647,1},
  {7,2147483647,1},{12,2147483647,1},{65536,2147483647,1}})do
  local tuple=pack(mask(src,dst,params[1],params[2],params[3]))
  local row={from=params[1],to=params[2],scale=params[3],return_count=tuple.n,roles={}}
  for i=1,tuple.n do
   local value=tuple[i]
   if value==src then row.roles[i]='source'
   elseif value==dst then row.roles[i]='destination'
   elseif value==nil then row.roles[i]='nil'
   elseif type(value)=='number' or type(value)=='string' or type(value)=='boolean'then
    row.roles[i]=type(value)..':'..tostring(value)
   else row.roles[i]=type(value);fail('unclassified native return')end
  end
  if tuple.n~=1 or tuple[1]~=dst then fail('supported native mask return is not exactly destination')end
  for i,v in ipairs(values)do if src:get((i-1)%4,math.floor((i-1)/4))~=v then fail('source mutated')end end
  r.calls[#r.calls+1]=row
 end
end)
if not ok then fail(why)end
for i=#owned,1,-1 do local freed,err=pcall(owned[i].free,owned[i]);if not freed then fail(err)end end
r.scratch_released=#r.issues==0
r.status=#r.issues==0 and 'pass' or 'fail'
return 'FILLER_MASK_NATIVE_CONTRACT_'..r.status
