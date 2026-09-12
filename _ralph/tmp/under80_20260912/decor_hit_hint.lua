-- Nondeployed candidate: a private last-hit hint, never a cached negative answer.
return function(old)
local function indexed_hit(list, x, y, radius)
	-- These circles are private to one Run and only appended after a stamp.
	-- Index their full bounding boxes; the original strict circle predicate still
	-- decides every possible hit. No candidate, rejection precedence or draw changes.
	local index = list.spatial_index
	if not index then
		index = { rows = {}, count = 0, serial = 0, seen = {} }
		list.spatial_index = index
	end
	local floor, cell = math.floor, 16384
	for i = index.count + 1, #list do
		local c = list[i]
		for bx = floor((c.x - c.r + 0.0) / cell), floor((c.x + c.r + 0.0) / cell) do
			local row = index.rows[bx]
			if not row then row = {}; index.rows[bx] = row end
			for by = floor((c.y - c.r + 0.0) / cell), floor((c.y + c.r + 0.0) / cell) do
				local bucket = row[by]
				if not bucket then bucket = {}; row[by] = bucket end
				bucket[#bucket + 1] = c
			end
		end
	end
	index.count, index.serial = #list, index.serial + 1
	local serial, seen = index.serial, index.seen
	local by0, by1 = floor((y - radius + 0.0) / cell), floor((y + radius + 0.0) / cell)
	for bx = floor((x - radius + 0.0) / cell), floor((x + radius + 0.0) / cell) do
		local row = index.rows[bx]
		if row then
			for by = by0, by1 do
				local bucket = row[by]
				for i = 1, bucket and #bucket or 0 do
					local c = bucket[i]
					if seen[c] ~= serial then
						seen[c] = serial
						local dx, dy = x - c.x, y - c.y
						local reach = radius + c.r
						if dx * dx + dy * dy < reach * reach then return true, c end
					end
				end
			end
		end
	end
	return false
end
local floor=math.floor
local LIMIT,CELL,SLOTS=67108864,4096,32768
local function cacheable(c)
 return c.x>=-LIMIT and c.x<=LIMIT and c.y>=-LIMIT and c.y<=LIMIT and c.r>=0 and c.r<=LIMIT
end
return function(list,x,y,radius)
 local cache=list.hit_hint_cache
 if not cache then
  cache={rows={},queries=0,hits=0,tests=0,index_queries=0,slots=0}
  list.hit_hint_cache=cache
 end
 cache.queries=cache.queries+1
 if cache.queries<=32 or not(x>=-LIMIT and x<=LIMIT and y>=-LIMIT and y<=LIMIT and radius>=0 and radius<=65536) then
  return old(list,x,y,radius)
 end
 local bx,by=floor((x+0.0)/CELL),floor((y+0.0)/CELL)
 local row=cache.rows[bx]
 local hint=row and row[by]
 if hint then
  cache.tests=cache.tests+1
  local dx,dy=x-hint.x,y-hint.y
  local reach=radius+hint.r
  -- Keep the exact predicate, plus a conservative one-unit interior margin.
  -- The margin proves bounding-box overlap despite double-rounding at cell edges.
  local distance2=dx*dx+dy*dy
  if distance2<reach*reach and reach>1 and distance2<(reach-1)*(reach-1) then
   cache.hits=cache.hits+1
   return true
  end
 end
 cache.index_queries=cache.index_queries+1
 local hit,c=indexed_hit(list,x,y,radius)
 if hit and c~=hint and cacheable(c) and (hint or cache.slots<SLOTS) then
  if not row then row={};cache.rows[bx]=row end
  if not hint then cache.slots=cache.slots+1 end
  row[by]=c
 end
 return hit
end
end
