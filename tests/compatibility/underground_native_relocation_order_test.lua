local f=assert(io.open('Code/sbm_map_generation.lua','r'));local source=f:read('*a');f:close()
local block=assert(source:match('(if type%(deposits.RelocateUnreachableUndergroundEnrichments%) ~= "function" then%s+error%("underground native enrichment reachability is unavailable"%).-)\n%s*local wall_token'))
local pre=assert(source:find(block,1,true))
local topup=assert(source:find('deposits.TopUpDeposits, map)',pre,true))
local restore=assert(source:find('deposits.EndUndergroundTopUpWallIgnore(map)',topup,true))
local final=assert(source:find('local audit_ok, audit_stats = deposits.RelocateUnreachableUndergroundEnrichments(map)',restore,true))
assert(pre<topup and topup<restore and restore<final,'native priority or final validation ordering lost')
for _,mode in ipairs({'success','unresolved','missing','error'})do
  local slots,events={},{}
  local map={}
  local deposits={RelocateUnreachableUndergroundEnrichments=function(owner)
    assert(owner==map and next(slots)==nil,'additions reserved space before native relocation')
    events[#events+1]='native'
    if mode=='error'then error('injected relocation error')end
    if mode=='unresolved'then return false,{unresolved=1,unresolved_details='injected unreachable native'}end
    slots[1]='native';return true,{moved=1,unresolved=0}
  end}
  if mode=='missing'then deposits.RelocateUnreachableUndergroundEnrichments=nil end
  local env=setmetatable({map=map,deposits=deposits,
    LoadingBegin=function()return 'token'end,
    LoadingEnd=function(token,stats,ok)assert(token=='token');events[#events+1]=ok and 'validated' or 'rejected'end,
  },{__index=_G})
  local ok=pcall(assert(load(block,'native-before-additions production phase','t',env)))
  if mode=='success'then
    assert(ok and map.SuperBigMapNativeEnrichmentReachability.moved==1)
    -- Additions see the native reservation and must choose the remaining slot.
    local chosen=slots[1] and 2 or 1;slots[chosen]='topup'
    assert(slots[1]=='native' and slots[2]=='topup' and table.concat(events,',')=='native,validated')
  else
    assert(not ok and next(slots)==nil,'failed native reachability allowed density placement')
  end
end
print('underground native relocation precedes density reservations; failures gate additions; final audit retained')
