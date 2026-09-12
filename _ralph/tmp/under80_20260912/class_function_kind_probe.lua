-- Verify unblocked standard-library function-kind detection inside the mod API.
-- Do not expose bytecode or access blocked debug through the mod environment.
local result={status='setup',calls={}}
rawset(_G,'SBM_NATIVE_STEP_CERT_PROBE',result)
local sbm
for _,mod in ipairs(ModsLoaded or {})do
 local value=mod.env and rawget(mod.env,'SuperBigMap')
 if value and value.Engine then sbm=value;break end
end
if not sbm then result.status='fail';return end
local library=sbm.Engine.Global('string')
local dump=type(library)=='table' and library.dump
result.dump_available=type(dump)=='function'
result.debug_blocked=sbm.Engine.Global('debug')==nil
if not result.dump_available then result.status='fail';return end
local baseline_ok,baseline_error=pcall(dump,pcall)
result.baseline_failed=not baseline_ok
local all=true
for _,row in ipairs({{'pcall',pcall},{'IsKindOf',sbm.Engine.Global('IsKindOf')},
 {'IsKindOfClasses',sbm.Engine.Global('IsKindOfClasses')},
 {'Lua closure',function()return true end},{'mod classifier',sbm.ObjectClone.ShouldSkipObject}})do
 local ok,value=pcall(dump,row[2])
 local native=debug.getinfo(row[2],'S').what=='C' -- diagnostic ground truth only
 local classified=not ok and not baseline_ok and value==baseline_error
 local match=classified==native
 result.calls[#result.calls+1]={name=row[1],dump_ok=ok,bytes=ok and #value or 0,
  error=not ok and tostring(value) or '',native= native,classified_native=classified,match=match}
 all=all and match
end
result.status=all and 'pass' or 'fail'
return 'FUNCTION_KIND_PROBE_COMPLETE'
