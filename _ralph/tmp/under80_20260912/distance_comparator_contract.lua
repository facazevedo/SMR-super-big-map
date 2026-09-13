-- Mapless diagnosis of the private comparator, independent scalar oracle.
local r={status='setup',cases={},issues={},allocated=0,freed=0}
rawset(_G,'SBM_DISTANCE_COMPARATOR_CONTRACT',r)
local sbm
for _,mod in ipairs(ModsLoaded or {})do local s=mod.env and rawget(mod.env,'SuperBigMap');if s and s.Engine then sbm=s;break end end
local owned={}
local function own(g)if not g or owned[g]then error('invalid allocation');return end;owned[g]=true;r.allocated=r.allocated+1;return g end
local function cleanup()for g in pairs(owned)do local ok,why=pcall(g.free,g);if ok then owned[g]=nil;r.freed=r.freed+1 else r.issues[#r.issues+1]=tostring(why)end end end
local ok,why=pcall(function()
 if not sbm then error('missing mod');return end
 local api={}
 for _,name in ipairs({'NewComputeGrid','GridRepack','GridAddMulDiv','GridAbs','GridCount','GridMinMax'})do
  api[name]=sbm.Engine.Global(name);if type(api[name])~='function'then error('missing '..name);return end
 end
 local definitions={{0,0,32},{0,1,32},{1,0,32},{1,2,32},{2,1,32},{0,65535,32},{65535,0,32},{0,1,768}}
 for _,d in ipairs(definitions)do
  local av,bv,w=table.unpack(d)
  local a=own(api.NewComputeGrid(w,w,'U',16));local b=own(api.NewComputeGrid(w,w,'U',16))
  for y=0,w-1 do for x=0,w-1 do a:set(x,y,0);b:set(x,y,0)end end
  a:set(0,0,av);b:set(0,0,bv)
  local delta=own(api.GridRepack(a,'f',32,true));local expected=own(api.GridRepack(b,'f',32,true))
  local row={a=av,b=bv,width=w,repacked_a=delta:get(0,0),repacked_b=expected:get(0,0)}
  api.GridAddMulDiv(delta,expected,-1);row.subtracted=delta:get(0,0)
  api.GridAbs(delta);row.absolute=delta:get(0,0)
  row.count_from_one=api.GridCount(delta,1,2147483647)
  row.count_from_zero=api.GridCount(delta,0,2147483647)
  row.count_zero_only=api.GridCount(delta,0,0)
  row.count_one_only=api.GridCount(delta,1,1)
  row.scalar_mismatches=0;row.scalar_nonzero_delta=0;row.scalar_bad_delta=0
  for y=0,w-1 do for x=0,w-1 do
   local aa,bb=a:get(x,y),b:get(x,y);local dd=delta:get(x,y)
   if aa~=bb then row.scalar_mismatches=row.scalar_mismatches+1 end
   if dd~=0 then row.scalar_nonzero_delta=row.scalar_nonzero_delta+1 end
   if dd~=math.abs(aa-bb)then row.scalar_bad_delta=row.scalar_bad_delta+1 end
  end end
  r.cases[#r.cases+1]=row;cleanup()
 end
end)
if not ok then r.issues[#r.issues+1]=tostring(why)end
cleanup();r.scratch_released=next(owned)==nil and r.allocated==r.freed
r.status=#r.issues==0 and r.scratch_released and 'pass' or 'fail'
return 'DISTANCE_COMPARATOR_CONTRACT_'..r.status
