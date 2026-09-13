-- PRIVATE mapless native identity experiment. No production hooks, maps or RNG.
local r={status='setup',cases={},issues={},allocated=0,freed=0,cells=0,
 all_cases_hold=true,all_nonempty_hold=true}
rawset(_G,'SBM_PLAYABLE_DISTANCE_CONTRACT',r)
local sbm
for _,mod in ipairs(ModsLoaded or {})do
 local s=mod.env and rawget(mod.env,'SuperBigMap');if s and s.Engine then sbm=s;break end
end
local function fail(why)r.issues[#r.issues+1]=tostring(why)end
if not sbm then fail('mod missing');r.status='fail';return end
local api={}
for _,name in ipairs({'NewComputeGrid','GridOr','GridDistanceMars','GridMin'})do
 api[name]=sbm.Engine.Global(name)
 if type(api[name])~='function'then fail('missing '..name)end
end
local constants=sbm.Engine.Global('const')
local packing=type(constants)=='table' and constants.PrefabGridPacking or 16
r.packing=packing
if packing~=16 then fail('unqualified prefab packing '..tostring(packing))end
if #r.issues>0 then r.status='fail';return end
local owned={}
local function own(grid)
 if not grid or owned[grid]then fail('invalid/aliased owned grid');return end
 owned[grid]=true;r.allocated=r.allocated+1;return grid
end
local function cleanup()
 for grid in pairs(owned)do
  local ok,why=pcall(grid.free,grid)
  if ok then owned[grid]=nil;r.freed=r.freed+1 else fail(why)end
 end
end
local definitions={
 {'opposite_corners',32,32,function(x,y,w,h)return x==0 and y==0,x==w-1 and y==h-1 end},
 {'overlap',32,32,function(x,y)return x==8 and y==8,x==8 and y==8 end},
 {'disjoint_circles',32,32,function(x,y)return (x-7)^2+(y-11)^2<=9,(x-25)^2+(y-22)^2<=16 end},
 {'overlap_circles',32,32,function(x,y)return (x-14)^2+(y-16)^2<=36,(x-18)^2+(y-16)^2<=36 end},
 {'edge_frame',32,32,function(x,y,w,h)return x==16 and y==16,x==0 or y==0 or x==w-1 or y==h-1 end},
 {'checkerboard',32,32,function(x,y)return (x+y)%2==0,(x+y)%2==1 end},
 {'sparse',128,128,function(x,y)return (x*37+y*19)%277==0,(x*13+y*41)%353==0 end},
 {'full_full',32,32,function()return true,true end},
 {'empty_empty',32,32,function()return false,false end},
 {'empty_corner',32,32,function(x,y)return false,x==0 and y==0 end},
 {'corner_empty',32,32,function(x,y)return x==0 and y==0,false end},
 {'actual_size_frame',768,768,function(x,y,w,h)return (x-241)^2+(y-423)^2<=144,x<5 or y<5 or x>=w-5 or y>=h-5 end},
}
local ok,why=pcall(function()
 for _,definition in ipairs(definitions)do
  local name,w,h,pattern=table.unpack(definition)
  local grids={}
  for i=1,6 do grids[i]=own(api.NewComputeGrid(w,h,'U',packing));if not grids[i]then return end end
  local a,b,union,da,db,combined=table.unpack(grids)
  local row={name=name,width=w,height=h,seeds_a=0,seeds_b=0,mismatches=0}
  for y=0,h-1 do for x=0,w-1 do
   local av,bv=pattern(x,y,w,h);av=av and 1 or 0;bv=bv and 1 or 0
   a:set(x,y,av);b:set(x,y,bv);row.seeds_a=row.seeds_a+av;row.seeds_b=row.seeds_b+bv
  end end
  -- Match the actual primary in-place and secondary explicit-destination calls.
  api.GridOr(a,union,b)
  for y=0,h-1 do for x=0,w-1 do
   local av,bv=pattern(x,y,w,h)
   if union:get(x,y)~=((av or bv)and 1 or 0)then fail('native OR boundary')end
  end end
  api.GridDistanceMars(union,1,1)
  api.GridDistanceMars(a,da,1,1)
  api.GridDistanceMars(b,db,1,1)
  local guard_a,guard_b=own(da:clone()),own(db:clone())
  if not guard_a or not guard_b then return end
  api.GridMin(da,combined,db)
  for y=0,h-1 do for x=0,w-1 do
   local av,bv=pattern(x,y,w,h)
   if a:get(x,y)~=(av and 1 or 0)or b:get(x,y)~=(bv and 1 or 0)then fail('distance source mutated')end
   local ad,bd=guard_a:get(x,y),guard_b:get(x,y)
   if da:get(x,y)~=ad or db:get(x,y)~=bd then fail('minimum source mutated')end
   local expected,actual=union:get(x,y),combined:get(x,y)
   if actual~=math.min(ad,bd)then fail('native minimum boundary')end
   if expected~=actual then
    row.mismatches=row.mismatches+1
    if not row.first then row.first={x=x,y=y,union_distance=expected,composed=actual,a=ad,b=bd}end
   end
   r.cells=r.cells+1
  end end
  if row.mismatches>0 then
   r.all_cases_hold=false
   if row.seeds_a>0 and row.seeds_b>0 then r.all_nonempty_hold=false end
  end
  r.cases[#r.cases+1]=row
  cleanup()
  if #r.issues>0 then return end
 end
end)
if not ok then fail(why)end
cleanup()
r.scratch_released=next(owned)==nil and r.allocated==r.freed
r.status=#r.issues==0 and r.scratch_released and 'pass' or 'fail'
return 'PLAYABLE_DISTANCE_CONTRACT_'..r.status
