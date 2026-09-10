-- Real production guard versus the real raster's aligned write rectangle.
local f = assert(io.open(arg[1] or "Code/sbm_terrain_copy.lua", "r"))
local source = f:read("*a"); f:close()
local a = assert(source:find("local function NewRocketBlendEdgeGuard(",1,true), "edge guard missing")
local b = assert(source:find("-- ROCKET_BLEND_EDGE_GUARD_END",a,true))
local factory = assert(load(source:sub(a,b-1).."\nreturn NewRocketBlendEdgeGuard"))()
local cap = assert(tonumber(source:match("local adaptive_transition_cap = (%d+) %* cells_per_hex")))
local scale = assert(tonumber(source:match("local maximum_width_scale = ([%d%.]+)")))
assert(cap == 36 and scale == 1.35, "raster changed: update the conservative edge certificate")
a = assert(source:find("\tlocal function aligned_native_bounds(",1,true))
b = assert(source:find("\tlocal function apply_native_patch(",a,true))
local checks, accepted = 0, 0
for _, size in ipairs({1024, 4096, 8192, 16384}) do
  local bounds = assert(load(source:sub(a,b-1).."\nreturn aligned_native_bounds", nil, "t",
    setmetatable({width=size,height=size-17},{__index=_G})))()
  for _, cells in ipairs({1, 7.5, 10}) do
    for _, core in ipairs({3,8,15}) do
      for _, transition in ipairs({6,50}) do
        local fits = factory(size,size-17,core*cells,(core+6)*cells,transition*cells,cells)
        for x = -1, size, 7.25 do
          for _, y in ipairs({x, size-1-x, 0, size-18, size/2}) do
            if fits(x,y) then
              accepted=accepted+1
              for _, adaptive in ipairs({0,cap*0.5,cap}) do
                local radius=core*cells+math.max(2,6,transition,adaptive)*cells*scale
                local x0,y0,x1,y1=bounds({cx=x,cy=y},radius,2,4)
                assert(x0>0 and y0>0 and x1<size-1 and y1<size-18,
                  "accepted pad can touch a physical edge")
                checks=checks+1
              end
            end
          end
        end
        assert(not fits(1,size/2) and not fits(size-2,size/2)
          and not fits(size/2,1) and not fits(size/2,size-19), "all four edges excluded")
      end
    end
  end
end
assert(accepted>1000, "guard cannot pass vacuously")
assert(source:find("not rocket_blend_fits(x / height_tile, y / height_tile)",1,true), "planner bypasses guard")
print("rocket blend edge: "..checks.." native rectangle comparisons passed")
