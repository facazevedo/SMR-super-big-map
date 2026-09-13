-- Supported mod primitives only. No debug, getter mutation, or shared value cache.
return function(Engine)
 local global=Engine.Global
 local point_fn,box_fn=global('point'),global('box')
 local is_point,is_box=global('IsPoint'),global('IsBox')
 local string_api=global('string')
 local dump=type(string_api)=='table' and string_api.dump
 local geometry={enabled=false}
 local native_error
 if type(dump)=='function'then
  local a,b=pcall(dump,function()return true end)
  local c,d=pcall(dump,pcall)
  if a and type(b)=='string' and not c and type(d)=='string'then native_error=d end
 end
 local function native(fn)
  if type(fn)~='function' or not native_error then return false end
  local ok,value=pcall(dump,fn)
  return not ok and value==native_error
 end
 function geometry.Qualify(bounds,visual)
  return geometry.enabled and Engine.Global==global
   and rawget(_G,'IsPoint')==is_point and rawget(_G,'IsBox')==is_box
   and is_box(bounds) and is_point(visual)
 end
 if not(native(point_fn) and native(box_fn) and native(is_point) and native(is_box))then return geometry end
 local okp,point_value=pcall(point_fn,0,0,0)
 local okb,box_value=pcall(box_fn,0,0,0,1,1,1)
 if not okp or not okb or not is_point(point_value) or not is_box(box_value)then return geometry end
 for _,role in ipairs({{'bounds',box_value,{'maxz','minz','minx','miny','sizex','sizey'}},
  {'visual',point_value,{'z','x','y'}}})do
  for _,name in ipairs(role[3])do
   local fn=role[2][name]
   if not native(fn)then return geometry end
   geometry[role[1]..'_'..name]=fn
  end
 end
 geometry.enabled=true
 return geometry
end
