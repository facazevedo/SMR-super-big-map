-- PRIVATE kernel. Caller certifies the fixed source and complete live-place
-- mutation stream. Returns diagnostic success, never impersonates native tuples.
return function(api,source,place,capacity)
 if type(api)~='table' or source==nil or place==nil or source==place
  or type(capacity)~='number' or capacity%1~=0 or capacity<0 or capacity>32 then return nil,'invalid prerequisites' end
 for _,name in ipairs({'mask','intersect','clear','clone','copy','free'})do
  if type(api[name])~='function'then return nil,'missing '..name end
 end
 local entries={};local clock=0;local failure;local closed=false
 local stats={calls=0,hits=0,misses=0,masks=0,intersections=0,copies=0,clones=0,
  clears=0,updates=0,evictions=0,live=0,peak=0,freed=0,capacity=capacity}
 local function fail(why)failure=failure or tostring(why);return false,failure end
 local function integer(v)return type(v)=='number' and math.type(v)=='integer' end
 local function owned(grid)for _,entry in ipairs(entries)do if entry.grid==grid then return true end end end
 local function release(index)
  local ok,why=pcall(api.free,entries[index].grid)
  if not ok then return fail('free: '..tostring(why))end
  table.remove(entries,index);stats.live=stats.live-1;stats.freed=stats.freed+1
  return true
 end
 local cache={stats=stats}
 function cache.invalidate(why)return fail('source/mutation contract: '..tostring(why))end
 function cache.apply(destination,from,to,scale)
  if failure then return false,failure end
  if closed then return false,'cache closed' end
  if destination==nil or destination==source or destination==place or owned(destination)
   or not integer(from) or not integer(to) or not integer(scale) or scale~=1 then return fail('invalid certified request')end
  clock=clock+1;stats.calls=stats.calls+1
  for _,entry in ipairs(entries)do
   if entry.from==from and entry.to==to and entry.scale==scale then
    local ok,why=pcall(api.copy,destination,entry.grid)
    if not ok then return fail('copy: '..tostring(why))end
    entry.last=clock;stats.hits=stats.hits+1;stats.copies=stats.copies+1
    return true
   end
  end
  stats.misses=stats.misses+1
  local ok,why=pcall(api.mask,source,destination,from,to,scale)
  if not ok then return fail('mask: '..tostring(why))end
  stats.masks=stats.masks+1
  ok,why=pcall(api.intersect,destination,place)
  if not ok then return fail('intersect: '..tostring(why))end
  stats.intersections=stats.intersections+1
  if capacity==0 then return true end
  if #entries==capacity then
   local oldest=1
   for i=2,#entries do if entries[i].last<entries[oldest].last then oldest=i end end
   if not release(oldest)then return false,failure end
   stats.evictions=stats.evictions+1
  end
  local clone_ok,grid=pcall(api.clone,destination)
  if not clone_ok or (type(grid)~='table' and type(grid)~='userdata')then return fail('clone: '..tostring(grid))end
  if grid==source or grid==place or grid==destination or owned(grid)then return fail('aliased clone')end
  entries[#entries+1]={grid=grid,from=from,to=to,scale=scale,last=clock}
  stats.clones=stats.clones+1;stats.live=stats.live+1;stats.peak=math.max(stats.peak,stats.live)
  return true
 end
 -- Call AFTER the caller's actual live-place clear. Never clear a caller grid.
 function cache.clear(value,center,radius)
  if failure then return false,failure end
  if closed then return false,'cache closed' end
  if not integer(value) or value~=0 or center==nil or type(radius)~='number'
   or radius~=radius or radius<0 or radius==math.huge then return fail('unsupported circle mutation')end
  stats.clears=stats.clears+1
  for _,entry in ipairs(entries)do
   local ok,why=pcall(api.clear,entry.grid,value,center,radius)
   if not ok then return fail('clear: '..tostring(why))end
   stats.updates=stats.updates+1
  end
  return true
 end
 function cache.close()
  for i=#entries,1,-1 do release(i)end
  closed=#entries==0
  if not closed then return fail('cleanup incomplete')end
  return not failure,failure
 end
 return cache
end
