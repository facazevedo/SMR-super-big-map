-- Fresh diagnostic only: split coarse-mask work from native patch work and
-- count exact zero/core/transition samples. No module reload or changed outputs.
local result={status='setup',calls={}}
rawset(_G,'SBM_OUTER_COARSE_DIAGNOSTIC',result)
local env,sbm
for _,mod in ipairs(ModsLoaded or {})do
 local value=mod.env and rawget(mod.env,'SuperBigMap')
 if value and value.Config then env,sbm=mod.env,value;break end
end
local function fail(why)result.status='fail';result.error=why;error(why)end
if not sbm then fail('outer coarse mod missing');return end
local original=sbm.TerrainCopy.PrepareOuterResourceTerrain
local cells,names={},{}
for i=1,200 do
 local name=debug.getupvalue(original,i)
 if not name then break end
 cells[name]=i
 if name~='_ENV' then names[#names+1]=name end
end
local err,source=AsyncFileToString('D:/PROJS/SMR/super-big-map/Code/sbm_terrain_copy.lua')
if err or type(source)~='string' then fail('outer coarse source missing');return end
source=source:gsub('\r\n','\n')
local a=source:find('local function PrepareOuterResourceTerrain(',1,true)
local b=a and source:find('local function RebuildOuterResourceTerrainRegions(',a,true)
if not a or not b then fail('outer coarse function anchors');return end
source=source:sub(a,b-1)
local function once(anchor,replacement)
 local first,last=source:find(anchor,1,true)
 if not first or source:find(anchor,last+1,true)then fail('outer coarse ambiguous anchor '..anchor);return false end
 source=source:sub(1,first-1)..replacement..source:sub(last+1);return true
end
if not once('\tlocal function apply_native_patch(patch)\n',
 '\tlocal function apply_native_patch(patch)\n\t\tlocal probe_started=probe_clock()\n'
 ..'\t\tlocal probe={kind=patch.kind,zero_before=0,zero_after=0,ones=0,transitions=0,exterior=0}\n')then return end
if not once('\t\t\t\tlocal cached_zero_sine, cached_zero_harmonic\n',
 '\t\t\t\tlocal cached_zero_sine, cached_zero_harmonic\n'
 ..'\t\t\t\tlocal probe_coarse_started=probe_clock()\n'
 ..'\t\t\t\tprobe.pre_coarse_ms=probe_coarse_started-probe_started\n'
 ..'\t\t\t\tprobe.width,probe.height=coarse_width,coarse_height\n'
 ..'\t\t\t\tprobe.radius,probe.core,probe.guards=radius,patch.core_cells,#protection_blends\n'
 ..'\t\t\t\tprobe.atan2_present=math.atan2~=nil\n')then return end
if not once('\t\t\t\t\t\tfor _, protected in ipairs(protection_blends) do',
 '\t\t\t\t\t\tif weight==0 then probe.zero_before=probe.zero_before+1 end\n'
 ..'\t\t\t\t\t\tif distance>=radius then probe.exterior=probe.exterior+1 end\n'
 ..'\t\t\t\t\t\tfor _, protected in ipairs(protection_blends) do')then return end
if not once('\t\t\t\t\t\tcoarse:set(coarse_x, coarse_y,',
 '\t\t\t\t\t\tif weight==0 then probe.zero_after=probe.zero_after+1\n'
 ..'\t\t\t\t\t\telseif weight==1 then probe.ones=probe.ones+1\n'
 ..'\t\t\t\t\t\telse probe.transitions=probe.transitions+1 end\n'
 ..'\t\t\t\t\t\tcoarse:set(coarse_x, coarse_y,')then return end
if not once('\t\t\t\tsamples = coarse_width * coarse_height',
 '\t\t\t\tprobe.coarse_ms=probe_clock()-probe_coarse_started\n'
 ..'\t\t\t\tprobe.cached_harmonic=cached_zero_harmonic\n'
 ..'\t\t\t\tsamples = coarse_width * coarse_height')then return end
if not once('\t\t\treturn changed_cells, local_width * local_height, samples',
 '\t\t\tprobe.total_ms=probe_clock()-probe_started\n'
 ..'\t\t\tprobe.samples,probe.raster_cells=samples,local_width*local_height\n'
 ..'\t\t\tprobe_record(probe)\n'
 ..'\t\t\treturn changed_cells, local_width * local_height, samples')then return end
local active
local function record(row)
 if not active then fail('outer coarse patch outside call');return end
 active.patches[#active.patches+1]=row
end
local prefix='local probe_clock,probe_record=...\n'
if #names>0 then prefix=prefix..'local '..table.concat(names,',')..'\n'end
local chunk,why=load(prefix..source..'\nreturn PrepareOuterResourceTerrain','@outer-coarse-profile','t',env)
if not chunk then fail(tostring(why));return end
local candidate=chunk(GetPreciseTicks,record)
for i=1,200 do
 local name=debug.getupvalue(candidate,i)
 if not name then break end
 if cells[name]then debug.upvaluejoin(candidate,i,original,cells[name])
 elseif name~='probe_clock' and name~='probe_record'then fail('outer coarse unjoined cell '..name);return end
end
local unpack_values=table.unpack or unpack
local function pack(...)return {n=select('#',...),...}end
sbm.TerrainCopy.PrepareOuterResourceTerrain=function(map,...)
 if active then fail('recursive outer coarse call');return original(map,...)end
 active={patches={}}
 local row=active
 local started=GetPreciseTicks()
 local values=pack(candidate(map,...))
 row.elapsed_ms=GetPreciseTicks()-started
 row.first_return=tostring(values[1])
 row.report=values[2]
 active=nil
 result.calls[#result.calls+1]=row
 local total=0
 for _,patch in ipairs(row.patches)do
  if patch.zero_after+patch.ones+patch.transitions~=patch.samples then
   fail('coarse census mismatch');return unpack_values(values,1,values.n)
  end
  total=total+patch.samples
 end
 if type(row.report)~='table' or row.report.error~='' or #row.patches==0
  or total~=row.report.native_mask_samples then result.status='fail'
 elseif result.status~='fail'then result.status='pass'end
 return unpack_values(values,1,values.n)
end
sbm.Config.DEBUG_LOGGING_ENABLED=true
sbm.Config.DEBUG_LOADING_TIMINGS=true
result.status='ready'
return 'OUTER_COARSE_PROFILE_READY'
