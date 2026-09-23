local f=assert(io.open('Code/sbm_map_generation.lua','rb'));local s=f:read('*a');f:close()
local first=assert(s:find('\tlocal copy_ok, copy_error = pcall(function()',s:find('local function BootstrapPassagesAndDeferWonders',1,true),true))
local last=assert(s:find('\n\tif type(resume_ild)',first,true))
local body=s:sub(first,last-1)..'\nreturn copy_ok,copy_error'
local function grid(w,h,fill)
 local g={w=w,h=h,cells={}}
 for i=1,w*h do g.cells[i]=fill end
 function g:get(x,y)return self.cells[1+y*self.w+x] end
 function g:copyrect(src,b,p)
  assert(b[1]==0 and b[2]==0 and p[1]==0 and p[2]==0)
  assert(b[3]==src.w and b[4]==src.h and src.w<=self.w and src.h<=self.h)
  for y=0,b[4]-1 do for x=0,b[3]-1 do self.cells[1+y*self.w+x]=src:get(x,y) end end
 end
 return g
end
math.randomseed(395)
local cells=0
for trial=1,600 do
 local w,h=1+trial%51,1+trial%43
 local src,dst=grid(w,h,0),grid(w+7,h+9,65535)
 for i=1,#src.cells do src.cells[i]=math.random(0,65535) end
 local env=setmetatable({padded_surface_grid=dst,pending_surface_buildable={grid=src},source_hex_w=w,source_hex_h=h,
  Global=function()return function(...)return {...}end end},{__index=_G})
 local run=assert(load(body,'production native copy','t',env))
 local ok,result=run();assert(ok and result==true)
 for y=0,dst.h-1 do for x=0,dst.w-1 do
  assert(dst:get(x,y)==((x<w and y<h) and src:get(x,y) or 65535));cells=cells+1
 end end
 dst.copyrect=false
 assert(not run(),'missing native operation must fail, not silently fall back')
 dst.copyrect=function()error('injected native failure')end
 assert(not run(),'native copy failure was accepted')
end
assert(s:find('if not copy_ok or copy_error ~= true then',first,true),'copy failure not propagated')
print('buildable bridge: '..cells..' exact U16/padding cells, missing API and native failure propagation')
