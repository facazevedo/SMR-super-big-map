-- Independent monotone scalar oracle against the ACTUAL local native block.
-- Check both endpoints of the inherited normalized-radius uncertainty interval.
-- Explicit issues/returns work even when engine assert/error only log.
return function(polynomial,api)
 local report={checks=0,weight_cells=0,min_slack_units=1e30,max_error_units=0,max_allowance_units=0,issues={}}
 local W,S=16777216,67108864
 local function issue(s)report.issues[#report.issues+1]=tostring(s)end
 local cores={0.2,0.2+1.0/W,0.25-0.5/W,0.25,0.25+0.5/W,1.0/3.0,
  0.4,0.6-1.0/W,0.6,0.6+1.0/W,0.75-0.5/W,0.75}
 local function weight(n,c)
  if n<=c then return 1 elseif n>=1 then return 0 end
  local t=(n-c)/(1-c)
  return 1-t*t*t*(t*(t*6-15)+10)
 end
 for _,core in ipairs(cores)do
  local owned={}
  local function own(g)if g then owned[#owned+1]=g end;return g end
  local ok,why=pcall(function()
   local w,h=257,24
   local grid=own(api.NewComputeGrid(w,h,'f',32))
   if not grid then issue('input allocation');return end
   local norms={}
   local c=math.floor(core*W+0.5)
   for y=0,h-1 do for x=0,w-1 do
    local encoded
    if y==0 then encoded=math.floor(x*S/256.0)
    elseif y<8 then encoded=c*4+x-128
    elseif y<13 then encoded=S+x-128
    else encoded=(x*7919+y*104729)%75497472 end
    grid:set(x,y,encoded)
    norms[y*w+x]=grid:get(x,y)/(S+0.0)
   end end
   api.GridMulDivAdd(grid,1,S,0)
   local result,err,error3=polynomial(api,own,grid,{core_fraction=core})
   if not result or err or not error3 then issue(err or 'local block failed');return end
   local delta=0.0000056+0.0000018/(core+0.0)
   for y=0,h-1 do for x=0,w-1 do
    local actual=result:get(x,y)
    -- Native getter truncates f32; floor is conservative for positive allowances
    -- and applied offline too. No fractional readback assumption supplies proof.
    local allowance=math.floor(error3:get(x,y))/3.0
    if actual<0 or actual>W or actual~=math.floor(actual) or allowance<79 or allowance>1206 then
     issue('weight/error field domain');return
    end
    report.weight_cells=report.weight_cells+1
    report.max_allowance_units=math.max(report.max_allowance_units,allowance)
    for _,sign in ipairs({-1,1})do
     local expected=weight(norms[y*w+x]+sign*delta,core)
     local difference=math.abs(actual-expected*W)
     report.min_slack_units=math.min(report.min_slack_units,allowance-difference)
     report.max_error_units=math.max(report.max_error_units,difference)
     if difference>allowance then
      issue('local allowance exceeded at '..tostring(core)..'/'..x..'/'..y..'/'..sign);return
     end
     report.checks=report.checks+1
    end
   end end
  end)
  if not ok then issue(why)end
  for i=#owned,1,-1 do
   local freed,err=pcall(owned[i].free,owned[i])
   if not freed then issue('cleanup: '..tostring(err))end
  end
  if #report.issues>0 then break end
 end
 report.expected_checks=12*257*24*2
 if report.checks~=report.expected_checks or report.weight_cells~=12*257*24 then issue('incomplete census')end
 report.status=#report.issues==0 and 'pass' or 'fail'
 return report
end
