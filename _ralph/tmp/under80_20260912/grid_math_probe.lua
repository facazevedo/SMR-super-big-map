-- Native scratch arithmetic only. No terrain, generation or installed hooks.
local result = {status='running', samples={}}
rawset(_G, 'SBM_NATIVE_STEP_CERT_PROBE', result)
local owned = {}
local function own(g) owned[#owned+1]=g; return g end
local ok, why = pcall(function()
    local function sample(name, g)
        local scaled = own(g:clone())
        GridMulDivAdd(scaled,1000000,1,0)
        local lo, hi = GridMinMax(scaled)
        result.samples[name] = {minimum_scaled=lo, maximum_scaled=hi, getter_scaled=scaled:get(0,0)}
    end
    local g = own(NewComputeGrid(2,2,'f',32))
    GridFill(g,1)
    GridMulDivAdd(g,1,4,0)
    sample('quarter',g)
    local reciprocal = own(g:clone())
    GridPow(reciprocal,-1,1)
    sample('reciprocal',reciprocal)
    local root = own(g:clone())
    GridPow(root,1,2)
    sample('root',root)
    local fractional = own(g:clone())
    GridMulDivAdd(fractional,1,2,125000,1000000)
    sample('integer_scaled_args',fractional)
    local x,y,angle = own(g:clone()),own(g:clone()),own(g:clone())
    GridFill(x,1); GridFill(y,1)
    GridATan2(y,x,angle)
    sample('atan2_pi_over_four',angle)
    local cosine = own(angle:clone())
    GridCos(cosine,cosine)
    sample('cos_pi_over_four',cosine)
    local sine = own(angle:clone())
    GridSin(sine,sine)
    sample('sin_pi_over_four',sine)
end)
for i=#owned,1,-1 do owned[i]:free() end
result.status, result.error = ok and 'pass' or 'fail', ok and '' or tostring(why)
print('SBM_GRID_MATH_PROBE',result.status,result.error)
