-- Execute the production bootstrap loop: provisional surface poses must not
-- delete native terrain objects. Authored underground clearance is unchanged.
local file=assert(io.open('Code/sbm_map_generation.lua','rb'))
local source=file:read('*a'):gsub('\r\n','\n');file:close()
local start=assert(source:find('\tlocal successful = {}\n\tmap:SuspendPassEdits("SuperBigMap_PassageBootstrap")',1,true))
local finish=assert(source:find('\n\tlocal resume_ok, resume_err = pcall(map.ResumePassEdits',start,true))
local body=source:sub(start,finish-1)..'\nassert(ok and err==true,err)\nreturn successful'
local helper_start=assert(source:find('function SuperBigMap.PrepareProvisionalSurfacePassageBuildable(',1,true))
local helper_end=assert(source:find('\nlocal function DeferredArtefactPreflight(',helper_start,true))
local helper=source:sub(helper_start,helper_end-1)..'\nreturn SuperBigMap.PrepareProvisionalSurfacePassageBuildable'

-- The helper retains nontrivial bridge writes and always finishes its mark.
for _,failure in ipairs({'none','mark','repair','finish','logged_mark'}) do
  local trace,grid={},{}
  local map={buildable={z_grid=grid},landscape_grid={},object_hex_grid={}}
  local landscape={mark=37,bbox='old',primes=4,grid=map.landscape_grid}
  local object={GetMap=function() return map end,GetPos=function() return 123 end,
    GetAngle=function() return 60 end}
  local shape={}
  local globals={guim=1000,
    LandscapeMarkCancel=function() trace[#trace+1]='cancel' end,
    LandscapeMarkStart=function(m,p) assert(m==map and p==123);trace[#trace+1]='start';return landscape end,
    Landscape_MarkShape=function(m,mark,s,p,a,lg,og)
      assert(m==map and mark==37 and s==shape and p==123 and a==60 and lg==map.landscape_grid and og==map.object_hex_grid)
      trace[#trace+1]='mark'
      if failure=='mark' then error('injected mark failure') end
      if failure=='logged_mark' then return nil end
      return 3,'new'
    end,
    Extend=function(a,b) assert(a=='old' and b=='new');return 'extended' end,
    buildUnbuildableZ=function() return 65535 end,
    Landscape_FixBuildable=function(l,lg,g,z,delta)
      assert(l==landscape and l.bbox=='extended' and l.primes==7 and lg==map.landscape_grid and g==grid and z==65535 and delta==1000/3)
      trace[#trace+1]='repair'
      if failure=='repair' then error('injected repair failure') end
      grid.repaired=true
    end,
    LandscapeFinish=function(mark)
      assert(mark==37);trace[#trace+1]='finish'
      if failure=='finish' then error('injected finish failure') end
    end,
  }
  local env=setmetatable({SuperBigMap={},Global=function(name) return assert(globals[name],name) end},{__index=_G})
  if failure=='logged_mark' then env.error=function() end end
  local fn=assert(load(helper,'production provisional buildable repair','t',env))()
  local ok,result=pcall(fn,object,shape)
  assert(trace[#trace]=='finish','landscape was not cleaned after '..failure)
  if failure=='none' then
    assert(ok and result==true and grid.repaired and table.concat(trace,',')=='cancel,start,mark,repair,finish')
  elseif failure=='logged_mark' then assert(ok and result==false and not grid.repaired)
  else assert(not ok,'injected '..failure..' was swallowed') end
end

-- Missing functions must be checked by name: nil-valued table entries disappear.
local preflight_end=assert(source:find('\n-- Vanilla selects a wonder',helper_end,true))
local preflight_body=source:sub(helper_end,preflight_end-1)..'\nreturn DeferredArtefactPreflight'
for _,missing in ipairs({'none','LandscapeMarkCancel','LandscapeMarkStart','Landscape_MarkShape',
    'Landscape_FixBuildable','LandscapeFinish','Extend','guim'}) do
  local env=setmetatable({Global=function(name)
    if name==missing then return nil end
    if name=='guim' then return 1000 end
    return function() end
  end},{__index=_G})
  local preflight=assert(load(preflight_body,'production preflight','t',env))()
  local ok,reason=preflight({MapGet=function() end,SuspendPassEdits=function() end,
    ResumePassEdits=function() end,buildable={GetZ=function() end}})
  assert(ok==(missing=='none') and (ok or reason:find(missing,1,true)))
end

for _,positions in ipairs({{100,200},{-400,700},{10000,-20000}}) do
  local surface={name='surface'}
  local underground={name='underground',buildable={GetZ=function() return 1000 end},
    SuspendPassEdits=function() end}
  local search_calls, surface_clears, underground_clears, recorded, repairs=0,0,0,0,0
  local native_objects={alive=true}
  local function object(map,x)
    return {map=map,x=x,GetPos=function(self) return self.x end,
      GetAngle=function() return 0 end,IsValidPlacement=function() return true end,
      Link=function(self,other) self.other=other;other.other=self end}
  end
  local markers={object(underground,11),object(underground,22)}
  local env=setmetatable({map=underground,surface_map=surface,passage_markers=markers,
    desired_passages=2,const_tbl={RandomMap={UndergroundPassagesMinDistance=1000}},
    unbuildable_z=65535,world_to_hex=function() return 0,0 end,
    get_shape=function(name) assert(name=='Elevator');return {} end,
    spawn_surface_anchor=function(map,pos,angle,min_dist,previous)
      search_calls=search_calls+1
      assert(map==surface and #previous==search_calls-1 and min_dist==1000)
      assert(repairs==search_calls-1,'next search lost its preceding bridge repair')
      return object(surface,positions[search_calls]),{}
    end,
    ArtefactSpawnMarkerBuilding=function(marker,class,map)
      assert(class=='SurfacePassage' and map==underground)
      return object(underground,marker.x)
    end,
    ArtefactClearObstructions=function(anchor)
      if anchor.map==surface then
        surface_clears=surface_clears+1;native_objects.alive=false
      else underground_clears=underground_clears+1 end
    end,
    SuperBigMap={Provenance={RecordNativeSpawn=function() recorded=recorded+1 end},
      PrepareProvisionalSurfacePassageBuildable=function(anchor,shape)
        assert(anchor.map==surface and type(shape)=='table');repairs=repairs+1;return true
      end},
    SafeCall=function(fn,...) return fn(...) end,
    done_object=function(marker) marker.deleted=true end,
  },{__index=_G})
  local successful=assert(load(body,'production passage bootstrap loop','t',env))()
  assert(#successful==2 and search_calls==2 and recorded==4,'native spawn/provenance sequence changed')
  assert(underground_clears==2,'authored underground clearance changed')
  assert(repairs==2,'source buildable bridge no longer repaired')
  assert(surface_clears==0 and native_objects.alive,
    'provisional surface passage cleanup still deletes native objects')

  -- Use the production loop through the OUTER failure return. A logging-only
  -- error cannot let a failed repair reach alignment or completion publication.
  local transaction_end=assert(source:find('\n\t-- Stock actual wonders remain live',finish,true))
  local failure_body=source:sub(start,transaction_end-1)..'\nerror("escaped failure boundary")\nreturn true'
  local restored,resumed=0,0
  env.error=function() end
  env.native_wonders={}
  env.passage_markers={object(underground,11),object(underground,22)}
  env.RestoreSurfaceBuildableBridge=function() restored=restored+1 end
  underground.ResumePassEdits=function() resumed=resumed+1 end
  env.SuperBigMap.PrepareProvisionalSurfacePassageBuildable=function() return false end
  search_calls,repairs=0,0
  local placed_before=underground_clears
  local result,reason=assert(load(failure_body,'production failure boundary','t',env))()
  assert(result==false and reason:find('buildable repair did not complete',1,true))
  assert(search_calls==1 and underground_clears==placed_before and restored==1 and resumed==1)
end

-- The generation wrapper must report failure and never run stock clearance as
-- a fallback, including when error() logs without throwing.
local guard_start=assert(source:find('\t\t\t\t\t\t\tif bootstrap_ok ~= true then',1,true))
local guard_end=assert(source:find('\n\t\t\t\t\t\t\treturn details',guard_start,true))
for _,results in ipairs({{true,false,'repair failed'},{false,'injected exception'}}) do
  local map={SuperBigMapPassageBootstrapComplete=true}
  local state={}
  local env=setmetatable({bootstrap_ok=false,bootstrap_results=results,details=results[3],
    map=map,SuperBigMap={State=state},error=function() end},{__index=_G})
  assert(assert(load(source:sub(guard_start,guard_end-1),'production no-fallback guard','t',env))()==false)
  assert(map.SuperBigMapPassageBootstrapComplete==false and #state.optimization_failures==1)
end
print('PASS production bootstrap: 3 provisional-position pairs preserve native surface objects and authored underground clearance')
