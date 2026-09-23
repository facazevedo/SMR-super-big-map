local f=assert(io.open('Code/sbm_decoration_validation.lua','rb'));local source=f:read('*a');f:close()
local body=assert(source:match('(\tlocal heights,height_rows=.-)\n\tlocal function root'))
for _,dimensions in ipairs({{819200,819200},{4096,6144},{67108864,67108864},{67108865,7},{11.5,11}}) do
 local width,height=table.unpack(dimensions);local calls=0;local expected={}
 local env=setmetatable({width=width,height=height,map={},floor=math.floor,
  terrain={GetHeight=function(_,x,y)calls=calls+1;return x*3-y*2 end}},{__index=_G})
 local at=assert(load(body..'\nreturn height_at','production height cache','t',env))()
 math.randomseed(391)
 for sample=1,3000 do
  local x,y
  if sample%7==0 then x,y=width-1,height-1
  elseif sample%11==0 then x,y=-1,0
  elseif sample%13==0 then x,y=width,0
  else x,y=math.random(0,10000)%width+.4,math.random(0,10000)%height-.4 end
  local ix,iy=math.floor(x+.5),math.floor(y+.5)
  local key=ix..':'..iy;local before=calls
  assert(at(x,y)==ix*3-iy*2,'height cache cell collision or changed rounding')
  assert(calls-before==(expected[key] and 0 or 1),'duplicate query or stale key')
  expected[key]=true
 end
end
print('decor height cache: 15000 exact queries across full bounds, large cells, negative/outside and nonintegral dimensions')
