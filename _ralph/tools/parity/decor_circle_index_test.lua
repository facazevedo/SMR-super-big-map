-- Production spatial query versus the previous exhaustive predicate, including
-- strict tangency, negative/fractional coordinates, wide circles and live appends.
local file=assert(io.open('Code/sbm_decor_topup.lua','rb'))
local source=file:read('*a'):gsub('\r\n','\n');file:close()
local helper=assert(source:match('(local function circle_hits%(.-)\nend'))..'\nend'
local current=assert(load(helper..'\nreturn circle_hits','production circles'))()
local function previous(list,x,y,radius)
  for i=1,#list do
    local c=list[i]
    local dx,dy=x-c.x,y-c.y
    local reach=radius+c.r
    if dx*dx+dy*dy<reach*reach then return true end
  end
  return false
end
local checks=0
local function check(list,x,y,r)
  assert(current(list,x,y,r)==previous(list,x,y,r),
    ('circle query differs at %.17g,%.17g radius %.17g'):format(x,y,r))
  checks=checks+1
end
for _,center in ipairs({-32768,-16384,-0.5,0,0.5,16384,32768}) do
  local list={{x=center,y=center,r=8192}}
  for _,delta in ipairs({-0.001,0,0.001}) do
    for _,r in ipairs({0,1,8192,32768}) do
      check(list,center+8192+r+delta,center,r)
      check(list,center,center-8192-r+delta,r)
    end
  end
end
local state=71
local function rand(n) state=(state*16807)%2147483647;return state%n end
local list={}
check(list,0,0,10)
for batch=1,12 do
  for i=1,80 do
    list[#list+1]={x=rand(1600000)-800000+0.25,y=rand(1600000)-800000-0.25,r=rand(90000)}
  end
  for i=1,4000 do check(list,rand(1800000)-900000,rand(1800000)-900000,rand(60000)) end
end
local a,b={},{}
check(a,17,29,1); check(b,17,29,1)
a[#a+1]={x=17,y=29,r=1}
assert(current(a,17,29,1) and not current(b,17,29,1),'index lifetime or append invalidation')
assert(#list==960 and list[1].x and list[960].x,'array census changed')
print('PASS '..checks..' exact production circle queries, tangencies, live appends and isolated passes')
