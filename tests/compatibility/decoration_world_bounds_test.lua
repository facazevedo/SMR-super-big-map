SuperBigMap={Engine={Global=function()end}}
dofile('Code/sbm_decoration_geometry.lua');dofile('Code/sbm_decoration_validation.lua')
local function up(fn,name)
 for i=1,100 do local k,v=debug.getupvalue(fn,i);if k==name then return v elseif not k then break end end
end
local world_bounds=up(up(SuperBigMap.DecorationValidation.Validate,'Scan'),'WorldBounds')
local raw=up(up(up(SuperBigMap.DecorationValidation.Validate,'Scan'),'ComponentContact'),'RawComponentContact')
local world=up(raw,'World')
local function old(record,b)
 local m=record.pose.matrix;local c=m.columns
 local x,y,z=(b[1]+b[4])*.5,(b[2]+b[5])*.5,(b[3]+b[6])*.5
 local hx,hy,hz=(b[4]-b[1])*.5,(b[5]-b[2])*.5,(b[6]-b[3])*.5
 local result={}
 for a=1,3 do
  local center=m.origin[a]+record.pose.shift[a]+c[1][a]*x+c[2][a]*y+c[3][a]*z
  local extent=math.abs(c[1][a])*hx+math.abs(c[2][a])*hy+math.abs(c[3][a])*hz
  result[a],result[a+3]=center-extent,center+extent
 end
 return result
end
math.randomseed(389)
for trial=1,1000 do
 local r={pose={shift={},matrix={origin={},columns={{},{},{}}}}}
 for a=1,3 do
  r.pose.shift[a]=math.random(-999,999);r.pose.matrix.origin[a]=math.random(-1000000,1000000)
  for j=1,3 do r.pose.matrix.columns[j][a]=(math.random()-.5)*3000 end
 end
 for box=1,32 do
  local b={};for a=1,3 do b[a]=math.random(-100,100);b[a+3]=b[a]+math.random()*100 end
  local actual,expected=world_bounds(r,b),old(r,b)
  for a=1,6 do assert(actual[a]==expected[a],'captured-pose bounds arithmetic changed') end
  local p={b[1],b[2],b[3]};local w=world(r,p);local m=r.pose.matrix
  for a=1,3 do
   local expected=m.origin[a]+r.pose.shift[a]+m.columns[1][a]*p[1]+m.columns[2][a]*p[2]+m.columns[3][a]*p[3]
   assert(w[a]==expected,'world vertex arithmetic changed')
  end
 end
end
print('world bounds: 32000 exact old/new boxes across arbitrary captured affine matrices and world offsets')
