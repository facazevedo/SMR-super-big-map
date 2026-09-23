local f = assert(io.open("Code/sbm_map_generation.lua", "r"))
local source = f:read("*a"); f:close()
local block = assert(source:match("function SuperBigMap.InstallSourceTerrainWriteBridge.-\nend\n"))
local function grid(w, h, value)
  local g = { w = w, h = h, freed = false, cells = {} }
  for i = 1, w*h do g.cells[i] = value end
  function g:size() return self.w, self.h end
  function g:free() assert(not self.freed); self.freed = true end
  function g:copyrect(src, bounds, origin)
    assert(bounds[1] == 0 and bounds[2] == 0 and origin[1] == 0 and origin[2] == 0)
    for y = 0, bounds[4]-1 do for x = 0, bounds[3]-1 do
      self.cells[1+y*self.w+x] = src.cells[1+y*src.w+x]
    end end
  end
  return g
end
local owner, other, raw = {}, {}, grid(8, 8, 9)
for i=1,#raw.cells do raw.cells[i]=(i*37)%256 end
local captures, allocations = {}, {}
local rebuilds = 0
local api = {
	RebuildPassability = function() rebuilds=rebuilds+1; return 'rebuilt' end,
  GetTypeGrid = function(map) assert(map == owner); return raw end,
  SetTypeGrid = function(map, g, extra)
    if g.type_grid then
      assert(map==owner and g.scale==100 and g.centered==false and g.pos[1]==0 and g.pos[2]==0)
      assert(g.type_grid.u8,'native regional writer requires U8')
      local result=grid(8,8,9)
      for i=1,#raw.cells do result.cells[i]=raw.cells[i] end
      result:copyrect(g.type_grid,{0,0,g.type_grid.w,g.type_grid.h},{0,0})
      g=result
    end
    captures[#captures+1] = {map=map, grid=g, extra=extra}; return nil, "type-result"
  end,
  SetForcedImpassFromMask = function(map, g) captures[#captures+1] = {map=map, grid=g}; return "mask-result" end,
}
local originals = {api.SetTypeGrid, api.SetForcedImpassFromMask, api.RebuildPassability}
local globals = {
  terrain = api, box = function(...) return {...} end, point = function(...) return {...} end,
  NewComputeGrid = function(w,h) local g=grid(w,h,0); allocations[#allocations+1]=g; return g end,
  GridFill = function(g,v) for i=1,#g.cells do g.cells[i]=v end end,
  GridToCompute = function(g) local c=grid(g.w,g.h,9); allocations[#allocations+1]=c; return c end,
  GridRepack = function(g,fmt,bits)
    assert(fmt=='U' and bits==8)
    local c=grid(g.w,g.h,0);c.u8=true
    for i=1,#g.cells do c.cells[i]=g.cells[i] end
    allocations[#allocations+1]=c;return c
  end,
  GridWriteStr = function(g) assert(g.w==6 and g.h==6); return 'serialized-source-mask' end,
}
local env = setmetatable({ SuperBigMap={}, Global=function(name)return globals[name]end,
  PackValues=table.pack, Unpack=table.unpack,
  FreeMigrationGrid=function(g,borrowed) if g~=borrowed then g:free() end end,
}, {__index=_G})
assert(load(block, "terrain bridge", "t", env))()
local close, stats = env.SuperBigMap.InstallSourceTerrainWriteBridge(owner, 6, 6, 8, 8)
local src = grid(6,6,3)
local a,b=api.SetTypeGrid(owner,src,"extra")
assert(a==nil and b=="type-result")
assert(captures[1].extra=="extra")
for y=0,7 do for x=0,7 do
  assert(captures[1].grid.cells[1+y*8+x] == ((x<6 and y<6) and 3 or raw.cells[1+y*8+x]))
end end
assert(api.SetForcedImpassFromMask(owner,src)=="mask-result")
assert(owner.SuperBigMapForcedImpassSource=='serialized-source-mask')
for y=0,7 do for x=0,7 do
  assert(captures[2].grid.cells[1+y*8+x] == ((x<6 and y<6) and 3 or 0))
end end
api.SetTypeGrid(other,src)
assert(captures[3].grid==src)
assert(stats.type_writes==1 and stats.mask_writes==1)
assert(not raw.freed and not src.freed)
for _,g in ipairs(allocations)do assert(g.freed)end
close(); close()
assert(api.SetTypeGrid==originals[1] and api.SetForcedImpassFromMask==originals[2])
-- A deferred source retains exact bytes but allocates/writes no temporary mask.
local before_captures, before_allocations = #captures, #allocations
local deferred_close, deferred_stats = env.SuperBigMap.InstallSourceTerrainWriteBridge(owner,6,6,8,8,true)
assert(api.RebuildPassability(owner)=='rebuilt' and rebuilds==1)
assert(api.SetForcedImpassFromMask(owner,src)==nil)
assert(api.RebuildPassability(owner)==nil and rebuilds==1 and deferred_stats.deferred_rebuilds==1)
assert(api.RebuildPassability(other)=='rebuilt' and rebuilds==2)
assert(owner.SuperBigMapForcedImpassSource=='serialized-source-mask' and owner.SuperBigMapForcedImpassDeferred)
assert(#captures==before_captures and #allocations==before_allocations)
assert(deferred_stats.deferred_masks==1 and deferred_stats.mask_writes==0)
api.SetForcedImpassFromMask(other,src)
assert(#captures==before_captures+1 and captures[#captures].map==other)
-- Even a log-only engine error cannot turn a failed capture into a successful deferral.
globals.GridWriteStr=function() return nil,'injected encode failure' end
env.error=function() end
owner.SuperBigMapForcedImpassSource=false;owner.SuperBigMapForcedImpassDeferred=false
assert(api.SetForcedImpassFromMask(owner,src)==nil)
assert(deferred_stats.error:find('injected encode failure') and deferred_stats.deferred_masks==1)
assert(not owner.SuperBigMapForcedImpassSource and not owner.SuperBigMapForcedImpassDeferred)
deferred_close()
assert(api.RebuildPassability==originals[3])
-- U8 aliases remain borrowed, while conversion failures become explicit failures.
globals.GridRepack=function(g) g.u8=true;return g end
local alias_close,alias_stats=env.SuperBigMap.InstallSourceTerrainWriteBridge(owner,6,6,8,8,false)
api.SetTypeGrid(owner,src)
assert(not src.freed and alias_stats.type_writes==1)
globals.GridRepack=function() return nil end
api.SetTypeGrid(owner,src)
assert(alias_stats.error:find('conversion failed') and alias_stats.type_writes==1)
alias_close()
print("PASS: exact source copy, preserved type padding, zero mask padding, owner isolation, results, cleanup, restoration")
