local path=arg[1] or '_ralph/runs/under80-20260912/artifacts/crease_offer_research_2/sbm_terrain_copy.lua'
local f=assert(io.open(path,'r'));local source=f:read('*a');f:close()
local body=assert(source:match('(local function BuildHeightStepDiscoveryIndex.-)\nend'))..'\nend'
local build=assert(load(body..'\nreturn BuildHeightStepDiscoveryIndex'))()
local api=dofile('_ralph/tools/parity/native_grid_double.lua')
-- Use the shared signed-storage copy model corrected AFTER native evidence.
-- No private model override hides the behavior from inherited parity tests.
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
