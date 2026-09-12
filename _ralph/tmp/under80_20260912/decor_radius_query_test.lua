local f=assert(io.open('Code/sbm_decor_topup.lua','rb'))
local source=f:read('*a'):gsub('\r\n','\n');f:close()
local body=assert(source:match('(local function circle_hits%(.-)\nend'))..'\nend'
local old=assert(load(body..'\nreturn circle_hits'))()
local candidate=dofile('_ralph/tmp/under80_20260912/decor_radius_query.lua')(old)
local checks=0
local function oracle(list,x,y,r)
    for i=1,#list do
        local c=list[i];local dx,dy=x-c.x,y-c.y;local reach=r+c.r
        if dx*dx+dy*dy<reach*reach then return true end
    end
    return false
end
local function check(list,x,y,r)
    local a,b,c=old(list,x,y,r),candidate(list,x,y,r),oracle(list,x,y,r)
    assert(a==b and b==c,('query differs %.17g %.17g %.17g'):format(x,y,r))
    checks=checks+1
end
for _,center in ipairs({-32768,-16384,-0.5,0,0.5,16384,32768})do
    local list={{x=center,y=center,r=8192}}
    for repeat_index=1,40 do
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
for _,r in ipairs({4095.999999,4096,4096.000001,65535.999999,65536,65536.000001})do
    for i=1,40 do check(list,rand(1600000)-800000,rand(1600000)-800000,r)end
end
for i=1,40 do check(a,17,29,1);check(b,17,29,1)end
a[#a+1]={x=17,y=29,r=1}
assert(candidate(a,17,29,1) and not candidate(b,17,29,1))
-- Coordinates outside the certified domain retain the accepted complete query.
local fallback={{x=67108865,y=0,r=1}}
for i=1,40 do assert(candidate(fallback,67108865,0,1)==old(fallback,67108865,0,1))end
local large={}
for i=1,40 do check(large,0,0,8192)end
large[1]={x=0,y=0,r=3000000}
check(large,0,0,8192)
assert(large.radius_spatial_indexes[8192].invalid,'cache storage bound not exercised')
print('PASS '..checks..' exhaustive/accepted/expanded-index comparisons; strict tangency, live appends and isolated lifetime')
