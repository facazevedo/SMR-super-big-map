-- Execute production's start-selection block, including its geometry helper.
local source_file = assert(io.open('Code/sbm_sector_exploration.lua', 'rb'))
local source = source_file:read('*a')
source_file:close()
local helper = source:match('%-%- START_ANCHOR_HELPER_BEGIN(.-)%-%- START_ANCHOR_HELPER_END') or ''
local selection = assert(source:match('(\tlocal selected = .-)\n\tlocal reveal_targets ='))
local select_anchor = assert(load(helper .. '\nreturn function(overlaps,x0,y0,x1,y1,revealed)\n'
  .. selection .. '\nreturn selected end', 'production start anchor'))()

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
    -- Resource quality may prefer an overlapping neighbour. It must not move
    -- the sole reveal away from the geometrically transformed start position.
    for first=1,9 do
      local actual = select_anchor(grid,ox+size/2,oy+size/2,
        ox+size*2.5,oy+size*2.5,{grid[first].sector})
      assert(actual=='1:1','resource winner displaced the geometric start anchor')
      checks=checks+1
    end
    -- Shared border belongs to the sector beginning there (half-open bounds).
    assert(select_anchor(grid,ox,oy,ox+2*size,oy+2*size,{'0:0'})=='1:1')
    -- Slightly before that border must remain in the preceding sector.
    assert(select_anchor(grid,ox,oy,ox+2*size-1,oy+2*size-1,{'1:1'})=='0:0')
    local reversed={}
    for i=#grid,1,-1 do reversed[#reversed+1]=grid[i] end
    assert(select_anchor(reversed,ox,oy,ox+2*size,oy+2*size,{'0:0'})=='1:1')
    checks=checks+3
  end
end
local ok = pcall(select_anchor, sectors(0,0,10),100,100,120,120,{'0:0'})
assert(not ok,'missing geometric anchor must fail loudly, not select a neighbour')
local errors = 0
local no_throw = assert(load(helper .. '\nreturn function(overlaps,x0,y0,x1,y1,revealed)\n'
  .. selection .. '\nreturn selected end', 'non-throwing engine error', 't',
  {error=function() errors=errors+1 end}))()
assert(no_throw(sectors(0,0,10),100,100,120,120,{'0:0'})==0 and errors==1,
  'non-throwing error must return before clearing any existing reveal')
print('PASS start anchor production selection: '..(checks+2)..' checks')
