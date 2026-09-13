-- Extend the actual-source census fixture without changing its accepted cases.
local function read(path)local f=assert(io.open(path,'r'));local s=f:read('*a');f:close();return s end
local source=read('_ralph/tmp/under80_20260912/rock_geometry_census_test.lua')
local function replace(old,new)
 local a,b=source:find(old,1,true);assert(a,'fixture anchor '..old)
 assert(not source:find(old,b+1,true),'duplicate fixture anchor')
 source=source:sub(1,a-1)..new..source:sub(b+1)
end
replace("local setup=read('_ralph/tmp/under80_20260912/rock_geometry_census.lua')",[[
local candidate=read('_ralph/runs/under80-20260912/artifacts/rock_geometry_candidate_2/candidate.lua')
]])
replace('local function event(...)events[#events+1]=serialize(table.pack(...))end',[[
 local geometry_calls=0
 local function event(label,...)
  if label:find('bounds.',1,true)==1 or label:find('point.',1,true)==1 then geometry_calls=geometry_calls+1;return end
  events[#events+1]=serialize(table.pack(label,...))
 end
]])
replace("local sbm={Config={},Engine={Global=function(name)return globals[name]end},",[[
 local geometry={Qualify=function()return mode~='changed_value' and mode~='subtype' and mode~='nil_tuple'
  and mode~='rebound_method' and mode~='getter_error' end}
 local sbm={Config={},Engine={Global=function(name)return globals[name]end},
]])
local a=source:find(' local harness=',1,true)
local b=source:find(' local map=',a,true)
assert(a and b)
source=source:sub(1,a-1)..[[
 if instrument then
  local cells,names={},{}
  for i=1,100 do
   local name=debug.getupvalue(original,i);if not name then break end
   cells[name]=i;if name~='_ENV'then names[#names+1]=name end
  end
  local chunk=assert(load('local NativeGeometry\nlocal '..table.concat(names,',')..'\n'..candidate..'\nreturn Capture','actual candidate','t',env))
  local replacement=chunk()
  for i=1,100 do
   local name=debug.getupvalue(replacement,i);if not name then break end
   if name=='NativeGeometry'then debug.setupvalue(replacement,i,geometry)
   else assert(cells[name]);debug.upvaluejoin(replacement,i,original,cells[name])end
  end
  sbm.RockGrounding.Capture=replacement
 end
]]..source:sub(b)
replace(' local obj={}',[[
 for _,name in ipairs({'maxz','minz','minx','miny','sizex','sizey'})do geometry['bounds_'..name]=bounds[name]end
 for _,name in ipairs({'x','y','z'})do geometry['visual_'..name]=visual[name]end
 local native_sizey=bounds.sizey
 local ray_count=0
 local obj={}
]])
replace("  event('ray',a:x(),a:y(),a:z(),b:x(),b:y(),b:z())",[[
  event('ray',a:x(),a:y(),a:z(),b:x(),b:y(),b:z())
  ray_count=ray_count+1
  if mode=='rebound_during_ray'then
   if ray_count==1 then bounds.sizey=function()event('bounds.sizey',12);return 12 end end
   if ray_count==2 then bounds.sizey=native_sizey end
  end
]])
replace("  if instrument then check(result.status=='fail' and result.restored,'getter failure cleanup')end",'')
a=source:find(' if instrument then\n  if mode==',1,true)
b=source:find(' local stats=',a,true);assert(a and b)
source=source:sub(1,a-1)..source:sub(b)
replace('return serialize(events),serialize(record),serialize(stats)','return serialize(events),serialize(record),serialize(stats),geometry_calls')
replace(" 'getter_error','final_error','final_false','rebound'})do"," 'getter_error','final_error','final_false','rebound','rebound_during_ray'})do")
replace('local a,b,c=run(mode,false)','local a,b,c,d=run(mode,false)')
replace('local x,y,z=run(mode,true)','local x,y,z,w=run(mode,true)')
replace(" check(c==z,mode..' exact capture counters')",[[
 check(c==z,mode..' exact capture counters')
 if mode=='normal' or mode=='rebound_during_ray'then check(w<d,mode..' native read reduction')end
 if mode=='changed_value' or mode=='subtype' or mode=='nil_tuple' or mode=='rebound_method' or mode=='getter_error'then
  check(w==d,mode..' original custom read calls')
 end
]])
replace("run('missing_source',true);run('bad_anchor',true)",'')
replace("' actual-source geometry census checks'","' actual-source scalar candidate checks'")
for _,extent in ipairs({10,12,16,24,36})do
 local scenario=source:gsub("local value=%(name=='minz' and %-5 or 10%)", "local value=(name=='minz' and -5 or "..extent..")")
 assert(load(scenario,'extended candidate fixture extent '..extent,'t',_G))()
end
