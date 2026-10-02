-- Owner ruling 2026-10-01: a vanilla rock is not relocated far from its vanilla spot (seating had moved
-- some 70-102 m). Vanilla rocks keep the in-place attempt and the 16 m searches; the wide ~128 m
-- search is for mod top-up rocks only. A vanilla rock that still cannot be seated, or whose move
-- fails verification and rolls back, stays where the stretch put it and is accepted, counted as
-- kept_in_place rather than stopping map generation.
local function read(path) local f=assert(io.open(path,'rb'));local s=f:read('*a');f:close();return s:gsub('\r\n','\n') end
local seating=read('Code/sbm_decoration_seating.lua')
local validation=read('Code/sbm_decoration_validation.lua')

assert(seating:find('if not plan and entry.confirmed and sector_limits and topup then',1,true),
  'the wide relocation search is limited to mod top-up rocks')
assert(seating:find('offsets=Seating.NearbyOffsets(tile,16),position_allowed=same_sector',1,true),
  'vanilla rocks keep the 16 m one-tile search')
assert(seating:find('local function keep_in_place(obj,reason)',1,true))
assert(seating:find('obj.SuperBigMapSeatingKeptInPlace=true',1,true))
assert(seating:find('elseif not topup then\n\t\t\tfor _,member in ipairs(entry.members or {{obj=obj}}) do keep_in_place(member.obj',1,true),
  'a vanilla rock without a plan is kept in place')
assert(seating:find('if change.row and change.row.topup then',1,true)
  and seating:find('keep_in_place(change.obj,"independent rendered-placement verification failed")',1,true),
  'a rolled-back vanilla move is kept in place; a rolled-back top-up is still rejected')
assert(validation:find('elseif record.obj.SuperBigMapSeatingKeptInPlace==true then',1,true)
  and validation:find('result.kept_in_place=result.kept_in_place+1',1,true),
  'the support summary counts kept rocks instead of reporting them unresolved')
print('relocation cap: vanilla rocks stay within 16 m or are kept in place')
