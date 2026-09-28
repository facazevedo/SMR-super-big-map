-- The stretched-centre helper, which since the owner's 2026-09-28 start-sector rule is only the
-- fallback when vanilla's start sector has no opening deposit to rank by (the rule itself is
-- tested in tests/compatibility/start_sector_rule_test.lua).
local source_file = assert(io.open('Code/sbm_sector_exploration.lua', 'rb'))
local source = source_file:read('*a')
source_file:close()
local helper = assert(source:match('%-%- START_ANCHOR_HELPER_BEGIN(.-)%-%- START_ANCHOR_HELPER_END'))
local select_anchor = assert(load(helper .. '\nreturn function(overlaps,x0,y0,x1,y1)\n'
  .. 'local s = SelectTransformedStartAnchor(overlaps,x0,y0,x1,y1) return s end', 'start anchor helper'))()

local function sectors(ox, oy, size)
  local result = {}
  for y=0,2 do
    for x=0,2 do
      result[#result+1] = {sector=tostring(x)..':'..tostring(y),
        x0=ox+x*size, y0=oy+y*size, x1=ox+(x+1)*size, y1=oy+(y+1)*size}
    end
  end
  return result
end

local checks = 0
for _, origin in ipairs({{0,0},{1200,2500},{-5100,-300}}) do
  for _, size in ipairs({10,11,40960}) do
    local ox,oy = origin[1],origin[2]
    local grid = sectors(ox,oy,size)
    assert(select_anchor(grid,ox+size/2,oy+size/2,ox+size*2.5,oy+size*2.5)=='1:1')
    -- Shared border belongs to the sector beginning there (half-open bounds).
    assert(select_anchor(grid,ox,oy,ox+2*size,oy+2*size)=='1:1')
    -- Slightly before that border must remain in the preceding sector.
    assert(select_anchor(grid,ox,oy,ox+2*size-1,oy+2*size-1)=='0:0')
    local reversed={}
    for i=#grid,1,-1 do reversed[#reversed+1]=grid[i] end
    assert(select_anchor(reversed,ox,oy,ox+2*size,oy+2*size)=='1:1')
    checks=checks+4
  end
end
local ok = pcall(select_anchor, sectors(0,0,10),100,100,120,120)
assert(not ok,'a missing centre sector must fail loudly, not select a neighbour')
print('PASS start anchor fallback helper: '..(checks+1)..' checks')
