-- Release builds: vanilla DoGenerate deletes PrefabObj helpers unless Platform.debug and
-- Platform.desktop. Expansion generations must reproduce the debug branch (markers kept,
-- gofPermanent cleared) that the decor top-ups and all harness evidence depend on.
local f=assert(io.open('Code/sbm_map_generation.lua','rb'));local source=f:read('*a');f:close()
local block=assert(source:match('(\tlocal function CallDoGenerateKeepingPrefabMarkers.-\n\tend\n)'),'helper not found')
local PERMANENT=4
local function fixture(debug_build)
  local classes={PrefabObj={},PrefabMarker={},PrefabDecorMarker={},PrefabFeature={leave_on_map=true}}
  local objects={}
  local function object(class)
    local o=setmetatable({class=class,flags=PERMANENT|1,done=false},{__index=classes[class]})
    function o:ClearGameFlags(flag) self.flags=self.flags&~flag end
    objects[#objects+1]=o;return o
  end
  local map={}
  function map:MapForEach(scope,class,fn) for _,o in ipairs(objects) do if not o.done then fn(o) end end end
  local globals={Platform={debug=debug_build,desktop=true},g_Classes=classes,const={gofPermanent=PERMANENT},
    ClassDescendantsList=function(name) assert(name=='PrefabObj');return {'PrefabMarker','PrefabDecorMarker','PrefabFeature'} end}
  local env=setmetatable({Global=function(n)return globals[n]end,PackValues=function(...)return {n=select('#',...),...}end},{__index=_G})
  local fn=assert(load(block..'\nreturn CallDoGenerateKeepingPrefabMarkers','marker helper','t',env))()
  -- Vanilla's end-of-generation cleanup, with its own debug switch.
  local function vanilla(generator,m,fail)
    for _,o in ipairs(objects) do
      if o.leave_on_map then
      elseif debug_build then o:ClearGameFlags(PERMANENT)
      else o.done=true end
    end
    if fail then error('vanilla failed') end
    return 'generated',42
  end
  return fn,map,classes,object,vanilla,objects
end

-- Release: markers survive with gofPermanent cleared; real leave_on_map helpers untouched.
do
  local fn,map,classes,object,vanilla=fixture(false)
  local marker,decor,feature=object('PrefabMarker'),object('PrefabDecorMarker'),object('PrefabFeature')
  local a,b=fn(map,function(...) return vanilla(...) end,'generator',map)
  assert(a=='generated' and b==42,'results not returned')
  assert(not marker.done and not decor.done,'release deleted the markers the decor top-up needs')
  assert(marker.flags==1 and decor.flags==1,'kept markers must lose gofPermanent like the debug branch')
  assert(feature.flags==PERMANENT|1,'real leave_on_map helper must keep its stock flags')
  for name,class in pairs(classes) do
    if name~='PrefabFeature' then assert(rawget(class,'leave_on_map')==nil,'class flag leaked: '..name) end
  end
  assert(classes.PrefabFeature.leave_on_map==true)
end
-- Release error path: class flags restored and the error propagates.
do
  local fn,map,classes,object,vanilla=fixture(false)
  object('PrefabMarker')
  local ok,err=pcall(fn,map,function(...) return vanilla(...) end,'generator',map,true)
  assert(not ok and tostring(err):find('vanilla failed'),'error was swallowed')
  assert(rawget(classes.PrefabMarker,'leave_on_map')==nil and rawget(classes.PrefabObj,'leave_on_map')==nil,'class flags leaked after error')
end
-- Debug build: untouched pass-through (vanilla's own debug branch already keeps them).
do
  local fn,map,classes,object,vanilla=fixture(true)
  local marker=object('PrefabMarker')
  local touched=false
  setmetatable(classes.PrefabMarker,{__newindex=function(t,k,v) touched=true;rawset(t,k,v) end})
  fn(map,function(...) return vanilla(...) end,'generator',map)
  assert(not touched,'debug build must not change class fields')
  assert(not marker.done and marker.flags==1)
end
print('release prefab markers: kept with gofPermanent cleared like the debug branch; flags restored; debug untouched')
