-- Reuse the independent small-grid model, not the observer's output logic.
local function read(path)local f=assert(io.open(path,'r'));local s=f:read('*a');f:close();return s end
local source=read('_ralph/tmp/under80_20260912/playable_distance_observer_test.lua')
source=source:sub(1,assert(source:find("\nfor _,mode in ipairs({'normal'",1,true))-1)
local function replace(old,new)
 local a,b=source:find(old,1,true);assert(a,'model anchor '..old)
 assert(not source:find(old,b+1,true),'model duplicate anchor')
 source=source:sub(1,a-1)..new..source:sub(b+1)
end
replace("dst.v=values;return nil,'distance',nil,dst,nil", "dst.v=values;if mode=='native_tuple'then return nil,'distance',nil,dst,nil end;return dst")
replace("for i=1,16 do self.v[i]=src.v[i]+(mode=='bad_copy' and 1 or 0)end", "for i=1,16 do self.v[i]=src.v[i]end;if mode=='copy_error'then self.v[1]=999;error('copy sentinel')end")
replace('saved,function()return tick end','saved,function()return tick end,borrowed,live')
local tests=[[
local install=assert(loadfile('_ralph/tmp/under80_20260912/playable_distance_helper.lua'))()
local function distance(g)
 local result={}
 for y=0,3 do for x=0,3 do
  local d=65535
  for yy=0,3 do for xx=0,3 do if g.v[yy*4+xx+1]~=0 then d=math.min(d,math.abs(x-xx)+math.abs(y-yy))end end end
  result[y*4+x+1]=d
 end end
 return result
end
for _,mode in ipairs({'normal','last_write','native_tuple','native_error','private_error',
 'copy_error','clone_alias','repack_error','place_mutation','bounds_mutation',
 'unsupported_write','foreign_write','unfinished','rebound','install_false','missing_api'})do
 local obs,api,original,row,unused,oldclean,actual,place,bounds,grid,saved,ticks,borrowed,live=fixture(mode)
 for _,name in ipairs({'GridAnd','GridNot','GridMask','GridFill','GridMulDivAdd','GridMulAddScaled'})do
  api[name]=function(g)for i=1,16 do g.v[i]=0 end;return nil,'mutation',nil end
 end
 if mode=='missing_api'then api.GridAbs=nil end
 local originals={};for k,v in pairs(api)do originals[k]=v end
 local generator={};local class={ProcStart=function()return nil,'start',nil end,ProcEnd=function()return nil,'end',nil end}
 local start,finish=class.ProcStart,class.ProcEnd;local writes=0
 local close,stats=install(generator,class,function(k)return api[k]end,function(k,v)
  writes=writes+1;if mode=='install_false' and writes==3 then return false end
  api[k]=v;return true
 end)
 local function dest(g)local d=api.GridDest(g);borrowed[d]=true;return d end
 local function verify(g,expected,label)
  if mode~='place_mutation' and mode~='bounds_mutation'then for i,v in ipairs(expected)do check(g.v[i]==v,label..' '..mode)end end
 end
 local function ret(g,...)
  local values=table.pack(...)
  if mode=='native_tuple'then check(values.n==5 and values[2]=='distance' and values[4]==g,'native tuple forwarded')
  else check(values.n==1 and values[1]==g,'destination return contract')end
 end
 local function run()
  local values=table.pack(class.ProcStart(generator,'FindPrefabPos_Playable'))
  check(values.n==3 and values[2]=='start','start tuple')
  for epoch=1,3 do
   local primary=dest(place)
   local expected={};for i=1,16 do expected[i]=(place.v[i]~=0 or bounds.v[i]~=0)and 1 or 0 end
   api.GridOr(place,primary,bounds);verify(primary,expected,'raw union')
   local primary_expected=distance(primary)
   ret(primary,api.GridDistanceMars(primary,1,1));verify(primary,primary_expected,'primary field')
   if epoch==2 then
    if mode=='place_mutation'then place.v[16]=1 end
    if mode=='bounds_mutation'then bounds.v[16]=1 end
    if mode=='unsupported_write'then api.GridFill(place)end
    if mode=='foreign_write'then
     check(coroutine.resume(coroutine.create(function()api.GridCircleSet(place,1,{x=3,y=3},0)end)),'foreign original write')
    end
   end
   for j=1,2 do
    local secondary=dest(place);local expected_secondary=distance(place)
    ret(secondary,api.GridDistanceMars(place,secondary,1,1));verify(secondary,expected_secondary,'secondary field')
    secondary.v[1]=999;api.GridOpFree(secondary)
   end
   if epoch<3 or mode=='last_write'then api.GridCircleSet(place,1,{x=epoch,y=epoch},0)end
   if mode=='unfinished'then return end
   if epoch<3 then api.GridOpFree(primary)
   else api.GridOpFree(bounds);api.GridOpFree(place);api.GridOpFree(primary)end
  end
  values=table.pack(class.ProcEnd(generator,'FindPrefabPos_Playable'))
  check(values.n==3 and values[2]=='end','end tuple')
 end
 local ok,why=pcall(run)
 if mode=='native_error'then check(not ok and tostring(why):find('actual%-distance%-sentinel'),'original exception forwarded');check(actual()==1,'original error not retried')
 else check(ok,why)end
 local replacement=function()end
 if mode=='rebound'then api.GridOr=replacement end
 local good=close()
 local expected_fail=({native_error=true,private_error=true,copy_error=true,clone_alias=true,repack_error=true,
  place_mutation=true,bounds_mutation=true,unfinished=true,rebound=true,install_false=true})[mode]
 check(good==not expected_fail,'close result '..mode..' '..tostring(stats.failure))
 if mode=='normal' or mode=='last_write'then
  check(stats.installed and stats.restored and not stats.failure,'normal installation')
  check(stats.scopes==1 and stats.primary==3 and stats.secondary==6 and stats.unions==3,'normal scope/call census')
  check(stats.cached_primary==2 and stats.cached_secondary==5 and actual()==2,'first return calibration then reuse')
  check(stats.transforms==4 and stats.minimums==2 and stats.copies==5,'complete replacement work')
  check(stats.writes==(mode=='last_write' and 3 or 2) and stats.guards==2,'all writes and both full guards')
  check(stats.allocated==8 and stats.freed==8 and stats.peak==6 and stats.live==0,'bounded ownership')
 elseif mode=='native_tuple'then check(stats.invalidations==1 and stats.cached_primary==0 and stats.cached_secondary==0 and actual()==9,'unqualified tuple fallback')
 elseif mode=='unsupported_write' or mode=='foreign_write'then check(stats.invalidations==1 and stats.restored,'unsupported mutation fallback')
 elseif mode=='missing_api'then check(not stats.installed and actual()==9,'missing API uses original path')end
 check(stats.live==0,'no owned leak '..mode)
 for g in pairs(live)do check(borrowed[g],'private model allocation leaked '..mode)end
 for k,v in pairs(originals)do
  check(api[k]==(mode=='rebound' and k=='GridOr' and replacement or v),'global restored/preserved '..k)
 end
 check(class.ProcStart==start and class.ProcEnd==finish,'class restored')
end
print('PASS '..checks..' supported distance helper model checks')
]]
assert(load(source..'\n'..tests,'supported helper fixture','t',_G))()
