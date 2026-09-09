local path=arg[1] or 'Code/sbm_terrain_copy.lua'
local f=assert(io.open(path,'r'));local source=f:read('*a');f:close()
local body=assert(source:match('(local function TranslateHeightTrack.-)\nreturn TranslateHeightTrack')
 or source:match('(local function TranslateHeightTrack.-)\nlocal function RepairInternalHeightStep'),
 'native track translation missing')
local translate=assert(load(body..'\nreturn TranslateHeightTrack'))()
local api=dofile('_ralph/tools/parity/native_grid_double.lua')
api.GridMask=function(input,output,lo,hi)
 local w,h=input:size();for y=0,h-1 do for x=0,w-1 do
  local v=input:get(x,y);output:set(x,y,v>=lo and v<=hi and 1 or 0)
 end end
end
local checks=0
local function check(ok,msg)assert(ok,msg);checks=checks+1 end
if source:find('local function RepairInternalHeightStep',1,true)then
 check(source:find('pcall(TranslateHeightTrack, discovery_api, grid, selected.axis,',1,true)~=nil,
  'production does not invoke the checked batch kernel')
 check(source:find('OptimizationFailure("native crease translation", report.error, map)',1,true)~=nil,
  'batch failure must be surfaced before terrain publication')
end
for _,axis in ipairs({'x','y'})do for _,before in ipairs({true,false})do
 for case=1,12 do
  local a=api.NewComputeGrid(39,35,'u',16)
  for y=0,34 do for x=0,38 do a:set(x,y,(x*337+y*7111)%65536)end end
  local b=a:clone();local pn=axis=='x' and 39 or 35;local an=axis=='x' and 35 or 39
  local rows={};local count=0
  for along=0,an-1 do if (along+case)%7~=0 then
   local n=case==1 and 1 or (1+(along*3+case)%math.min(pn,30))
   local row={along=along,lo=before and 0 or pn-n,hi=before and n-1 or pn-1,offset=(along*31+case*997)%65535+1}
   rows[#rows+1]=row;count=count+n
   for p=row.lo,row.hi do local x,y=axis=='x' and p or along,axis=='x' and along or p
    a:set(x,y,math.min(65535,a:get(x,y)+row.offset))
   end
  end end
  local changed,err=translate(api,b,axis,before,rows,65535)
  check(changed==count,'track failed: '..tostring(err))
  for y=0,34 do for x=0,38 do check(a:get(x,y)==b:get(x,y),'track height changed')end end
  a:free();b:free()
 end
end end
local g=api.NewComputeGrid(39,35,'u',16)
local missing={};for k,v in pairs(api)do missing[k]=v end;missing.GridRepack=nil
local count,why=translate(missing,g,'x',true,{{along=0,lo=0,hi=4,offset=5}},65535)
check(count==nil and why:find('GridRepack',1,true),'missing primitive must fail before writes')
count,why=translate(api,g,'x',true,{{along=0,lo=0,hi=4,offset=5},{along=0,lo=0,hi=6,offset=2}},65535)
check(count==nil and why:find('dependent',1,true),'duplicate rows must not be batched')
check(g:get(0,0)==0,'failed translation published terrain')
g:free()
for _,axis in ipairs({'x','y'})do for _,before in ipairs({true,false})do
 for _,maximum in ipairs({0,1,12345,65535})do
  local a=api.NewComputeGrid(13,17,'u',16)
  for y=0,16 do for x=0,12 do a:set(x,y,(x*97+y*193)%(maximum+1))end end
  local b=a:clone();local pn=axis=='x' and 13 or 17
  local p=before and 0 or pn-1
  local row={along=0,lo=p,hi=p,offset=65535}
  local x,y=axis=='x' and p or 0,axis=='x' and 0 or p
  a:set(x,y,maximum)
  check(translate(api,b,axis,before,{row},maximum)==1,'singleton translation failed')
  for y=0,16 do for x=0,12 do check(a:get(x,y)==b:get(x,y),'singleton/clamp changed outside write')end end
  a:free();b:free()
 end
end end
print('crease track translation: '..checks..' checks passed')
