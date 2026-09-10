local f=assert(io.open(arg[1] or 'Code/sbm_terrain_copy.lua','r'))
local source=f:read('*a');f:close()
local a=assert(source:find('local function CoalesceExactRectangles(',1,true),
    'production exact region coalescer missing')
local b=assert(source:find('-- EXACT_REGION_COALESCER_END',a,true))
local coalesce=assert(load(source:sub(a,b-1)..'\nreturn CoalesceExactRectangles'))()
local checks, seed = 0, 7431
local function check(ok, why) assert(ok, why); checks = checks + 1 end
local function draw(n) seed = seed * 48271 % 2147483647; return seed % n end
local function covered(rectangles,x,y)
    for _,b in ipairs(rectangles) do if x>=b.x0 and x<b.x1 and y>=b.y0 and y<b.y1 then return true end end
    return false
end
for trial = 1, 100 do
    local input, snapshot = {}, {}
    for i = 1, 20 do
        local x,y = draw(21)-10, draw(21)-10
        input[i] = {x0=x,y0=y,x1=x+draw(8)+1,y1=y+draw(8)+1}
        snapshot[i] = {x0=input[i].x0,y0=input[i].y0,x1=input[i].x1,y1=input[i].y1}
    end
    local output = coalesce(input)
    check(#output<=#input and #output>0,'nonempty and no call-count increase')
    for x=-10,18 do for y=-10,18 do
        check(covered(input,x,y)==covered(output,x,y),'exact half-open coverage')
    end end
    for i,b in ipairs(input) do for k,v in pairs(b) do check(snapshot[i][k]==v,'input certificate mutated') end end
end
local a={x0=0,y0=0,x1=10,y1=10};local inner={x0=2,y0=2,x1=5,y1=5}
check(#coalesce({a,a,inner})==1,'duplicate/containment not removed')
check(#coalesce({a,{x0=10,y0=0,x1=20,y1=10}})==1,'adjacent exact rectangle union not merged')
check(#coalesce({a,{x0=11,y0=0,x1=20,y1=10}})==2,'gap enlarged')
check(#coalesce({a,{x0=10,y0=5,x1=20,y1=15}})==2,'L-shaped union enlarged')
print('production exact rectangle coalescer: '..checks..' checks passed')
