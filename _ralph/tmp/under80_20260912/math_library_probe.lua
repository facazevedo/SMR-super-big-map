local result={status='fail',global_atan2=type(math.atan2),global_atan=type(math.atan)}
rawset(_G,'SBM_NATIVE_STEP_CERT_PROBE',result)
for _,mod in ipairs(ModsLoaded or {}) do
    local sbm=mod.env and rawget(mod.env,'SuperBigMap')
    if sbm and sbm.Config then
        local library=mod.env.math
        result.mod_atan2=type(library.atan2)
        result.mod_atan=type(library.atan)
        result.same_math_table=library==math
        result.same_sin=library.sin==math.sin
        result.sin_kind=debug.getinfo(library.sin,'S').what
        result.status='pass'
        break
    end
end
print('SBM_MATH_LIBRARY_PROBE',result.status,result.global_atan2,result.mod_atan2)
