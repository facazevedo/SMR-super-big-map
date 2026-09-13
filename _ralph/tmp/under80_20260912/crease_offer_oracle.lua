-- Shared offline/native read-only oracle. Explicit error collection also works
-- when the engine's error/assert merely log instead of raising Lua exceptions.
return function(build,api)
 local checks,issues,primitive=0,{},{}
 local function check(ok,why)checks=checks+1;if not ok then issues[#issues+1]=why end end
 local function same(a,b)
  if type(a)~=type(b)then return false end
  if type(a)~='table'then return a==b end
  for k,v in pairs(a)do if not same(v,b[k])then return false end end
  for k in pairs(b)do if a[k]==nil then return false end end
  return true
 end
 -- Actual native copyrect must preserve signed f32, unlike the unsigned setter.
 for _,divisor in ipairs({1,8})do
  local from,to=api.NewComputeGrid(3,2,'f',32),api.NewComputeGrid(3,2,'f',32)
  if not from or not to then return checks,{'primitive allocation failed'} end
  for y=0,1 do for x=0,2 do from:set(x,y,65535-x-y)end end
  api.GridMulDivAdd(from,-1,divisor,0)
  to:copyrect(from,api.box(0,0,3,2),api.point(0,0))
  -- No signed/fractional get() assumption: bias and rescale stored values
  -- natively into exact small positive integers before checking their values.
  local rows={}
  for y=0,1 do for x=0,2 do
   local row={x=x,y=y,divisor=divisor,source_readback=from:get(x,y),copy_readback=to:get(x,y)}
   rows[#rows+1]=row;primitive[#primitive+1]=row
  end end
  api.GridMulDivAdd(to,1,1,65536/divisor)
  api.GridMulDivAdd(to,divisor,1,0)
  for _,row in ipairs(rows)do
   row.biased_copy=to:get(row.x,row.y)
   check(row.biased_copy==1+row.x+row.y,'signed/fractional f32 copy via positive native bias')
  end
  from:free();to:free()
 end
 for case=1,20 do
  local grid=api.NewComputeGrid(23,19,'u',16)
  if not grid then return checks,{'fixture allocation failed'}end
  for y=0,18 do for x=0,22 do
   local p=case%2==0 and y or x
   local jump=({2,127,128,129,65535})[(case-1)%5+1]
   local z=p>=10 and jump or 0
   if case>10 then z=65535-z end
   if case>16 then z=(x*x*71+y*y*139+x*y*51+case*673)%65536 end
   grid:set(x,y,z)
  end end
  for _,axis in ipairs({'x','y'})do
   local n,pn=axis=='x' and 19 or 23,axis=='x' and 23 or 19
   local function at(p,a)if axis=='x'then return grid:get(p,a)else return grid:get(a,p)end end
   for _,step in ipairs({1,8})do for _,widths in ipairs({1,3})do
    for _,threshold in ipairs({2,128,129,65535})do
     local expected_rows,expected_offers,count={},{},0
     for width=1,widths do expected_offers[width]={}end
     for a=0,n-1,step do
      for p=1,pn-3 do
       local any=false
       for width=1,widths do
        if p+width+1<pn then
         local v0,va,vb,v3=at(p-1,a),at(p,a),at(p+width,a),at(p+width+1,a)
         local delta,jump=vb-va,math.abs(vb-va)
         if jump>=threshold and jump>=2*math.max(math.abs(va-v0),math.abs(v3-vb),1)then
          local row=expected_offers[width][a]
          if not row then row={};expected_offers[width][a]=row end
          row[p]=delta;any=true;count=count+1
         end
        end
       end
       if any then
        expected_rows[a]=expected_rows[a] or {}
        expected_rows[a][#expected_rows[a]+1]=p
       end
      end
     end
     local rows,stats,offers=build(api,grid,axis,1,pn-3,n,step,widths,threshold)
     check(rows~=nil,'build failed '..tostring(stats))
     check(same(rows,expected_rows),'position/order mismatch case '..case)
     check(same(offers,expected_offers),'per-width signed offers mismatch case '..case)
     check(type(stats)=='table' and stats.enumerated==count,'accepted width census')
    end
   end end
  end
  grid:free()
 end
 return checks,issues,primitive
end
