-- Research only: approximate f32 mask. NOT safe to publish without a proved
-- final-height error bracket and exact scalar correction of ambiguous cells.
return function(api, own, candidate, policy, short_radius, long_radius, x0, y0, w, h)
    local S, W = 1048576, 16777216
    local function plane(component)
        local function value(x,y)
            local dx,dy=x-candidate.x,y-candidate.y
            if component=='u' then
                return (dx*candidate.mountain_x+dy*candidate.mountain_y)/short_radius
            end
            return (-dx*candidate.mountain_y+dy*candidate.mountain_x)/long_radius
        end
        local a,b = math.floor(value(x0,y0)*S+0.5),math.floor(value(x0+w-1,y0)*S+0.5)
        local c,d = math.floor(value(x0,y0+h-1)*S+0.5),math.floor(value(x0+w-1,y0+h-1)*S+0.5)
        local bias=math.max(0,-math.min(a,b,c,d))
        if math.max(a,b,c,d)+bias>W then error('mask plane exceeds exact integer seed encoding') end
        local seed=own(api.NewComputeGrid(2,2,'f',32))
        seed:set(0,0,a+bias);seed:set(1,0,b+bias)
        seed:set(0,1,c+bias);seed:set(1,1,d+bias)
        api.GridMulDivAdd(seed,1,1,-bias)
        api.GridMulDivAdd(seed,1,S,0)
        return own(api.GridResample(seed,w,h,true))
    end
    local u,v=plane('u'),plane('v')
    local radius=own(u:clone()); api.GridMulDivAdd(radius,u,1,0)
    local v2=own(v:clone()); api.GridMulDivAdd(v2,v,1,0)
    api.GridAdd(radius,v2); api.GridPow(radius,1,2)
    local inverse=own(radius:clone())
    -- Clamp away the singularity strictly inside the minimum allowed core.
    api.GridMulDivAdd(inverse,8,1,0); api.GridClamp(inverse,1,2147483647)
    api.GridPow(inverse,-1,1); api.GridMulDivAdd(inverse,8,1,0)
    api.GridMulDivAdd(u,inverse,1,0); api.GridMulDivAdd(v,inverse,1,0)
    local u2=own(u:clone());api.GridMulDivAdd(u2,u,1,0)
    api.GridMulDivAdd(v,v,1,0)
    local lobe3=own(u2:clone())
    api.GridMulDivAdd(lobe3,u,1,0)
    local cross=own(v:clone());api.GridMulDivAdd(cross,u,1,0)
    api.GridAddMulDiv(lobe3,cross,-3)
    local lobe2=own(u2:clone());api.GridAddMulDiv(lobe2,v,-1)
    -- Coefficients use integer-ratio native arguments, never float API arguments.
    api.GridMulDivAdd(lobe3,55,1000,1)
    api.GridAddMulDiv(lobe3,lobe2,35,1000)
    api.GridPow(lobe3,-1,1)
    api.GridMulDivAdd(radius,lobe3,1,0)
    local core=math.floor(policy.core_fraction*W+0.5)
    api.GridMulDivAdd(radius,W,1,-core)
    api.GridMulDivAdd(radius,1,W-core,0)
    api.GridClamp(radius,0,1)
    local polynomial=own(radius:clone())
    api.GridMulDivAdd(polynomial,6,1,-15)
    api.GridMulDivAdd(polynomial,radius,1,10)
    local cube=own(radius:clone())
    api.GridMulDivAdd(cube,radius,1,0);api.GridMulDivAdd(cube,radius,1,0)
    api.GridMulDivAdd(polynomial,cube,1,0)
    api.GridMulDivAdd(polynomial,-1,1,1)
    api.GridClamp(polynomial,0,1)
    api.GridMulDivAdd(polynomial,W,1,0)
    api.GridRound(polynomial)
    return polynomial
end
