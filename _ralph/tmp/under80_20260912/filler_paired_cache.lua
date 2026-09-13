-- PRIVATE paired API-boundary prototype. Caller certifies fixed source, live
-- place lineage and complete clears. Success flags are NOT native return tuples.
return function(api,source,place,capacity)
 if type(api)~='table' or source==nil or place==nil or source==place
  or type(capacity)~='number' or capacity%1~=0 or capacity<0 or capacity>32 then return nil,'invalid prerequisites' end
 for _,name in ipairs({'mask','intersect','clear','clone','copy','free'})do
  if type(api[name])~='function'then return nil,'missing '..name end
 end
 local entries={};local clock=0;local failure;local closed=false;local pending
 local stats={mask_calls=0,and_calls=0,hits=0,misses=0,masks=0,intersections=0,
  mask_copies=0,and_copies=0,clones=0,clears=0,updates=0,evictions=0,live=0,peak=0,freed=0,capacity=capacity}
 local function fail(why)failure=failure or tostring(why);return false,failure end
 local function integer(v)return type(v)=='number' and math.type(v)=='integer' end
 local function owned(grid)
  for _,entry in ipairs(entries)do if entry.raw==grid or entry.eligible==grid then return true end end
 end
 local function release(index)
  local entry=entries[index]
  for _,role in ipairs({'eligible','raw'})do
   if entry[role]then
    local ok,why=pcall(api.free,entry[role])
    if ok then entry[role]=nil;stats.live=stats.live-1;stats.freed=stats.freed+1
    else fail('free: '..tostring(why))end
   end
  end
  if not entry.raw and not entry.eligible then table.remove(entries,index);return true end
  return false
 end
 local function clone(destination)
  local ok,grid=pcall(api.clone,destination)
  if not ok or (type(grid)~='table' and type(grid)~='userdata')then fail('clone: '..tostring(grid));return end
  if grid==source or grid==place or grid==destination or owned(grid)then fail('aliased clone');return end
  stats.clones=stats.clones+1;stats.live=stats.live+1;stats.peak=math.max(stats.peak,stats.live)
  return grid
 end
 local cache={stats=stats}
 function cache.invalidate(why)return fail('source/mutation contract: '..tostring(why))end
 function cache.mask(destination,from,to,scale)
  if failure then return false,failure end
  if closed then return false,'cache closed' end
  if pending or destination==nil or destination==source or destination==place or owned(destination)
   or not integer(from) or not integer(to) or not integer(scale) or scale~=1 then return fail('invalid mask request/pair')end
  clock=clock+1;stats.mask_calls=stats.mask_calls+1
  local entry
  for _,candidate in ipairs(entries)do
   if candidate.from==from and candidate.to==to and candidate.scale==scale then entry=candidate;break end
  end
  if entry then
   local ok,why=pcall(api.copy,destination,entry.raw)
   if not ok then return fail('raw copy: '..tostring(why))end
   stats.hits=stats.hits+1;stats.mask_copies=stats.mask_copies+1;entry.last=clock
  else
   stats.misses=stats.misses+1
   local ok,why=pcall(api.mask,source,destination,from,to,scale)
   if not ok then return fail('mask: '..tostring(why))end
   stats.masks=stats.masks+1
   if capacity>0 then
    if #entries==capacity then
     local oldest=1;for i=2,#entries do if entries[i].last<entries[oldest].last then oldest=i end end
     if not release(oldest)then return false,failure end
     stats.evictions=stats.evictions+1
    end
    local raw=clone(destination);if not raw then return false,failure end
    entry={raw=raw,from=from,to=to,scale=scale,last=clock};entries[#entries+1]=entry
   end
  end
  pending={destination=destination,entry=entry}
  return true
 end
 function cache.intersect(destination,other)
  if failure then return false,failure end
  if closed then return false,'cache closed' end
  if not pending or pending.destination~=destination or other~=place then return fail('invalid And pair')end
  local entry=pending.entry
  stats.and_calls=stats.and_calls+1
  if entry and entry.eligible then
   local ok,why=pcall(api.copy,destination,entry.eligible)
   if not ok then return fail('eligible copy: '..tostring(why))end
   stats.and_copies=stats.and_copies+1
  else
   local ok,why=pcall(api.intersect,destination,place)
   if not ok then return fail('intersect: '..tostring(why))end
   stats.intersections=stats.intersections+1
   if entry then
    local eligible=clone(destination);if not eligible then return false,failure end
    entry.eligible=eligible
   end
  end
  pending=nil;return true
 end
 -- Every live place clear is forwarded here AFTER the caller's actual write.
 -- Raw masks never change. A pending first And initializes from current place.
 function cache.clear(value,center,radius)
  if failure then return false,failure end
  if closed then return false,'cache closed' end
  if not integer(value) or value~=0 or center==nil or type(radius)~='number'
   or radius~=radius or radius<0 or radius==math.huge then return fail('unsupported circle mutation')end
  stats.clears=stats.clears+1
  for _,entry in ipairs(entries)do if entry.eligible then
   local ok,why=pcall(api.clear,entry.eligible,value,center,radius)
   if not ok then return fail('clear: '..tostring(why))end
   stats.updates=stats.updates+1
  end end
  return true
 end
 function cache.close()
  if pending then fail('incomplete pending pair');pending=nil end
  for i=#entries,1,-1 do release(i)end
  closed=#entries==0
  if not closed then return fail('cleanup incomplete')end
  return not failure,failure
 end
 return cache
end
