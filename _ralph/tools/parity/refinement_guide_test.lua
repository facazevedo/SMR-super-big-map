local f = assert(io.open(arg[1] or "Code/sbm_terrain_copy.lua", "r"))
local source = f:read("*a"); f:close()
local a = assert(source:find("local function NewHeightStepRefinementGuide(", 1, true),
    "production refinement guide missing")
local b = assert(source:find("-- HEIGHT_REFINEMENT_GUIDE_END", a, true))
local factory = assert(load(source:sub(a,b-1) .. "\nreturn NewHeightStepRefinementGuide"))()
local checks = 0
local function check(ok, why) assert(ok, why); checks = checks + 1 end
for _, axis in ipairs({'x','y'}) do
    local edge = axis == 'x' and 'left' or 'top'
    local other = axis == 'x' and 'y' or 'x'
    local track = {axis=axis,edge=edge}
    for wp = 0, 39 do for wa = 0, 39 do
        local guide = factory()
        local row = {12,17,23}
        guide.RegisterDomain(axis,edge,8,30,1,{[20]=row})
        check(guide.Candidates(track,20,10,25,29) == row, 'full native index reusable')
        guide.RegisterWrite(axis,wa,wp,wp+2)
        local conflict = wa == 20 and wp <= 29 and wp+2 >= 9
        check((guide.Candidates(track,20,10,25,29) == false) == conflict,
            'same-axis dependency intersection')
        guide = factory()
        guide.RegisterDomain(axis,edge,8,30,1,{[20]=row})
        guide.RegisterWrite(other,wp,wa,wa+2)
        conflict = wp >= 9 and wp <= 29 and wa <= 20 and wa+2 >= 20
        check((guide.Candidates(track,20,10,25,29) == false) == conflict,
            'cross-axis dependency intersection')
        check(guide.Candidates(track,20,7,25,29) == false, 'incomplete left domain')
        check(guide.Candidates(track,20,10,31,35) == false, 'incomplete right domain')
    end end
    local guide = factory()
    guide.RegisterDomain(axis,edge,8,30,8,{[20]={17}})
    check(guide.Candidates(track,20,10,25,29) == false, 'coarse source rows cannot certify refinement')
end
print('production refinement guide: ' .. checks .. ' checks passed')
