-- Candidate for supported production embedding. No private runtime APIs.
return function(generator,class,read,write)
 local stats={installed=false,restored=false,scopes=0,primary=0,secondary=0,
  native_primary=0,native_secondary=0,cached_primary=0,cached_secondary=0,
  unions=0,writes=0,transforms=0,minimums=0,copies=0,guards=0,
  allocated=0,freed=0,live=0,peak=0,invalidations=0}
 local originals,wrappers,owned={},{},{};local scope
 local saved_start,saved_end,start_wrapper,end_wrapper
 local pack=function(...)return {n=select('#',...),...}end
 local unpack_values=table.unpack or unpack
 local function fail(why)stats.failure=stats.failure or tostring(why);return false end
 local function thread()return coroutine.running() or 'main'end
 local function here()return scope and not scope.disabled and scope.thread==thread()end
 local function number(v)return type(v)=='number' and v==v and v>-math.huge and v<math.huge end
 local function integer(v)return number(v) and math.type(v)=='integer'end
 local function release(g)
  if not owned[g]then return fail('unowned distance scratch')end
  local ok,why=pcall(g.free,g);if not ok then return fail('distance free: '..tostring(why))end
  owned[g]=nil;stats.live=stats.live-1;stats.freed=stats.freed+1;return true
 end
 local function own(g,caller)
  if (type(g)~='table' and type(g)~='userdata') or owned[g] or g==caller
   or (scope and (g==scope.place or g==scope.bounds or g==scope.primary or g==scope.dest))then
   fail('invalid/aliased distance scratch');return nil
  end
  owned[g]=true;stats.allocated=stats.allocated+1;stats.live=stats.live+1
  stats.peak=math.max(stats.peak,stats.live);return g
 end
 local function valid(g,limit,w,h)
  if originals.IsComputeGrid(g)~='U'then return false end
  local x,y=g:size();if not integer(x) or not integer(y) or x<=0 or y<=0 or (w and (x~=w or y~=h))then return false end
  local lo,hi=originals.GridMinMax(g)
  return number(lo) and number(hi) and lo>=0 and hi<=limit and lo%1==0 and hi%1==0,x,y
 end
 local function compare(a,b)
  if not valid(a,16777216,scope.width,scope.height) or not valid(b,16777216,scope.width,scope.height)then return fail('distance guard range')end
  local delta=own(originals.GridRepack(a,'f',32,true),a);if not delta then return false end
  local expected=own(originals.GridRepack(b,'f',32,true),b);if not expected then return false end
  originals.GridAddMulDiv(delta,expected,-1);originals.GridAbs(delta)
  -- Native count excludes its lower bound: include every nonzero integer delta.
  local same=originals.GridCount(delta,0,2147483647)==0
  release(expected);release(delta);stats.guards=stats.guards+1
  if not same then return fail('distance input changed outside admitted writes')end
  return true
 end
 local function clear()
  if scope and scope.ready then
   local ok,why=pcall(function()
    if not scope.place_freed then compare(scope.place,scope.place_guard)end
    if not scope.bounds_freed then compare(scope.bounds,scope.bounds_guard)end
   end)
   if not ok then fail('distance guards: '..tostring(why))end
  end
  for g in pairs(owned)do release(g)end
  if scope then scope.ready=false;scope.disabled=true;scope.dest=nil;scope.dest_source=nil;scope.pending=nil end
 end
 local function disable()
  if scope and not scope.disabled then stats.invalidations=stats.invalidations+1;clear()end
 end
 local function guarded(fn,...)
  local out=pack(pcall(fn,...))
  if not out[1]then fail('distance private operation: '..tostring(out[2]));clear();return false end
  if stats.failure then clear();return false end
  return true,unpack_values(out,2,out.n)
 end
 local function touches(...)
  if not scope or not scope.ready then return false end
  for i=1,select('#',...)do local g=select(i,...)
   if g==scope.place or g==scope.bounds or owned[g]then return true end
  end
  return false
 end
 local function setup(place,dest,bounds)
  local good,w,h=valid(place,1)
  if not good or w*h*6*4>16777216 or not valid(bounds,1,w,h) or not valid(dest,1,w,h)then disable();return false end
  scope.place,scope.bounds,scope.primary=place,bounds,dest;scope.width,scope.height=w,h
  scope.place_guard=own(place:clone(),place);scope.bounds_guard=own(bounds:clone(),bounds)
  scope.distance_place=own(originals.GridDest(place),place);scope.distance_bounds=own(originals.GridDest(bounds),bounds)
  if not scope.place_guard or not scope.bounds_guard or not scope.distance_place or not scope.distance_bounds then return false end
  scope.ready=true;scope.dirty=true
  originals.GridDistanceMars(scope.bounds_guard,scope.distance_bounds,1,1);stats.transforms=stats.transforms+1
  return true
 end
 local function union_after(place,dest,bounds)
  if not scope.ready and not setup(place,dest,bounds)then return end
  scope.pending=dest;scope.primary=dest;stats.unions=stats.unions+1
 end
 local function primary(dest,calibrate)
  originals.GridDistanceMars(scope.place_guard,scope.distance_place,1,1);stats.transforms=stats.transforms+1
  if not calibrate then
   originals.GridMin(scope.distance_place,dest,scope.distance_bounds)
   stats.minimums=stats.minimums+1;stats.cached_primary=stats.cached_primary+1
  end
  scope.pending=nil;scope.dirty=false;stats.primary=stats.primary+1
  return dest
 end
 local function secondary(dest)
  dest:copy(scope.distance_place);stats.copies=stats.copies+1;stats.cached_secondary=stats.cached_secondary+1
  stats.secondary=stats.secondary+1;return dest
 end
 local function close()
  if scope then fail('unfinished Playable procedure');clear();scope=nil end
  for g in pairs(owned)do release(g)end
  local restore_good=true
  for name,wrapper in pairs(wrappers)do
   local ok,current=pcall(read,name)
   if ok and current==wrapper then
    local wrote,good=pcall(write,name,originals[name])
    local checked,value=pcall(read,name)
    if not wrote or not good or not checked or value~=originals[name]then restore_good=false;fail('distance global restore '..name)end
   elseif not ok or current~=originals[name]then restore_good=false;fail('distance global rebound '..name)end
  end
  if start_wrapper then
   if class.ProcStart==start_wrapper then class.ProcStart=saved_start
   elseif class.ProcStart~=saved_start then restore_good=false;fail('distance ProcStart rebound')end
   if class.ProcEnd==end_wrapper then class.ProcEnd=saved_end
   elseif class.ProcEnd~=saved_end then restore_good=false;fail('distance ProcEnd rebound')end
  end
  stats.restored=restore_good and stats.live==0
  return stats.failure==nil,stats.failure
 end
 local function install()
  if type(class)~='table' or type(read)~='function' or type(write)~='function' or type(math.type)~='function'then return end
  saved_start,saved_end=class.ProcStart,class.ProcEnd
  if type(saved_start)~='function' or type(saved_end)~='function'then return end
  for _,name in ipairs({'GridDest','GridOr','GridDistanceMars','GridCircleSet','GridOpFree',
   'GridMin','GridRepack','GridAddMulDiv','GridAbs','GridCount','GridMinMax','IsComputeGrid',
   'GridAnd','GridNot','GridMask','GridFill','GridMulDivAdd','GridMulAddScaled'})do
   originals[name]=read(name);if type(originals[name])~='function'then return end
  end
  wrappers.GridDest=function(...)
   local out=pack(originals.GridDest(...))
   if here()then
    scope.dest_source,scope.dest=nil,nil
    if select('#',...)==1 and out.n==1 and out[1]~=select(1,...) and not owned[out[1]]then
     scope.dest_source=select(1,...);scope.dest=out[1]
    end
   end
   return unpack_values(out,1,out.n)
  end
  wrappers.GridOr=function(...)
   local place,dest,bounds=...
   local admitted=here() and select('#',...)==3 and place~=dest and place~=bounds and dest~=bounds
    and scope.dest_source==place and scope.dest==dest and not scope.pending
    and (not scope.ready or (place==scope.place and bounds==scope.bounds and not scope.primary))
   if scope and not scope.disabled and not admitted and (here() or touches(...))then disable()end
   local out=pack(originals.GridOr(...))
   if admitted then guarded(union_after,place,dest,bounds)end
   return unpack_values(out,1,out.n)
  end
  wrappers.GridDistanceMars=function(...)
   local src,dst,a,b=...
   if here() and scope.ready then
    if select('#',...)==3 and src==scope.pending and integer(dst) and dst==1 and integer(a) and a==1 and scope.dirty then
     if not scope.primary_contract then
      -- Keep real native exceptions outside the private fallback pcall: never retry them.
      local out=pack(originals.GridDistanceMars(...));stats.native_primary=stats.native_primary+1
      if out.n~=1 or out[1]~=src then disable();return unpack_values(out,1,out.n)end
      scope.primary_contract=true;guarded(primary,src,true)
      return unpack_values(out,1,out.n)
     end
     local out=pack(guarded(primary,src,false))
     if out[1]then return unpack_values(out,2,out.n)end
     -- Recover the original raw input before the authoritative fallback transform.
     originals.GridOr(scope.place,src,scope.bounds)
    elseif select('#',...)==4 and src==scope.place and dst==scope.dest and scope.dest_source==src
     and dst~=scope.bounds and dst~=scope.primary and integer(a) and a==1 and integer(b) and b==1
     and not scope.pending and not scope.dirty and scope.primary then
     scope.dest=nil;scope.dest_source=nil
     if not scope.secondary_contract then
      local out=pack(originals.GridDistanceMars(...));stats.native_secondary=stats.native_secondary+1
      if out.n~=1 or out[1]~=dst then disable();return unpack_values(out,1,out.n)end
      scope.secondary_contract=true;stats.secondary=stats.secondary+1
      return unpack_values(out,1,out.n)
     end
     local out=pack(guarded(secondary,dst));if out[1]then return unpack_values(out,2,out.n)end
    else disable()end
   elseif touches(...)then disable()end
   return originals.GridDistanceMars(...)
  end
  wrappers.GridCircleSet=function(...)
   local g,value,center,radius=...
   if here() and scope.ready and select('#',...)==4 and g==scope.place and integer(value) and value==1
    and center~=nil and number(radius) and radius>=0 and not scope.pending then
    local out=pack(originals.GridCircleSet(...))
    guarded(function()
     originals.GridCircleSet(scope.place_guard,value,center,radius);scope.dirty=true;stats.writes=stats.writes+1
    end)
    return unpack_values(out,1,out.n)
   end
   if touches(...)then disable()end
   return originals.GridCircleSet(...)
  end
  wrappers.GridOpFree=function(...)
   local g=...
   if scope and scope.ready then
    if select('#',...)~=1 or not here()then if touches(...)then disable()end
    elseif g==scope.place or g==scope.bounds then
     -- Stock frees bounds, then place, then primary before ProcEnd.
     clear()
    elseif g and g==scope.primary then scope.primary=nil;scope.pending=nil end
   end
   return originals.GridOpFree(...)
  end
  for _,name in ipairs({'GridAnd','GridNot','GridMask','GridFill','GridMulDivAdd','GridMulAddScaled',
   'GridMin','GridRepack','GridAddMulDiv','GridAbs'})do
   wrappers[name]=function(...)if touches(...)then disable()end;return originals[name](...)end
  end
  start_wrapper=function(self,tag,...)
   local out=pack(saved_start(self,tag,...))
   if self==generator and tag=='FindPrefabPos_Playable'then
    if scope then fail('nested Playable scope');clear()end
    scope={thread=thread()};stats.scopes=stats.scopes+1
   end
   return unpack_values(out,1,out.n)
  end
  end_wrapper=function(self,tag,...)
   if self==generator and tag=='FindPrefabPos_Playable'then
    if not scope or scope.thread~=thread()then fail('Playable scope endpoint')
    else clear();scope=nil end
   end
   return saved_end(self,tag,...)
  end
  class.ProcStart,class.ProcEnd=start_wrapper,end_wrapper
  for name,wrapper in pairs(wrappers)do
   if not write(name,wrapper) or read(name)~=wrapper then fail('distance install '..name);return end
  end
  stats.installed=true
 end
 local ok,why=pcall(install);if not ok then fail('distance install: '..tostring(why))end
 if stats.failure then close()end
 return close,stats
end
