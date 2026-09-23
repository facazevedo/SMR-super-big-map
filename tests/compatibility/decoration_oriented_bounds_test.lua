SuperBigMap={Engine={Global=function()end}}
dofile('Code/sbm_decoration_geometry.lua');dofile('Code/sbm_decoration_validation.lua')
local function up(fn,name)
 for i=1,100 do local k,v=debug.getupvalue(fn,i);if k==name then return v elseif not k then break end end
 error('missing upvalue '..name)
end
local raw=up(up(up(SuperBigMap.DecorationValidation.Validate,'Scan'),'ComponentContact'),'RawComponentContact')
local separated=up(raw,'OrientedContactSeparated')
local function corners(record,bounds)
 local out={};local m=record.pose.matrix
 for x=0,1 do for y=0,1 do for z=0,1 do
  local p={bounds[1+x*3],bounds[2+y*3],bounds[3+z*3]};local q={}
  for i=1,3 do
   q[i]=m.origin[i]+record.pose.shift[i]
   for j=1,3 do q[i]=q[i]+m.columns[j][i]*p[j] end
  end
  out[#out+1]=q
 end end end
 return out
end
local function interval(points,n)
 local lo,hi=math.huge,-math.huge
 for _,p in ipairs(points)do
  local d=0;for i=1,3 do d=d+p[i]*n[i] end
  lo=math.min(lo,d);hi=math.max(hi,d)
 end
 return lo,hi
end
math.randomseed(442)
local proofs=0
for trial=1,5000 do
 local records,boxes={},{}
 for j=1,2 do
  local m={origin={},columns={{},{},{}}};local shift={};local box={}
  for i=1,3 do
   m.origin[i]=(trial%2)*800000+math.random()*1000;shift[i]=math.random()*100
   box[i]=-math.random()*10;box[i+3]=math.random()*10
   for k=1,3 do m.columns[k][i]=(math.random()-.5)*100 end
  end
  records[j]={pose={matrix=m,shift=shift}};boxes[j]=box
 end
 local a,b=records[1],records[2];local ab,bb=boxes[1],boxes[2]
 local tolerance=trial%4==0 and 2 or 0
 local result=separated(a,ab,b,bb,tolerance)
 assert(result==separated(a,ab,b,bb,tolerance),'cached immutable box changed verdict')
 if result then
  proofs=proofs+1;local ac,bc=corners(a,ab),corners(b,bb);local witness=false
  for _,r in ipairs(records)do for _,n in ipairs(r.pose.matrix.columns)do
   local al,ah=interval(ac,n);local bl,bh=interval(bc,n)
   local length=math.sqrt(n[1]^2+n[2]^2+n[3]^2)
   if math.max(bl-ah,al-bh)>tolerance*length then witness=true end
  end end
  assert(witness,'shortcut separated boxes without a complete corner projection witness')
 end
 assert(not separated(a,ab,a,ab,tolerance),'coincident box rejected')
end
assert(proofs>500,'insufficient separated-box coverage')
local a={pose={matrix={origin={800000,800000,800000},columns={{1,0,0},{0,1,0},{0,0,1}}},shift={0,0,0}}}
local box={-1,-1,-1,1,1,1}
for _,gap in ipairs({0,1e-8,1,2})do
 local b={pose={matrix=a.pose.matrix,shift={2+gap,0,0}}}
 assert(not separated(a,box,b,box,2),'touching/within-tolerance gap rejected')
end
assert(separated(a,box,{pose={matrix=a.pose.matrix,shift={5,0,0}}},box,2))
print('oriented bounds: 5000 affine/reflected box pairs, independent eight-corner proofs, pose caches and tolerance boundaries passed')
