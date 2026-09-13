-- PRIVATE prototype, not production. Caller must certify source is immutable.
-- This does NOT impersonate GridMask's return tuple; it reports write success.
-- No fusion/deferred write: every successful apply fully writes destination.
return function(api,source,capacity)
 if type(api)~='table' or type(api.mask)~='function' or type(api.clone)~='function'
  or type(api.copy)~='function' or type(api.free)~='function' or source==nil
  or type(capacity)~='number' or capacity<0 or capacity>32 or capacity%1~=0 then
  return nil,'invalid private filler mask cache prerequisites'
 end
 local entries={};local clock=0;local closed=false;local failure
 local stats={calls=0,hits=0,misses=0,masks=0,copies=0,clones=0,evictions=0,
  live=0,peak=0,capacity=capacity,freed=0}
 local function fail(why)failure=failure or tostring(why);return false,failure end
 local function valid_number(v)return type(v)=='number' and v==v and v>-math.huge and v<math.huge end
 local function release(entry)
  -- Remove ownership only after the provided free operation succeeds.
  local ok,why=pcall(api.free,entry.grid)
  if not ok then return fail('cache free failed: '..tostring(why))end
  stats.live=stats.live-1;stats.freed=stats.freed+1
  return true
 end
 local cache={stats=stats}
 function cache.apply(destination,from,to,scale)
  if failure then return false,failure end
  if closed then return false,'cache closed' end
  if destination==nil or destination==source or not valid_number(from)
   or not valid_number(to) or not valid_number(scale)then return fail('invalid private mask request')end
  clock=clock+1;stats.calls=stats.calls+1
  for _,entry in ipairs(entries)do
   if entry.from==from and entry.to==to and entry.scale==scale then
    local ok,why=pcall(api.copy,destination,entry.grid)
    if not ok then return fail('cache copy failed: '..tostring(why))end
    entry.last=clock;stats.hits=stats.hits+1;stats.copies=stats.copies+1
    return true
   end
  end
  stats.misses=stats.misses+1;stats.masks=stats.masks+1
  local ok,why=pcall(api.mask,source,destination,from,to,scale)
  if not ok then return fail('native mask failed: '..tostring(why))end
  if capacity==0 then return true end
  if #entries==capacity then
   local oldest=1
   for i=2,#entries do if entries[i].last<entries[oldest].last then oldest=i end end
   if not release(entries[oldest])then return false,failure end
   table.remove(entries,oldest);stats.evictions=stats.evictions+1
  end
  local clone_ok,grid=pcall(api.clone,destination)
  if not clone_ok or (type(grid)~='table' and type(grid)~='userdata')then
   return fail('cache clone failed: '..tostring(grid))
  end
  if grid==destination or grid==source then return fail('cache clone aliased caller grid')end
  for _,entry in ipairs(entries)do if entry.grid==grid then return fail('cache clone aliased owned grid')end end
  entries[#entries+1]={grid=grid,from=from,to=to,scale=scale,last=clock}
  stats.clones=stats.clones+1;stats.live=stats.live+1;stats.peak=math.max(stats.peak,stats.live)
  return true
 end
 function cache.close()
  -- Failed frees retain their entries for explicit retry; never free caller grids.
  for i=#entries,1,-1 do if release(entries[i])then table.remove(entries,i)end end
  closed=#entries==0
  if not closed then return fail('cache cleanup incomplete')end
  return failure==nil,failure
 end
 return cache
end
