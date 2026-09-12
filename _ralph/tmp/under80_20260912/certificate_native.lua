local result = {status='running'}
rawset(_G, 'SBM_NATIVE_STEP_CERT_PROBE', result)
PauseInfiniteLoopDetection('SBMNativeCertificateProbe')
local ok, why = pcall(function()
    local env, sbm
    for _, mod in ipairs(ModsLoaded or {}) do
        local value = mod.env and rawget(mod.env, 'SuperBigMap')
        if value and value.Config then env, sbm = mod.env, value; break end
    end
    if not sbm then error('mod missing') end
    local function read(path)
        local err, text = AsyncFileToString('D:/PROJS/SMR/super-big-map/'..path)
        if err or not text then error(tostring(err)) end
        return text:gsub('\r\n', '\n')
    end
    local source = read('_ralph/runs/under80-20260912/artifacts/certified_steps_research/terrain_candidate.lua')
    local first = source:find('local function BuildHeightStepDiscoveryIndex(', 1, true)
    local last = source:find('local function RepairInternalHeightStep(', first or 1, true)
    if not first or not last then error('candidate helper anchors missing '..tostring(first)..'/'..tostring(last)) end
    local body = source:sub(first, last-1)
    local function compile(text, name)
        local fn, err = load(text, name, 't', env)
        if not fn then error(tostring(err)) end
        return fn()
    end
    local build = compile(body..'\nreturn BuildHeightStepDiscoveryIndex', '@certificate-build')
    local oracle = compile(read('_ralph/tmp/under80_20260912/certificate_oracle.lua'), '@certificate-oracle')
    local api = {}
    for _, name in ipairs({'IsComputeGrid', 'GridRepack', 'GridMulDivAdd', 'GridAdd',
        'GridAbs', 'GridMask', 'GridCount', 'GridForeach', 'NewComputeGrid', 'box', 'point'}) do
        api[name] = sbm.Engine.Global(name)
    end
    result.checks = oracle(build, api)
end)
ResumeInfiniteLoopDetection('SBMNativeCertificateProbe')
result.status, result.error = ok and 'pass' or 'fail', ok and '' or tostring(why)
print('SBM_NATIVE_STEP_CERT_PROBE', result.status, result.checks, result.error)
