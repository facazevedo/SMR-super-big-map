local f=assert(io.open('Code/sbm_terrain_copy.lua','r'));local source=f:read('*a');f:close()
local block=assert(source:match('%-%- NATURAL_APRON_BUILDABLE_POLICY_BEGIN(.-)%-%- NATURAL_APRON_BUILDABLE_POLICY_END'))
local policy=assert(load(block..'\nreturn NaturalApronBuildableCorePolicy'))()
local base={50,150,4,4,20}
for index=1,5 do
  for _,bad in ipairs({false,'bad',0/0,math.huge,-math.huge})do
    local args={table.unpack(base)};args[index]=bad
    assert(not policy(table.unpack(args,1,5)))
  end
  local args={table.unpack(base)};args[index]=nil
  assert(not policy(table.unpack(args,1,5)),'missing native setting accepted')
end
assert(not policy(-1,150,4,4,20))
assert(not policy(50,2,4,4,20))
assert(not policy(50,150,0,4,20))
assert(not policy(50,150,4,0,20))
assert(not policy(50,150,4,4,0))
local tested=0
for _,area in ipairs({0,1,7,19,37,50,61,91,100,1000})do
  for _,delta in ipairs({3,50,150,500})do
    for _,scale in ipairs({0.5,1,4,8,16})do
      local p=assert(policy(area,delta,scale,4,20))
      local rings=p.support_rings
      assert(1+3*rings*(rings+1)>area,'native minimum area is strict')
      if rings>0 then assert(1+3*(rings-1)*rings<=area)end
      assert(p.core_hexes*0.952*0.90>=rings+3,'erosion/alignment margin missing')
      assert(p.core_hexes/p.feather_hexes<=0.75 and p.core_hexes/p.feather_hexes>=0.2)
      local radius=p.core_hexes*scale*1.35*1.036*1.09
      local worst_pair_height_delta=2*radius*p.maximum_gradient+1
      assert(2*worst_pair_height_delta<=delta+1e-10,'native flood fill height spread exceeded')
      tested=tested+1
    end
  end
end
local p=assert(policy(table.unpack(base)))
assert(p.core_hexes==9 and p.feather_hexes==20)
local large=assert(policy(50,150,4,30,20))
assert(large.core_hexes==30 and large.feather_hexes>=40,'explicit larger core lost')
print('native apron buildability: '..tested..' area/height/scale policies, strict area and invalid native settings')
