local function read(path)local f=assert(io.open(path,'rb'));local s=f:read('*a'):gsub('\r\n','\n');f:close();return s end
local source=read('Code/sbm_decor_topup.lua')
local body=assert(source:match('(local function circle_hits%(.-)\nend'))..'\nend'
local old=assert(load(body..'\nreturn circle_hits'))()
local indexed_body,n=body:gsub('then return true end','then return true, c end')
assert(n==1)
local indexed=assert(load(indexed_body..'\nreturn circle_hits'))()
local factory=dofile(arg[1] or '_ralph/tmp/under80_20260912/decor_positive_cell.lua')
local candidate=factory(indexed)
local checks,certified=0,0
local function oracle(list,x,y,r)
    for i=1,#list do
        local c=list[i];local dx,dy=x-c.x,y-c.y;local reach=r+c.r
        if dx*dx+dy*dy<reach*reach then return true end
    end
    return false
end
local pairs_by_list={}
local function check(list,x,y,r,exhaustive)
    local copy=pairs_by_list[list]
    if not copy then copy={};pairs_by_list[list]=copy end
    for i=#copy+1,#list do copy[i]=list[i] end
    local before=copy.spatial_index and copy.spatial_index.serial or 0
    local expected,actual=old(list,x,y,r),candidate(copy,x,y,r)
    assert(expected==actual,('old/new mismatch %.17g %.17g %.17g'):format(x,y,r))
    if exhaustive~=false then assert(actual==oracle(list,x,y,r),'exhaustive mismatch')end
    if actual and (copy.spatial_index and copy.spatial_index.serial or 0)==before then certified=certified+1 end
    checks=checks+1
    return copy
end
-- Positive certificate, every padded-cell edge, and radius threshold changes.
for _,center in ipairs({-16384,-0.5,0,0.5,16384})do
    local list={{x=center+2048,y=center+2048,r=6000.25}}
    for i=1,40 do check(list,center+2048,center+2048,1024.5)end
    for _,dx in ipairs({0,0.000001,1,2048,4095.999999,4096})do
        for _,dy in ipairs({0,0.000001,1,2048,4095.999999,4096})do
            for _,r in ipairs({0,1,1023.999999,1024,1024.5,65536})do check(list,center+dx,center+dy,r)end
        end
    end
end
-- Strict tangency, radii/cell boundaries, noninteger and negative coordinates.
for _,center in ipairs({-32768,-0.5,0,0.5,32768})do
    local list={{x=center,y=center,r=8192}}
    for rep=1,40 do
        for _,delta in ipairs({-0.001,0,0.001})do
            for _,r in ipairs({0,1,8192,32768})do
                check(list,center+8192+r+delta,center,r)
                check(list,center,center-8192-r+delta,r)
            end
        end
    end
end
local state=71
local function rand(n)state=(state*16807)%2147483647;return state%n end
local list={}
for batch=1,12 do
    for i=1,40 do list[#list+1]={x=rand(1600000)-800000+0.25,y=rand(1600000)-800000-0.25,r=rand(50000)}end
    for i=1,4000 do check(list,rand(1800000)-900000,rand(1800000)-900000,({0,1,8192,11000.25,32768})[i%5+1])end
end
local a,b={},{}
for i=1,40 do check(a,17,29,1);check(b,17,29,1)end
a[1]={x=2048,y=2048,r=8192}
local copy=check(a,17,29,1);check(a,17,29,1);check(b,17,29,1)
assert(copy.positive_cell_cache.slots>0,'no learned positive')
local serial=copy.spatial_index.serial
a[2]={x=100000,y=100000,r=8192}
check(a,17,29,1)
assert(copy.spatial_index.serial==serial,'positive invalidated by append')
check(a,100000,100000,1)
assert(copy.spatial_index.count==#a,'miss did not catch up appended circle')
-- Unsupported domains and fractional extremes retain the complete query.
for _,center in ipairs({-16777216,16777216,-16777217,16777217})do
    local edge={{x=center,y=center,r=8192.125}}
    for i=1,40 do check(edge,center,center,1024)end
    for _,delta in ipairs({-0.000001,0,0.000001,8192.125})do check(edge,center+delta,center,0)end
end
for _,r in ipairs({65535.999999,65536,65536.000001})do for i=1,40 do check(list,0,0,r)end end
for _,x in ipairs({-1e-310,0,1e-310})do for i=1,40 do check(a,x,0,8192)end end
-- Cache cap is a memory bound, not a query/placement budget. Populate only
-- metadata to exercise exact fallback, then allow improving an existing entry.
local capped={ {x=2048,y=2048,r=8192} }
capped.positive_cell_cache={rows={},queries=32,slots=32768,learned=0,descriptors={},radii={},radius_count=0}
assert(candidate(capped,2048,2048,0)==true)
assert(capped.positive_cell_cache.learned==0)
capped.positive_cell_cache.rows[0]={[0]=4096}
assert(candidate(capped,2048,2048,0)==true)
assert(capped.positive_cell_cache.rows[0][0]==0 and capped.positive_cell_cache.slots==32768)
local radius_cap={{x=2048,y=2048,r=1}}
local radius_copy
for i=1,1100 do radius_copy=check(radius_cap,2048,2048,i)end
if radius_copy.positive_cell_cache.radii then
    local count=0;for _ in pairs(radius_copy.positive_cell_cache.radii)do count=count+1 end
    assert(count==1024 and radius_copy.positive_cell_cache.radius_count==1024,'radius cache cap')
end
assert(certified>100,'certificate path not exercised')
print('PASS positive-cell:',checks,'old/new/exhaustive checks;',certified,'certified answers; append/domain/cap boundaries')
