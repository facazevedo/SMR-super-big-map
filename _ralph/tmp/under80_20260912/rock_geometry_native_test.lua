local function read(path)local f=assert(io.open(path,'r'));local s=f:read('*a');f:close();return s end
local source=read('_ralph/tmp/under80_20260912/rock_geometry_native.lua')
local checks=0
local function check(v,m)assert(v,m);checks=checks+1 end
for _,mode in ipairs({'normal','lua_point','lua_box','lua_predicate','lua_getter','missing_dump','bad_lua_control','bad_c_control','constructor_error'})do
 local native={}
 local function primitive(fn)native[fn]=true;return fn end
 local methods={}
 for _,name in ipairs({'maxz','minz','minx','miny','sizex','sizey','x','y','z'})do methods[name]=primitive(function()return 1 end)end
 local function value(kind)return setmetatable({kind=kind},{__index=methods})end
 local env=setmetatable({}, {__index=_G});env._G=env
 env.point=primitive(function()if mode=='constructor_error'then error('constructor')end;return value('point')end)
 env.box=primitive(function()return value('box')end)
 env.IsPoint=primitive(function(v)return type(v)=='table' and v.kind=='point' end)
 env.IsBox=primitive(function(v)return type(v)=='table' and v.kind=='box' end)
 if mode=='lua_point'then native[env.point]=nil end
 if mode=='lua_box'then native[env.box]=nil end
 if mode=='lua_predicate'then native[env.IsPoint]=nil end
 if mode=='lua_getter'then native[methods.minx]=nil end
 env.string={dump=function(fn)
  if mode=='bad_lua_control'then error('native')end
  if native[fn] or fn==pcall then
   if mode=='bad_c_control'then return 'dumped C' end
   error('native',0)
  end
  return string.dump(fn)
 end}
 if mode=='missing_dump'then env.string.dump=nil end
 local Engine={Global=function(name)return rawget(env,name)end}
 local factory=assert(load(source,'actual qualification','t',env))()
 local geometry=factory(Engine)
 if mode=='normal'then
  check(geometry.enabled and geometry.Qualify(value('box'),value('point')),'native pair admitted')
  check(not geometry.Qualify({},value('point')) and not geometry.Qualify(value('box'),{}),'custom values refused')
  local original=Engine.Global;Engine.Global=function()return true end
  check(not geometry.Qualify(value('box'),value('point')),'rebound global helper')
  Engine.Global=original
  local predicate=env.IsPoint;env.IsPoint=function()return true end
  check(not geometry.Qualify(value('box'),value('point')),'rebound native predicate')
  env.IsPoint=predicate
  check(geometry.Qualify(value('box'),value('point')),'restored identities')
 else check(not geometry.enabled and not geometry.Qualify(value('box'),value('point')),mode..' fallback')end
end
print('PASS '..checks..' native qualification controls and fallback checks')
