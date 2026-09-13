-- Export literal f32 scratch results for an independent exact-rational audit.
local result={status='running',calls={}}
rawset(_G,'SBM_NATIVE_STEP_CERT_PROBE',result)
local out='D:/PROJS/SMR/super-big-map/_ralph/runs/under80-20260912/artifacts/native_outer_primitives/'
local owned={}
local function own(g) if g then owned[#owned+1]=g end;return g end
local function fail(why)result.status='fail';result.error=tostring(why)end
local function save(name,g)
    if not g then fail('missing '..name);return false end
    local err=GridSaveRaw(out..name..'.f32',g)
    if err then fail('save '..name..': '..tostring(err));return false end
    result.calls[#result.calls+1]={name=name,cells=1024}
    return true
end
local ok,why=pcall(function()
    local x,y,square=own(NewComputeGrid(32,32,'f',32)),own(NewComputeGrid(32,32,'f',32)),own(NewComputeGrid(32,32,'f',32))
    if not x or not y or not square then fail('allocation');return end
    local special={0,8388608,16777215,8389632,8391680,12583936,4195328,16776192}
    for i=0,1023 do
        local cx,cy=i%32,math.floor(i/32)
        x:set(cx,cy,special[i+1] or ((i*104729)%16777213))
        y:set(cx,cy,(i*130363+31)%16777213)
        square:set(cx,cy,1+(i*65521)%16777215)
    end
    GridMulDivAdd(x,1,8388608,-1);GridMulDivAdd(y,1,8388608,-1)
    if not save('x',x) or not save('y',y) or not save('square',square) then return end
    local operations={
        {'mul_grid',function(g)GridMulDivAdd(g,y,1,0)end},
        {'fma_grid',function(g)GridMulDivAdd(g,y,1,-1)end},
        {'scale_ratio',function(g)GridMulDivAdd(g,24,100,0)end},
        {'polynomial_a',function(g)GridMulDivAdd(g,6,1,-15)end},
        {'add_grid',function(g)GridAdd(g,y)end},
        {'add_scaled_grid',function(g)GridAddMulDiv(g,y,-2,16777216)end},
        {'encoded_add',function(g)GridMulDivAdd(g,16777216,1,14763950);GridMulDivAdd(g,1,16777216,0)end},
        {'clamp',function(g)GridClamp(g,0,1)end},
        {'abs',function(g)GridAbs(g)end},
        {'round_positive',function(g)GridAbs(g);GridMulDivAdd(g,4096,1,0);GridRound(g)end},
    }
    for _,op in ipairs(operations)do
        local g=own(x:clone());if not g then fail('clone');return end
        op[2](g);if not save(op[1],g) then return end
    end
    local root,inverse=own(square:clone()),own(square:clone())
    if not root or not inverse then fail('power clone');return end
    GridPow(root,1,2);GridPow(inverse,-1,1)
    if not save('root',root) or not save('inverse',inverse) then return end
end)
for i=#owned,1,-1 do owned[i]:free() end
if not ok then fail(why) end
if not result.error then result.status='pass' end
return 'NATIVE_OUTER_PRIMITIVES_CAPTURED'
