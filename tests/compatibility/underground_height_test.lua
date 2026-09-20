local f=assert(io.open('Code/sbm_terrain_copy.lua','r'))
local source=f:read('*a');f:close()
local block=assert(source:match('(local uniform_underground = environment == "Underground".-)\n%s*pcall%(grid_muldivadd'))
local function transform(environment,min0,max0,cap,shift)
 local env=setmetatable({environment=environment,min0=min0,max0=max0,cap=cap,
  full_tw=8192,sw_tiles=6144,Z_FLOOR_WU=1000,
  cfg_bool=function(key,default)
   if key=='STRETCH_SHIFT_HEIGHTS_DOWN' and shift~=nil then return shift end
   return default
  end}, {__index=_G})
 return assert(load(block..'\nreturn zmul,zdiv,zadd,normalized','height transform','t',env))()
end
local m,d,a,n=transform('Underground',10000,22784,65535)
assert(m==8192 and d==6144 and a==-3333 and n==false)
assert(math.floor(10000*m/d)+a==10000,'the native underground floor must not be lowered')
assert(math.floor(22784*m/d)+a<=65535)
local sm,sd,sa,sn=transform('Surface',10000,22784,65535)
assert(sm==8192 and sd==6144 and sa==-12333 and sn==false,
 'surface headroom normalization is unchanged')
m,d,a,n=transform('Underground',10000,22784,65535,false)
assert(a==0,'explicit normalization opt-out remains honored')
local ok=pcall(transform,'Underground',50000,65000,65535)
assert(not ok,'an underground map that cannot fit must not silently squash or lower')
print('underground height: floor anchor, uniform scale, surface isolation and overflow passed')
