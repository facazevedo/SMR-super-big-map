local path=arg[1] or '_ralph/runs/under80-20260912/artifacts/crease_offer_research_2/sbm_terrain_copy.lua'
local f=assert(io.open(path,'r'));local source=f:read('*a');f:close()
local body=assert(source:match('(local function BuildHeightStepDiscoveryIndex.-)\nend'))..'\nend'
local build=assert(load(body..'\nreturn BuildHeightStepDiscoveryIndex'))()
local api=dofile('_ralph/tools/parity/native_grid_double.lua')
-- The shared double routes copyrect through its unsigned set() emulation.
-- A private raw f32-to-f32 copy model is required here, and is NOT native proof.
-- The shared oracle checks real signed native copyrect before any promotion.
local probe=api.NewComputeGrid(1,1,'f',32)
local methods=getmetatable(probe).__index
probe:free()
local prior_copy=methods.copyrect
function methods:copyrect(from,bounds,to)
 if self.format~='f' or from.format~='f' then return prior_copy(self,from,bounds,to)end
 assert(not self.freed)
 local sw,sh=from:size()
 assert(bounds.x0>=0 and bounds.y0>=0 and bounds.x1<=sw and bounds.y1<=sh)
 for y=bounds.y0,bounds.y1-1 do for x=bounds.x0,bounds.x1-1 do
  local dx,dy=to.x+x-bounds.x0,to.y+y-bounds.y0
  assert(dx>=0 and dy>=0 and dx<self.w and dy<self.h)
  self.values[dy*self.w+dx]=from:get(x,y)
 end end
end
for _,inclusive in ipairs({false,true})do
 api.GridMask=function(input,output,lo,hi)
  local w,h=input:size()
  for y=0,h-1 do for x=0,w-1 do
   local v=input:get(x,y)
   output:set(x,y,((inclusive and v>=lo or not inclusive and v>lo)and v<=hi)and 1 or 0)
  end end
 end
 local checks,issues=dofile('_ralph/tmp/under80_20260912/crease_offer_oracle.lua')(build,api)
 assert(#issues==0,table.concat(issues,'\n'))
 print('PASS collection offer grid oracle:',checks,'checks; inclusive='..tostring(inclusive))
end
local original=api.GridForeach
local grid=api.NewComputeGrid(9,5,'u',16)
for y=0,4 do for x=4,8 do grid:set(x,y,128)end end
for _,bad in ipairs({1,3,262144,131072})do
 api.GridForeach=function(g,callback,lo,hi)
  original(g,function(_,x,y)callback(bad,x,y)end,lo,hi)
 end
 local rows,why=build(api,grid,'x',1,6,5,1,3,128)
 assert(rows==nil and type(why)=='string','invalid signed packet accepted')
end
for _,mode in ipairs({'missing','duplicate','coordinate'})do
 api.GridForeach=function(g,callback,lo,hi)
  if mode=='missing'then return end
  original(g,function(value,x,y)
   callback(value,mode=='coordinate' and -1 or x,y)
   if mode=='duplicate'then callback(value,x,y)end
  end,lo,hi)
 end
 local rows,why=build(api,grid,'x',1,6,5,1,3,128)
 assert(rows==nil and type(why)=='string',mode..' enumeration accepted')
end
grid:free()
print('PASS 7 signed-packet/enumeration failure cases')
