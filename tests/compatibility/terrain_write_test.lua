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
local captures, allocations = {}, {}
local api = {
  GetTypeGrid = function(map) assert(map == owner); return raw end,
  SetTypeGrid = function(map, g, extra) captures[#captures+1] = {map=map, grid=g, extra=extra}; return nil, "type-result" end,
  SetForcedImpassFromMask = function(map, g) captures[#captures+1] = {map=map, grid=g}; return "mask-result" end,
}
local originals = {api.SetTypeGrid, api.SetForcedImpassFromMask}
local globals = {
  terrain = api, box = function(...) return {...} end, point = function(...) return {...} end,
  NewComputeGrid = function(w,h) local g=grid(w,h,0); allocations[#allocations+1]=g; return g end,
  GridFill = function(g,v) for i=1,#g.cells do g.cells[i]=v end end,
  GridToCompute = function(g) local c=grid(g.w,g.h,9); allocations[#allocations+1]=c; return c end,
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
  assert(captures[1].grid.cells[1+y*8+x] == ((x<6 and y<6) and 3 or 9))
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
print("PASS: exact source copy, preserved type padding, zero mask padding, owner isolation, results, cleanup, restoration")
