local file=assert(io.open('Code/sbm_decoration_seating.lua','rb'));local code=file:read('*a');file:close()
local body=assert(code:match('(local height_cache=entry%.foundation.-)\n\t\tlocal function flat_height'))
local reads=0;local delta=0
local function build(width,height,foundation)
 local env=setmetatable({width=width,height=height,entry={foundation=foundation},map={},
  point_fn=function(x,y)
   x,y=math.floor(x+.5),math.floor(y+.5)
   return {xy=function()return x,y end}
  end,
  terrain={GetHeight=function(_,p)reads=reads+1;local x,y=p:xy();return x*10000+y+delta end}}, {__index=_G})
 return assert(load(body..'\nreturn height_at','production terrain cache','t',env))()
end
local at=build(100,100,true)
assert(at(10,20)==100020 and at(10,20)==100020 and reads==1)
assert(at(10.25,20.25)==100020 and reads==1,'native-quantized coordinates did not reuse exact height')
assert(at(99.75,3)==1000003 and at(0,4)==4,'rounded map edge aliased the next row')
assert(at(5,99.75)==50100 and at(5,99.75)==50100,'rounded upper edge fallback failed')
assert(at(-.1,5)==nil and at(100,5)==nil)
for i=1,1000 do
 local x,y=(i*37)%999/10,(i*13)%999/10
 assert(at(x,y)==math.floor(x+.5)*10000+math.floor(y+.5),'height cache changed native coordinate conversion')
end
delta=17;local fresh=build(100,100,true)
assert(fresh(10,20)==100037,'a previous transaction leaked cached terrain')
reads=0;local uncached=build(100,100,false)
assert(uncached(10,20)==100037 and uncached(10,20)==100037 and reads==2)
local wide=build(67108865,100,true)
assert(wide(10,20)==100037 and wide(67108864.75,20)==671088650037,'unbounded dimensions lost row fallback')
print('seating height cache: exact native rounding, duplicate queries, map-edge alias guards and transaction isolation passed')
