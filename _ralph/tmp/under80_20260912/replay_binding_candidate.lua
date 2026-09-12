-- Offline-only IO redirection: run the unchanged regression on the candidate text.
-- Actual production regression replay remains required before any acceptance.
local candidate, regression = assert(arg[1]), assert(arg[2])
local original_open = io.open
io.open = function(path, mode)
    if path == 'Code/sbm_terrain_copy.lua' and (mode == 'r' or mode == 'rb') then
        path = candidate
    end
    return original_open(path, mode)
end
arg = { [0]=regression }
dofile(regression)
