local f=assert(io.open('Code/sbm_deposits.lua','r'));local source=f:read('*a');f:close()
local block=assert(source:match('(function DepositRules.BuildHexCircleExclusions.-)\nfunction DepositRules.BuildSurfaceResidualHexCandidates'))
local origin_x,origin_y,scale,skew=0,0,10,5
local api={point=function(x,y)return{x=x,y=y}end}
api.HexToWorld=function(q,r)return origin_x+scale*q+skew*r,origin_y+8*r end
api.WorldToHex=function(p)local r=(p.y-origin_y)/8;return math.floor((p.x-origin_x-skew*r)/scale+.5),math.floor(r+.5)end
local env=setmetatable({DepositRules={},Global=function(k)return api[k]end},{__index=_G})
assert(load(block,'production repulsion disk intervals','t',env))()
local build=env.DepositRules.BuildHexCircleExclusions
math.randomseed(1001195)
local checked=0
for trial=1,240 do
  origin_x,origin_y=math.random(-10000,10000),math.random(-10000,10000)
  scale,skew=math.random(5,25),math.random(-15,15)
  local disks={}
  for i=1,math.random(0,18)do
    local x,y=api.HexToWorld(math.random(-14,14),math.random(-14,14))
    disks[#disks+1]={x=x+math.random(-3,3),y=y+math.random(-3,3),radius=math.random(0,95)}
  end
  -- Exact integer tangency, overlap, zero-radius centre and duplicate disks.
  disks[#disks+1]={x=origin_x,y=origin_y,radius=scale*3}
  disks[#disks+1]={x=origin_x,y=origin_y,radius=0}
  disks[#disks+1]=disks[1]
  local rows=build(disks)
  for q=-28,28 do
    local last
    for _,interval in ipairs(rows[q]or{})do
      assert(interval[1]<=interval[2] and(not last or interval[1]>last+1),'interval union not normalized')
      last=interval[2]
    end
    for r=-28,28 do
      local x,y=api.HexToWorld(q,r)
      local reference=false
      for _,disk in ipairs(disks)do
        if (x-disk.x)^2+(y-disk.y)^2<=disk.radius^2 then reference=true;break end
      end
      local actual=false
      for _,interval in ipairs(rows[q]or{})do if r>=interval[1] and r<=interval[2] then actual=true;break end end
      assert(actual==reference,'disk exclusion differs from strict world-space predicate at trial '..trial..' hex '..q..','..r)
      checked=checked+1
    end
  end
end
print('hex exclusion intervals: '..checked..' scalar parity checks across translated/skewed grids, overlaps and boundaries')
