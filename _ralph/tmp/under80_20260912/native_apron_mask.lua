-- Research: bounded f32 mask with runtime root/reciprocal residual certificates.
-- nil without a reason means the numeric domain requires the exact scalar path.
-- nil with a reason is a native failure, never permission for silent fallback.
return function(api, own, candidate, policy, short_radius, long_radius, x0, y0, w, h)
    local S, W = 1048576, 16777216
    local function finite(v) return type(v)=='number' and v==v and math.abs(v)<=1048576 end
    if not finite(policy.core_fraction) or policy.core_fraction<0.2 or policy.core_fraction>0.75
        or short_radius<=0 or long_radius<=0 or w<2 or h<2 or w>16384 or h>16384 then return nil end
    for _,v in ipairs({candidate.x,candidate.y,candidate.mountain_x,candidate.mountain_y,
        short_radius,long_radius,x0,y0}) do if not finite(v) then return nil end end
    local specs={}
    for _,component in ipairs({'u','v'}) do
        local radius=component=='u' and short_radius or long_radius
        local cx=component=='u' and candidate.mountain_x or -candidate.mountain_y
        local cy=component=='u' and candidate.mountain_y or candidate.mountain_x
        local xv,yv={},{}
        for x=0,w-1 do xv[x]=(x+x0-candidate.x)*cx/radius end
        for y=0,h-1 do yv[y]=(y+y0-candidate.y)*cy/radius end
        for _,values in ipairs({xv,yv}) do
            for _,value in pairs(values) do if not finite(value) or math.abs(value)>4 then return nil end end
        end
        for _,x in ipairs({0,w-1}) do for _,y in ipairs({0,h-1}) do
            if math.abs(xv[x]+yv[y])>4 then return nil end
        end end
        specs[component]={x=xv,y=yv}
    end
    local function field(values,axis)
        local grid=own(api.NewComputeGrid(w,h,'f',32))
        if not grid then return nil,'native mask coordinate allocation failed' end
        for index,value in pairs(values) do
            local encoded=math.floor(value*S+0.5)+4*S
            if axis=='x' then grid:set(index,0,encoded) else grid:set(0,index,encoded) end
        end
        local filled,extent=1,axis=='x' and h or w
        while filled<extent do
            local count=math.min(filled,extent-filled)
            local bounds=axis=='x' and api.box(0,0,w,count) or api.box(0,0,count,h)
            local destination=axis=='x' and api.point(0,filled) or api.point(filled,0)
            grid:copyrect(grid,bounds,destination)
            filled=filled+count
        end
        api.GridMulDivAdd(grid,1,1,-4*S)
        api.GridMulDivAdd(grid,1,S,0)
        return grid
    end
    local function plane(component)
        local spec=specs[component]
        local x,why=field(spec.x,'x');if not x then return nil,why end
        local y,why=field(spec.y,'y');if not y then return nil,why end
        api.GridAdd(x,y)
        return x
    end
    local function zero_count(grid,lower)
        local count=api.GridCount(grid,lower,2147483647)
        return type(count)=='number' and count==0
    end
    local function reciprocal(grid)
        local original=own(grid:clone())
        if not original then return nil,'native mask reciprocal snapshot allocation failed' end
        api.GridPow(grid,-1,1)
        api.GridMulDivAdd(original,grid,1,-1);api.GridAbs(original)
        api.GridMulDivAdd(original,W,1,0)
        if not zero_count(original,16) then return nil,'native mask reciprocal residual failed' end
        return true
    end
    local u,why=plane('u');if not u then return nil,why end
    local v,why=plane('v');if not v then return nil,why end
    local radius,v2=own(u:clone()),own(v:clone())
    if not radius or not v2 then return nil,'native mask square allocation failed' end
    api.GridMulDivAdd(radius,u,1,0);api.GridMulDivAdd(v2,v,1,0)
    api.GridAdd(radius,v2)
    local squared=own(radius:clone())
    if not squared then return nil,'native mask root snapshot allocation failed' end
    api.GridPow(radius,1,2)
    local residual=own(radius:clone())
    if not residual then return nil,'native mask root certificate allocation failed' end
    api.GridMulDivAdd(residual,radius,1,0)
    api.GridAddMulDiv(residual,squared,-1);api.GridAbs(residual)
    api.GridAddMulDiv(residual,squared,-1,S)
    api.GridMulDivAdd(residual,W,1,0)
    if not zero_count(residual,1) then return nil,'native mask square-root residual failed' end
    local inverse=own(radius:clone())
    if not inverse then return nil,'native mask inverse allocation failed' end
    -- Clamp away the singularity strictly inside the minimum allowed core.
    api.GridMulDivAdd(inverse,8,1,0); api.GridClamp(inverse,1,2147483647)
    local valid,why=reciprocal(inverse);if not valid then return nil,why end
    api.GridMulDivAdd(inverse,8,1,0)
    api.GridMulDivAdd(u,inverse,1,0); api.GridMulDivAdd(v,inverse,1,0)
    local u2=own(u:clone())
    if not u2 then return nil,'native mask normalized square allocation failed' end
    api.GridMulDivAdd(u2,u,1,0)
    api.GridMulDivAdd(v,v,1,0)
    local lobe3=own(u2:clone())
    if not lobe3 then return nil,'native mask lobe allocation failed' end
    api.GridMulDivAdd(lobe3,u,1,0)
    local cross=own(v:clone())
    if not cross then return nil,'native mask cross allocation failed' end
    api.GridMulDivAdd(cross,u,1,0)
    api.GridAddMulDiv(lobe3,cross,-3)
    local lobe2=own(u2:clone())
    if not lobe2 then return nil,'native mask second lobe allocation failed' end
    api.GridAddMulDiv(lobe2,v,-1)
    -- Coefficients use integer-ratio native arguments, never float API arguments.
    api.GridMulDivAdd(lobe3,55,1000,1)
    api.GridAddMulDiv(lobe3,lobe2,35,1000)
    local valid,why=reciprocal(lobe3);if not valid then return nil,why end
    api.GridMulDivAdd(radius,lobe3,1,0)
    local core=math.floor(policy.core_fraction*W+0.5)
    api.GridMulDivAdd(radius,W,1,-core)
    api.GridMulDivAdd(radius,1,W-core,0)
    api.GridClamp(radius,0,1)
    local polynomial=own(radius:clone())
    if not polynomial then return nil,'native mask polynomial allocation failed' end
    api.GridMulDivAdd(polynomial,6,1,-15)
    api.GridMulDivAdd(polynomial,radius,1,10)
    local cube=own(radius:clone())
    if not cube then return nil,'native mask cubic allocation failed' end
    api.GridMulDivAdd(cube,radius,1,0);api.GridMulDivAdd(cube,radius,1,0)
    api.GridMulDivAdd(polynomial,cube,1,0)
    api.GridMulDivAdd(polynomial,-1,1,1)
    api.GridClamp(polynomial,0,1)
    api.GridMulDivAdd(polynomial,W,1,0)
    api.GridRound(polynomial)
    return polynomial
end
