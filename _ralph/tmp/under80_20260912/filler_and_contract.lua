-- Mapless, scratch-only discovery of the valid two-grid native return contract.
local r={status='setup',calls={},issues={}}
rawset(_G,'SBM_FILLER_AND_CONTRACT',r)
local sbm
for _,mod in ipairs(ModsLoaded or {})do
 local s=mod.env and rawget(mod.env,'SuperBigMap');if s and s.Engine then sbm=s;break end
end
local function fail(why)r.issues[#r.issues+1]=tostring(why);r.status='fail' end
if not sbm then fail('mod missing');return end
local operation,create=sbm.Engine.Global('GridAnd'),sbm.Engine.Global('NewComputeGrid')
if type(operation)~='function' or type(create)~='function'then fail('native API missing');return end
local pack=function(...)return{n=select('#',...),...}end
local owned={}
local ok,why=pcall(function()
 local dst=create(4,2,'U',16);if not dst then fail('destination allocation');return end;owned[#owned+1]=dst
 local src=create(4,2,'U',16);if not src or src==dst then fail('source allocation');return end;owned[#owned+1]=src
 local patterns={{0,0},{1,0},{1,65535},{65535,65535},
  {{0,1,2,3,4,5,10,65535},{65535,2,1,2,3,4,7,0}},
  {{0,1,0,1,0,1,0,1},{0,65535,65535,0,0,65535,65535,0}}}
 for index,pattern in ipairs(patterns)do
  local inputs={}
  for i=1,8 do
   local a=type(pattern[1])=='table' and pattern[1][i] or pattern[1]
   local b=type(pattern[2])=='table' and pattern[2][i] or pattern[2]
   local x,y=(i-1)%4,math.floor((i-1)/4);dst:set(x,y,a);src:set(x,y,b);inputs[i]=b
  end
  local values=pack(operation(dst,src));local row={case=index,return_count=values.n,roles={},output={}}
  for i=1,values.n do
   local v=values[i]
   if rawequal(v,dst)then row.roles[i]='destination'
   elseif rawequal(v,src)then row.roles[i]='source'
   elseif v==nil then row.roles[i]='nil'
   elseif type(v)=='number' or type(v)=='boolean' or type(v)=='string'then row.roles[i]=type(v)..':'..tostring(v)
   else fail('unknown return role');row.roles[i]=type(v)end
  end
  for i=1,8 do
   local x,y=(i-1)%4,math.floor((i-1)/4)
   if src:get(x,y)~=inputs[i]then fail('source mutated')end
   row.output[i]=dst:get(x,y)
  end
  r.calls[#r.calls+1]=row
 end
end)
if not ok then fail(why)end
for i=#owned,1,-1 do local good,err=pcall(owned[i].free,owned[i]);if not good then fail(err)end end
r.scratch_released=#r.issues==0;r.status=#r.issues==0 and 'pass' or 'fail'
return 'FILLER_AND_CONTRACT_'..r.status
