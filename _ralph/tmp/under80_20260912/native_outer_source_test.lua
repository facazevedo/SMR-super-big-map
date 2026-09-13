-- Actual staged production scalar branch and correction closure against v983.
local function read(path)local f=assert(io.open(path,'r'));local s=f:read('*a'):gsub('\r\n','\n');f:close();return s end
local current=read('Code/sbm_terrain_copy.lua')
local pipe=assert(io.popen('git show f4d1da6:Code/sbm_terrain_copy.lua','r'))
local prior=pipe:read('*a'):gsub('\r\n','\n');assert(pipe:close())
local function scalar_body(source)
    local first=assert(source:find('local function apply_native_patch',1,true))
    first=assert(source:find('local dx, dy = x - patch.cx, y - patch.cy',first,true))
    local last=assert(source:find('coarse:set(coarse_x, coarse_y,',first,true))
    return source:sub(first,last-1)
end
local function normalize(text)return (text:gsub('%s+',''))end
local literal=scalar_body(prior)
assert(normalize(scalar_body(current))==normalize(literal),'preserved scalar body changed')
local first=assert(current:find('local function scalar_native_weight(',1,true))
first=assert(current:find('local dx, dy = x - patch.cx, y - patch.cy',first,true))
local last=assert(current:find('return math.floor(weight * native_weight_scale + 0.5)',first,true))
assert(normalize(current:sub(first,last-1))==normalize(literal),'correction closure differs from v983 scalar')
local native_first=assert(current:find('local NativeOuterMask = function(',1,true))
local native_last=assert(current:find('local native_mask_failure',native_first,true))
local native=current:sub(native_first,native_last-1)
assert(native:find('stats.domain_qualified = true',1,true)<native:find('local owned, lookup',1,true),'domain marked after allocation')
assert(native:find('hard guard threshold domain',1,true)<native:find('stats.domain_qualified = true',1,true),'hard cutoff qualified too late')
for _,name in ipairs({'AsyncRand','InteractionRand','Random','Rand'})do
    assert(not native:find('%f[%w_]'..name..'%f[^%w_]'),'RNG name in native helper: '..name)
end
assert(current:find('if native_mask_failure then return end',1,true),'missing patch-loop abort')
assert(current:find('if native_mask_failure then ok_apply, apply_error = false, native_mask_failure end',1,true),'missing installation gate')
print('PASS staged source: both scalar copies match v983; domain/failure boundaries and no new RNG names')
