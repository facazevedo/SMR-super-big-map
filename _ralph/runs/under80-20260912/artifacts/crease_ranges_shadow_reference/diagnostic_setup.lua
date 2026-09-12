-- Isolated full native shadow. Accepted function writes the live grid; candidate
-- writes a clone. Compare all return records and every final U16 height sample.
local result={status='setup',calls={}}
rawset(_G,'SBM_CREASE_RANGES_DIAGNOSTIC',result)
local env,sbm
for _,mod in ipairs(ModsLoaded or {})do
 local value=mod.env and rawget(mod.env,'SuperBigMap')
 if value and value.Config then env,sbm=mod.env,value;break end
end
local function fail(why)result.status='fail';result.error=why;error(why)end
if not sbm then fail('crease ranges mod missing');return end
local function upvalue(fn,wanted)
 for i=1,200 do
  local name,value=debug.getupvalue(fn,i)
  if not name then break end
  if name==wanted then return value,i end
 end
end
local caller=sbm.TerrainCopy.StretchSourceToFull
local original,index=upvalue(caller,'RepairInternalHeightStep')
if type(original)~='function' then fail('crease ranges callsite missing');return end
local cells,names={},{}
for i=1,200 do
 local name=debug.getupvalue(original,i)
 if not name then break end
 cells[name]=i
 if name~='_ENV' then names[#names+1]=name end
end
local err,source=AsyncFileToString('D:/PROJS/SMR/super-big-map/_ralph/runs/under80-20260912/artifacts/crease_ranges_research/terrain_candidate.lua')
if err or type(source)~='string' then fail('crease ranges source missing');return end
source=source:gsub('\r\n','\n')
local a=source:find('local function RepairInternalHeightStep(',1,true)
local b=a and source:find('local function RepairQualifiedSourceHeightSteps(',a,true)
if not a or not b then fail('crease ranges source anchors');return end
source=source:sub(a,b-1)
local anchor='\tlocal function scan_line_range(row, axis, along, perp0, perp1, edge)\n'
a,b=source:find(anchor,1,true)
if not a or source:find(anchor,b+1,true)then fail('crease ranges counter anchor');return end
source=source:sub(1,b)..'\t\tcount_range(perp0,perp1)\n'..source:sub(b+1)
local active
local function count_range(first,last)
 if active then
  active.ranges=active.ranges+1
  active.positions=active.positions+last-first+1
 end
end
local prefix='local count_range=...\n'
if #names>0 then prefix=prefix..'local '..table.concat(names,',')..'\n'end
local chunk,why=load(prefix..source..'\nreturn RepairInternalHeightStep','@crease-ranges-shadow','t',env)
if not chunk then fail(tostring(why));return end
local candidate=chunk(count_range)
for i=1,200 do
 local name=debug.getupvalue(candidate,i)
 if not name then break end
 if cells[name]then debug.upvaluejoin(candidate,i,original,cells[name])
 elseif name~='count_range'then fail('crease ranges unjoined cell: '..name);return end
end
local function equal(a,b)
 if type(a)~=type(b)then return false end
 if type(a)~='table'then return a==b end
 for k,v in pairs(a)do if not equal(v,b[k])then return false end end
 for k in pairs(b)do if a[k]==nil then return false end end
 return true
end
local unpack_values=table.unpack or unpack
local function pack(...)return {n=select('#',...),...}end
local function wrapper(grid,wide)
 local copy=grid:clone()
 if not copy then fail('crease ranges clone failed');return original(grid,wide)end
 local row={wide_ring_only=wide,ranges=0,positions=0}
 local started=GetPreciseTicks()
 local before=pack(original(grid,wide))
 row.accepted_ms=GetPreciseTicks()-started
 active=row;started=GetPreciseTicks()
 local after=pack(candidate(copy,wide))
 row.candidate_ms=GetPreciseTicks()-started;active=nil
 row.records_equal=equal(before,after)
 local left=GridRepack(grid,'f',32,true)
 local right=GridRepack(copy,'f',32,true)
 if not left or not right then
  if left then left:free()end;if right then right:free()end;copy:free()
  fail('crease ranges comparison allocation');return unpack_values(before,1,before.n)
 end
 GridAddMulDiv(right,left,-1);GridAbs(right)
 row.height_differences=GridCount(right,1,2147483647)
 left:free();right:free();copy:free()
 row.original_singletons=before[4] and before[4].candidates or -1
 row.old_read_calls=row.original_singletons*(wide and 4 or 6)
 row.new_read_calls=row.positions+row.ranges*(wide and 3 or 5)
 row.pass=row.records_equal and row.height_differences==0
  and row.positions==row.original_singletons and row.new_read_calls<=row.old_read_calls
  and not(before[2] and before[2].error)
 result.calls[#result.calls+1]=row
 if not row.pass then result.status='fail'
 elseif result.status~='fail' and #result.calls>=2
  and row.new_read_calls<row.old_read_calls then result.status='pass'end
 return unpack_values(before,1,before.n)
end
if debug.setupvalue(caller,index,wrapper)~='RepairInternalHeightStep'then fail('crease ranges install');return end
sbm.Config.DEBUG_LOGGING_ENABLED=true
sbm.Config.DEBUG_LOADING_TIMINGS=true
result.status='ready'
return 'CREASE_RANGES_SHADOW_READY'
