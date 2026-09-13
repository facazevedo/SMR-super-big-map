-- Actual source, real shadow setup/lifecycle, fixture-native geometry identities.
local function read(path)local f=assert(io.open(path,'r'));local s=f:read('*a');f:close();return s end
local source=read('_ralph/tmp/under80_20260912/rock_geometry_census_test.lua')
local function replace(old,new)
 local a,b=source:find(old,1,true);assert(a,'fixture anchor '..old)
 assert(not source:find(old,b+1,true),'duplicate fixture anchor')
 source=source:sub(1,a-1)..new..source:sub(b+1)
end
replace("local setup=read('_ralph/tmp/under80_20260912/rock_geometry_census.lua')",[[
local setup=read('_ralph/tmp/under80_20260912/rock_geometry_shadow.lua')
setup=setup:gsub('local geometry=factory%(%)%(sbm.Engine%)','local geometry=env.fixture_geometry;geometry.enabled=true')
]])
replace('local function event(...)events[#events+1]=serialize(table.pack(...))end',[[
 local function event(label,...)
  if label:find('bounds.',1,true)==1 or label:find('point.',1,true)==1 then return end
  events[#events+1]=serialize(table.pack(label,...))
 end
]])
replace(' local env=setmetatable({SuperBigMap=sbm},{__index=_G});env._G=env',[[
 local geometry={Qualify=function()return true end}
 local env=setmetatable({SuperBigMap=sbm,fixture_geometry=geometry},{__index=_G});env._G=env
]])
replace('harness.AsyncFileToString=function()', 'harness.AsyncFileToString=function(path)')
replace("if mode=='bad_anchor'then return nil,production:gsub('bounds:minx%(%)','0')end",[[
 if mode=='bad_anchor' and path:find('candidate.lua',1,true)then return nil,'invalid Lua' end
]])
replace('return nil,production',"return nil,read(path:gsub('^D:/PROJS/SMR/super%-big%-map/',''))")
replace('harness.SBM_ROCK_GEOMETRY_CENSUS','harness.SBM_ROCK_GEOMETRY_SHADOW')
replace("result.status=='ready' and result.joined_cells>0 and result.source_substitutions==15", "result.status=='ready' and result.candidate_joined>0 and result.native_qualified")
replace(' local obj={}',[[
 for _,name in ipairs({'maxz','minz','minx','miny','sizex','sizey'})do geometry['bounds_'..name]=bounds[name]end
 for _,name in ipairs({'x','y','z'})do geometry['visual_'..name]=visual[name]end
 local obj={}
]])
local a=source:find("  check((result.peak_roles",1,true)
local b=source:find('\n end\n local stats=',a,true);assert(a and b)
source=source:sub(1,a-1)..[[
  check(result.calls[1].peak_events<=1024,'bounded replay')
  if mode=='normal'then check(result.calls[1].records==1 and result.calls[1].mismatches==0 and result.calls[1].qualified==1,'actual shadow record proof')end
]]..source:sub(b)
replace("'normal','flat','short','ineligible','invalid_z','no_hit','changed_value','subtype','rebound_method','nil_tuple',", "'normal','flat','short','ineligible','invalid_z','no_hit',")
replace("' actual-source geometry census checks'","' actual-source native-shadow fixture checks'")
assert(load(source,'extended native shadow fixture','t',_G))()
