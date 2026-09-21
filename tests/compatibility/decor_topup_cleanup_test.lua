local attempted={}
local globals={IsValid=function(o)return not o.deleted end,DoneObject=function(o)
 attempted[#attempted+1]=o
 if o.throw then error('injected removal failure')end
 if not o.ignore then o.deleted=true end
end}
SuperBigMap={Engine={Global=function(k)return globals[k]end},ObjectClone={}}
dofile('Code/sbm_decor_topup.lua')
local discard=SuperBigMap.DecorTopUp.DiscardCreated
assert(type(discard)=='function','new stamp cleanup must report and verify every removal')
local a,b,c={throw=true},{},{ignore=true}
local ok,reason=discard({a,b,c})
assert(not ok and reason and b.deleted and #attempted==3,'one failed removal prevented cleanup of other created objects')
assert(not a.deleted and not c.deleted,'fixture did not retain failing removals')
a.throw=nil;c.ignore=nil;attempted={}
assert(discard({a,b,c}) and a.deleted and c.deleted and #attempted==2,'retry must skip already removed objects')
globals.DoneObject=nil
assert(not discard({{}}),'missing removal API certified cleanup')
print('top-up cleanup: complete attempts, verified destruction, idempotence and failure reporting passed')
