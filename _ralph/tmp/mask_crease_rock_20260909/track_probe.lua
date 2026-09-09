local result={cases={},mismatches=0}
rawset(_G,'ROW_PROBE_RESULT',result);rawset(_G,'ROW_PROBE_STATUS','running')
CreateRealTimeThread(function()
 local ok,err=pcall(function()
  local translate=dofile('D:/PROJS/SMR/super-big-map/_ralph/tmp/mask_crease_rock_20260909/track_candidate.lua')
  local api={};for _,key in ipairs({'NewComputeGrid','GridRepack','GridResample','GridRound','GridFill',
   'GridMulDivAdd','GridAdd','GridMask','GridClamp','box','point','IsComputeGrid'}) do api[key]=_G[key]end
  for _,n in ipairs({16,32,64,512})do for _,axis in ipairs({'x','y'})do for _,before in ipairs({true,false})do
   local an=n==64 and 8192 or 1024
   local w,h=axis=='x' and n or an,axis=='x' and an or n
   local initial=NewComputeGrid(w,h,'u',16)
   for y=0,h-1 do for x=0,w-1 do initial:set(x,y,(x*131+y*7919)%65536)end end
   local a,b=initial:clone(),initial:clone();local rows={}
   for along=0,an-1 do if along%7~=0 then
    local size=1+(along*3)%n
    rows[#rows+1]={along=along,lo=before and 0 or n-size,hi=before and size-1 or n-1,offset=(along*7919)%65535+1}
   end end
   local started=GetPreciseTicks();local scalar_modified=0
   for _,row in ipairs(rows)do for p=row.lo,row.hi do
    local x,y=axis=='x' and p or row.along,axis=='x' and row.along or p
    a:set(x,y,math.min(65535,a:get(x,y)+row.offset));scalar_modified=scalar_modified+1
   end end
   local scalar_ms=GetPreciseTicks()-started;started=GetPreciseTicks()
   local modified,why=translate(api,b,axis,before,rows,65535)
   local native_ms=GetPreciseTicks()-started;local mismatches=0
   for y=0,h-1 do for x=0,w-1 do if a:get(x,y)~=b:get(x,y)then mismatches=mismatches+1 end end end
   result.mismatches=result.mismatches+mismatches
   result.cases[#result.cases+1]={length=n,along=an,axis=axis,before=before,scalar_ms=scalar_ms,
    native_ms=native_ms,mismatches=mismatches,modified=modified,scalar_modified=scalar_modified,error=why}
   a:free();b:free();initial:free()
  end end end
 end)
 if not ok then result.error=tostring(err)end
 rawset(_G,'ROW_PROBE_STATUS',ok and 'complete' or 'failed')
end)
