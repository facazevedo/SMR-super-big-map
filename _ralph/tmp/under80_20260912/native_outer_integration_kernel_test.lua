-- Run the existing literal/failure suite against the helper embedded in the
-- generated integration draft, not against the standalone research helper.
local draft='_ralph/runs/under80-20260912/artifacts/native_outer_integration_research/sbm_terrain_copy.lua'
local f=assert(io.open(draft,'r'));local source=f:read('*a'):gsub('\r\n','\n');f:close()
local first=assert(source:find('local NativeOuterMask = function(',1,true))
local last=assert(source:find('\n\tlocal native_mask_failure',first,true))
local helper=assert(load(source:sub(first,last-1)..'\nreturn NativeOuterMask','integrated mask','t',_G))()
local old_dofile,old_open=dofile,io.open
local calls,qualified,unqualified=0,0,0
io.open=function(path,mode,...)
    if path=='Code/sbm_terrain_copy.lua' then path=draft end
    return old_open(path,mode,...)
end
_G.dofile=function(path)
    if path=='_ralph/tmp/under80_20260912/native_outer_mask.lua' then
        return function(...)
            local grid,stats,why=helper(...)
            assert(type(stats.domain_qualified)=='boolean','missing explicit domain discriminator')
            if stats.domain_qualified then qualified=qualified+1
            else
                unqualified=unqualified+1
                assert(not grid and type(why)=='string','domain refusal returned a grid')
            end
            calls=calls+1
            return grid,stats,why
        end
    end
    return old_dofile(path)
end
local ok,why=pcall(old_dofile,'_ralph/tmp/under80_20260912/native_outer_mask_test.lua')
_G.dofile,io.open=old_dofile,old_open
assert(ok,why)
assert(qualified>0 and unqualified>=5,'domain branches not exercised')
print('PASS embedded integration helper: '..calls..' calls; '..qualified..' qualified; '..unqualified..' domain refusals')
