SuperBigMap={}
dofile('Code/sbm_config.lua')
local c=SuperBigMap.Config
for key,value in pairs(c)do
 if key:match('^DEBUG_')or key:match('^TRACE_')or key=='NATIVE_SOURCE_MANIFEST'or key=='DECORATION_VALIDATION_ENABLED'then
  assert(value==false,'release diagnostic enabled: '..key)
 end
end
-- Owner request 2026-09-28: publish without the Place Elevator / Switch Underground / Reveal Surface
-- / Reveal Underground test buttons.
assert(c.PLACE_ELEVATOR_BUTTON_ENABLED==false,'temporary inspection buttons enabled')
assert(c.UNDERGROUND_REVEAL_ALL_DARKNESS==false,'test darkness reveal enabled')
assert(c.UNDERGROUND_REVEAL_ALL_ENRICHMENTS_FOR_TESTING==false,'test reveal enabled')
assert(c.STRETCH_HEIGHT_GRID_DUMP_PATH=='','test terrain dumps enabled')
assert(c.FULL_MAP_PLAYABLE and c.SURFACE_STRETCH_AT_START,'release must keep complete expanded terrain')
-- Informational log lines print only with debug logging; failure reports stay unconditional.
local f=assert(io.open('Code/sbm_underground_darkness.lua','rb'));local darkness=f:read('*a');f:close()
local _,gated=darkness:gsub('DEBUG_LOGGING_ENABLED == true','')
assert(gated==2,'underground darkness status lines must be debug-only, found '..gated..' gates')
print('release configuration: diagnostics, traces, manifests and test buttons disabled, expansion retained')
