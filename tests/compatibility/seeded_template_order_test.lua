-- Seeded choice must index canonical native records, not spatial-tree enumeration.
local file=assert(io.open('Code/sbm_deposits.lua','r'));local source=file:read('*a');file:close()
local body=assert(source:match('(function DepositRules.SortNativeTemplates.-)\nend\n'),
  'native donor lists have no canonical ordering')..'\nend\nreturn DepositRules.SortNativeTemplates'
local sort=assert(load(body,'production native template ordering','t',{DepositRules={},type=type,
  ipairs=ipairs,table=table,math=math}))()
local objects={}
for i=1,91 do objects[i]={SuperBigMapNativeRecordIndex=i,resource='resource'..i%5,handle=92-i} end
local function list(reverse)
  local t={};for i=1,#objects do t[i]=objects[reverse and #objects-i+1 or i] end;return t
end
for trial=1,300 do
  local t=list(trial%2==0)
  for i=#t,2,-1 do local j=(trial*37+i*17)%i+1;t[i],t[j]=t[j],t[i] end
  assert(sort(t)==t,'list identity changed')
  for i=1,#t do assert(t[i]==objects[i],'seeded donor choice depends on enumeration') end
end
for _,t in ipairs({{{handle=1},{handle=2}},{{SuperBigMapNativeRecordIndex=2},{handle=4}},
  {{SuperBigMapNativeRecordIndex=2},{SuperBigMapNativeRecordIndex=2}},
  {{SuperBigMapNativeRecordIndex=0},{SuperBigMapNativeRecordIndex=1}},
  {{SuperBigMapNativeRecordIndex=1.5},{SuperBigMapNativeRecordIndex=1}}}) do
  local first,second=t[1],t[2];sort(t)
  assert(t[1]==first and t[2]==second,'uncertified/custom donor order was changed')
end
assert(#sort({})==0)
for _,name in ipairs({'TopUpDeposits','TopUpAnomalies','TopUpEffectDeposits'}) do
  local section=assert(source:match('function DepositRules%.'..name..'%b().-\nend'))
  assert(section:find('DepositRules.SortNativeTemplates',1,true),name..' bypasses canonical donor ordering')
end
print('seeded native templates: 27300 donor choices stable under shuffled enumeration; custom/duplicate records preserved')
