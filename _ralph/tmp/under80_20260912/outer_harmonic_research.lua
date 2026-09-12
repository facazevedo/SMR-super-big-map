-- Non-deployed research: complex powers replace per-cell trigonometry only as
-- an approximation to be certified before exact coarse U12 rounding.
return function(api,own,u,v,phase)
    local function clone(g)
        local result=own(g:clone())
        if not result then error('outer harmonic research allocation failed') end
        return result
    end
    local function multiply(ar,ai,br,bi)
        local real,cross=clone(ar),clone(ai)
        api.GridMulDivAdd(real,br,1,0);api.GridMulDivAdd(cross,bi,1,0)
        api.GridAddMulDiv(real,cross,-1)
        local imag,other=clone(ar),clone(ai)
        api.GridMulDivAdd(imag,bi,1,0);api.GridMulDivAdd(other,br,1,0)
        api.GridAdd(imag,other)
        return real,imag
    end
    local r2,i2=multiply(u,v,u,v)
    local r3,i3=multiply(r2,i2,u,v)
    local r5,i5=multiply(r3,i3,r2,i2)
    local r7,i7=multiply(r5,i5,r2,i2)
    local W=16777216
    local terms={{r3,i3,0.52,phase},{r5,i5,0.30,-phase*1.37},{r7,i7,0.18,phase*0.73}}
    local result
    for _,term in ipairs(terms) do
        local sine=math.floor(term[3]*math.sin(term[4])*W+0.5)
        local cosine=math.floor(term[3]*math.cos(term[4])*W+0.5)
        api.GridMulDivAdd(term[1],sine,W,0)
        api.GridAddMulDiv(term[1],term[2],cosine,W)
        if result then api.GridAdd(result,term[1]) else result=term[1] end
    end
    return result
end
