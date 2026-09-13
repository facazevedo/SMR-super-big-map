-- Compare complete native coarse grids; only the accepted grid reaches terrain.
-- Clone just PrepareOuterResourceTerrain and join its original private cells.
local result={status='setup',calls={}}
rawset(_G,'SBM_OUTER_ENCLOSURE_SHADOW',result)
local env,sbm
for _,mod in ipairs(ModsLoaded or {}) do
 local value=mod.env and rawget(mod.env,'SuperBigMap')
 if value and value.Config then env,sbm=mod.env,value;break end
end
local function fail(why)result.status='fail';result.error=why;error(why)end
if not sbm then fail('mod missing');return end
local original=sbm.TerrainCopy.PrepareOuterResourceTerrain
local cells,names={},{}
for i=1,200 do
 local name=debug.getupvalue(original,i);if not name then break end
 cells[name]=i;if name~='_ENV' then names[#names+1]=name end
end
local function read(path)
 local err,s=AsyncFileToString(path)
 if err or type(s)~='string' then fail('missing source '..path);return end
 return s:gsub('\r\n','\n')
end
local accepted=read('D:/PROJS/SMR/super-big-map/Code/sbm_terrain_copy.lua')
local candidate_source=read('D:/PROJS/SMR/super-big-map/_ralph/runs/under80-20260912/artifacts/outer_enclosure_research/sbm_terrain_copy.lua')
if not accepted or not candidate_source then return end
local function coarse_block(s)
 local a=s:find('local function apply_native_patch',1,true)
 a=a and s:find('local coarse_width =',a,true)
 local b=a and s:find('mask = own(native_resample(coarse,',a,true)
 if not a or not b then fail('coarse anchors');return end
 return s:sub(a,b-1),a,b
end
local function compile(s)
 local block=coarse_block(s);if not block then return end
 local chunk,why=load('return function(_ENV) '..block..' return coarse,samples end','@outer-enclosure-coarse','t',env)
 if not chunk then fail(tostring(why));return end
 return chunk()
end
local old,new=compile(accepted),compile(candidate_source)
if not old or not new or type(GridFill)~='function' then fail('coarse compilation/API');return end
local active
local function compare(context)
 setmetatable(context,{__index=env})
 context.native_fill=GridFill
 local start=GetPreciseTicks()
 local a,na=old(context)
 local middle=GetPreciseTicks()
 local b,nb=new(context)
 local finished=GetPreciseTicks()
 local w=math.floor((context.local_width-1)/context.sample_step)+1
 local h=math.floor((context.local_height-1)/context.sample_step)+1
 local mismatch=0
 if na~=nb then fail('sample count changed') end
 for y=0,h-1 do for x=0,w-1 do
  if a:get(x,y)~=b:get(x,y) then mismatch=mismatch+1 end
 end end
 active.patches[#active.patches+1]={kind=context.patch.kind,samples=na,
  width=w,height=h,old_ms=middle-start,new_ms=finished-middle,mismatches=mismatch}
 if mismatch~=0 then fail('coarse grid mismatch '..tostring(mismatch)) end
 return a,na
end
local first=accepted:find('local function PrepareOuterResourceTerrain(',1,true)
local last=first and accepted:find('local function RebuildOuterResourceTerrainRegions(',first,true)
if not first or not last then fail('function anchors');return end
local source=accepted:sub(first,last-1)
local block,a,b=coarse_block(source)
if not block then return end
local replacement=[[local coarse
				coarse,samples=probe_compare({patch=patch,math=math,
				 local_width=local_width,local_height=local_height,sample_step=sample_step,
				 x0=x0,y0=y0,x1=x1,y1=y1,radius=radius,base_transition=base_transition,
				 transition_irregularity=transition_irregularity,maximum_width_scale=maximum_width_scale,
				 protection_blends=protection_blends,native_weight_scale=native_weight_scale,
				 native_new_grid=native_new_grid,own=own,ProtectedTerrainBlendWeight=ProtectedTerrainBlendWeight})
				]]
source=source:sub(1,a-1)..replacement..source:sub(b)
local prefix='local probe_compare=...\n'
if #names>0 then prefix=prefix..'local '..table.concat(names,',')..'\n' end
local chunk,why=load(prefix..source..'\nreturn PrepareOuterResourceTerrain','@outer-enclosure-shadow','t',env)
if not chunk then fail(tostring(why));return end
local candidate=chunk(compare)
for i=1,200 do
 local name=debug.getupvalue(candidate,i);if not name then break end
 if cells[name] then debug.upvaluejoin(candidate,i,original,cells[name])
 elseif name~='probe_compare' then fail('unjoined cell '..name);return end
end
local unpack_values=table.unpack or unpack
local function pack(...)return {n=select('#',...),...}end
sbm.TerrainCopy.PrepareOuterResourceTerrain=function(map,...)
 if active then fail('recursive preparation');return original(map,...) end
 active={patches={}};local row=active
 local values=pack(candidate(map,...))
 active=nil;result.calls[#result.calls+1]=row
 local total,mismatches=0,0
 for _,patch in ipairs(row.patches) do total=total+patch.samples;mismatches=mismatches+patch.mismatches end
 row.samples,row.mismatches=total,mismatches
 if type(values[2])~='table' or values[2].error~='' or #row.patches==0
  or total~=values[2].native_mask_samples or mismatches~=0 then result.status='fail'
 elseif result.status~='fail' then result.status='pass' end
 return unpack_values(values,1,values.n)
end
sbm.Config.DEBUG_LOGGING_ENABLED=true
sbm.Config.DEBUG_LOADING_TIMINGS=true
result.status='ready'
return 'OUTER_ENCLOSURE_SHADOW_READY'
