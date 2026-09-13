-- PRIVATE RESEARCH ONLY. The epsilon below is NOT a proved certificate.
-- Caller must independently compare EVERY returned U12 cell with the scalar oracle.
-- Never deploy this function on the strength of a successful captured-data test.
-- KNOWN UNSAFE FAILURE PATH: native_outer_mask_residual_faults demonstrated that
-- the engine's error() logs and returns here; require_value does not abort work.
-- Offline Lua failure tests do NOT establish engine failure containment.
return function(api, row, scalar, epsilon_numerator)
    local math, type, ipairs = math, type, ipairs
    local w, h, step = row.width, row.height, row.sample_step
    local p = row.patch
    local stats = { corrected = 0, changed_by_correction = 0, samples = w*h,
        experimental_epsilon_numerator = epsilon_numerator, certificate_proved = false }
    local function integer(v) return type(v)=='number' and v==math.floor(v) end
    local function finite(v) return type(v)=='number' and v==v and math.abs(v)<=1048576 end
    local function require_value(ok, why) if not ok then error(why, 0) end end
    if row.atan2_present or not integer(w) or not integer(h) or w<2 or h<2
        or w>4096 or h>4096 or (step~=1 and step~=4) or not integer(row.x0)
        or not integer(row.y0) or not finite(p.core_cells) or p.core_cells<1
        or not finite(row.base_transition) or row.base_transition<1 or p.core_cells>row.base_transition
        or not finite(p.relief_x) or not finite(p.relief_y)
        or math.abs(p.relief_x)>1 or math.abs(p.relief_y)>1
        or not finite(row.irregularity) or row.irregularity<0 or row.irregularity>0.45
        or (epsilon_numerator~=nil and (not integer(epsilon_numerator)
            or epsilon_numerator<1 or epsilon_numerator>16)) then
        return nil, stats, 'unsupported research domain'
    end
    local function domain(cx, cy)
        if not integer(cx) or not integer(cy) then return false end
        local dx=math.max(math.abs(row.x0-cx),math.abs(row.x0+(w-1)*step-cx))
        local dy=math.max(math.abs(row.y0-cy),math.abs(row.y0+(h-1)*step-cy))
        return dx*dx+dy*dy<=16777216
    end
    if not domain(p.cx,p.cy) then return nil,stats,'coordinate square domain' end
    local allowance_units=324
    for _,g in ipairs(row.guards) do
        if not domain(g.cx,g.cy) or not finite(g.radius) or g.radius<1
            or not finite(g.transition) or g.transition<0
            or (g.transition>0 and (g.transition<0.25 or g.transition>128)) then
            return nil,stats,'unsupported protection domain'
        end
        if g.transition>0 then allowance_units=allowance_units+82+6*g.radius/g.transition end
    end
    local derived_numerator=math.ceil(allowance_units/256.0)
    if derived_numerator>16 then return nil,stats,'research error budget exceeds supported range' end
    epsilon_numerator=epsilon_numerator or derived_numerator
    stats.experimental_epsilon_numerator=epsilon_numerator
    stats.derived_numerator=derived_numerator
    local owned, lookup = {}, {}
    local function own(grid)
        require_value(grid~=nil and grid~=false,'native outer allocation failed')
        if grid and not lookup[grid] then lookup[grid]=true;owned[#owned+1]=grid end
        return grid
    end
    local function clone(grid) return own(grid:clone()) end
    local function new() return own(api.NewComputeGrid(w,h,'f',32)) end
    local function ratio(value)
        require_value(finite(value),'nonfinite native coefficient')
        local q=1073741824
        while math.abs(value)*q>16777215 do q=q/2 end
        return math.floor(value*q+0.5),q
    end
    local function mul(grid,value)
        local n,q=ratio(value)
        api.GridMulDivAdd(grid,n,q,0)
    end
    local function add(grid,value)
        local n,q=ratio(value)
        -- Powers-of-two scaling is exact; API arguments remain integral.
        api.GridMulDivAdd(grid,q,1,n)
        api.GridMulDivAdd(grid,1,q,0)
    end
    local function finite_positive(grid)
        require_value(api.GridCount(grid,0,2147483647)==w*h,'nonfinite/out-of-range native arithmetic')
    end
    local function reciprocal(grid)
        local original=clone(grid)
        api.GridPow(grid,-1,1)
        finite_positive(grid)
        api.GridMulDivAdd(original,grid,1,-1);api.GridAbs(original)
        api.GridMulDivAdd(original,16777216,1,0)
        api.GridClamp(original,0,16)
        require_value(api.GridCount(original,4,32)==0,'native outer reciprocal residual')
        stats.reciprocal_checks=(stats.reciprocal_checks or 0)+1
    end
    local function field(axis,center)
        local grid=new()
        local extent=axis=='x' and w or h
        for i=0,extent-1 do
            if axis=='x' then grid:set(i,0,i*step) else grid:set(0,i,i*step) end
        end
        local filled,across=1,axis=='x' and h or w
        while filled<across do
            local count=math.min(filled,across-filled)
            local box=axis=='x' and api.box(0,0,w,count) or api.box(0,0,count,h)
            local point=axis=='x' and api.point(0,filled) or api.point(filled,0)
            grid:copyrect(grid,box,point)
            filled=filled+count
        end
        api.GridMulDivAdd(grid,1,1,(axis=='x' and row.x0 or row.y0)-center)
        return grid
    end
    local function distance(cx,cy,need_root)
        local x,y=field('x',cx),field('y',cy)
        local square,y2=clone(x),clone(y)
        api.GridMulDivAdd(square,x,1,0);api.GridMulDivAdd(y2,y,1,0)
        api.GridAdd(square,y2)
        -- Squares/sum are exact within the qualified integer domain.
        if need_root==false then return nil,x,y,square end
        local squared=clone(square)
        api.GridClamp(squared,1,2147483647)
        local radius=clone(squared)
        api.GridPow(radius,1,2)
        finite_positive(radius)
        local residual=clone(radius)
        api.GridMulDivAdd(residual,radius,1,0)
        api.GridAddMulDiv(residual,squared,-1);api.GridAbs(residual)
        api.GridAddMulDiv(residual,squared,-2,16777216)
        api.GridMulDivAdd(residual,1073741824,1,0)
        api.GridClamp(residual,0,16)
        require_value(api.GridCount(residual,1,32)==0,'native outer root residual')
        stats.root_checks=(stats.root_checks or 0)+1
        return radius,x,y,square
    end
    local function smooth(t)
        local polynomial=clone(t)
        api.GridMulDivAdd(polynomial,6,1,-15)
        api.GridMulDivAdd(polynomial,t,1,10)
        local cube=clone(t)
        api.GridMulDivAdd(cube,t,1,0);api.GridMulDivAdd(cube,t,1,0)
        api.GridMulDivAdd(polynomial,cube,1,0)
        return polynomial
    end
    local result
    local ok,why=pcall(function()
        local radius,x,y=distance(p.cx,p.cy)
        local inverse=clone(radius)
        api.GridClamp(inverse,1,2147483647);reciprocal(inverse)
        api.GridMulDivAdd(x,inverse,1,0);api.GridMulDivAdd(y,inverse,1,0)
        mul(x,p.relief_x);mul(y,p.relief_y);api.GridAdd(x,y)
        local along=x
        local width=clone(along)
        api.GridMulDivAdd(width,along,1,0);api.GridMulDivAdd(width,24,100,0)
        local harmonic=row.cached_zero_harmonic
        if harmonic==nil then
            harmonic=.52*math.sin(p.phase)+.30*math.sin(-p.phase*1.37)+.18*math.sin(p.phase*.73)
        end
        require_value(finite(harmonic) and math.abs(harmonic)<=1,'native outer harmonic domain')
        add(width,1+row.irregularity*harmonic-.12)
        local linear=clone(along);api.GridMulDivAdd(linear,-6,100,0);api.GridAdd(width,linear)
        -- Clamp endpoints are integer-only: use the exactly scaled U24 interval.
        api.GridMulDivAdd(width,16777216,1,0)
        api.GridClamp(width,8388608,22649242)
        api.GridMulDivAdd(width,1,16777216,0)
        mul(width,row.base_transition);reciprocal(width)
        add(radius,-p.core_cells);api.GridMulDivAdd(radius,width,1,0)
        api.GridClamp(radius,0,1)
        local weight=smooth(radius)
        api.GridMulDivAdd(weight,-1,1,1);api.GridClamp(weight,0,1)
        for _,g in ipairs(row.guards) do
            local d,_,_,square=distance(g.cx,g.cy,g.transition>0)
            local protection
            if g.transition==0 then
                -- Integer squared distances permit a separated threshold. Resolve
                -- it with the literal scalar sqrt predicate, including exact tangency.
                local cutoff=math.floor(g.radius*g.radius)
                local resolved=false
                for attempt=1,4 do
                    if cutoff>0 and math.sqrt(cutoff)>g.radius then cutoff=cutoff-1
                    elseif math.sqrt(cutoff+1)<=g.radius then cutoff=cutoff+1
                    else resolved=true;break end
                end
                require_value(resolved and cutoff>=0 and cutoff<8388608,'hard guard threshold domain')
                protection=new()
                api.GridMulDivAdd(square,2,1,0)
                -- Inputs are even exact integers; threshold is odd and <2^24.
                api.GridMask(square,protection,2*cutoff+1,2147483647)
                stats.hard_guards=(stats.hard_guards or 0)+1
            else
                add(d,-g.radius)
                -- Reciprocal coefficient is rounded on the CPU for this prototype;
                -- its exact production error treatment remains an open proof obligation.
                mul(d,1.0/g.transition)
                api.GridClamp(d,0,1)
                protection=smooth(d);api.GridClamp(protection,0,1)
            end
            api.GridMulDivAdd(weight,protection,1,0)
        end
        api.GridClamp(weight,0,1)
        local lower,upper=clone(weight),clone(weight)
        add(lower,-epsilon_numerator/65536.0);api.GridClamp(lower,0,1)
        add(upper,epsilon_numerator/65536.0);api.GridClamp(upper,0,1)
        api.GridMulDivAdd(lower,4096,1,0);api.GridRound(lower)
        api.GridMulDivAdd(upper,4096,1,0);api.GridRound(upper)
        local uncertain=clone(upper)
        api.GridAddMulDiv(uncertain,lower,-1)
        api.GridMulDivAdd(uncertain,2,1,0) -- positive >=2; enumeration bound1 has no equality ambiguity
        local expected=api.GridCount(uncertain,1,2147483647)
        api.GridMulDivAdd(weight,4096,1,0);api.GridRound(weight)
        local seen={}
        api.GridForeach(uncertain,function(value,cx,cy)
            require_value(integer(cx) and integer(cy) and cx>=0 and cy>=0 and cx<w and cy<h,
                'native outer correction coordinate escaped patch')
            local key=cy*w+cx
            require_value(not seen[key],'duplicate native outer correction')
            seen[key]=true
            local exact=scalar(cx,cy)
            require_value(integer(exact) and exact>=0 and exact<=4096,'invalid scalar outer correction')
            if weight:get(cx,cy)~=exact then stats.changed_by_correction=stats.changed_by_correction+1 end
            weight:set(cx,cy,exact);stats.corrected=stats.corrected+1
        end,1,2147483647)
        require_value(type(expected)=='number' and expected==stats.corrected,'native outer correction census')
        result=weight
        stats.allocations=#owned
    end)
    local cleanup_error
    for i=#owned,1,-1 do
        if not ok or owned[i]~=result then
            local freed,err=pcall(owned[i].free,owned[i])
            if not freed then cleanup_error=tostring(err) end
        end
    end
    if cleanup_error then
        if result then pcall(result.free,result) end
        return nil,stats,'native outer cleanup: '..cleanup_error
    end
    if not ok then return nil,stats,tostring(why) end
    return result,stats
end
