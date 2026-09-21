SuperBigMap={}
dofile('Code/sbm_config.lua')
local c=SuperBigMap.Config
for key,value in pairs(c)do
 if key:match('^DEBUG_')or key:match('^TRACE_')or key=='NATIVE_SOURCE_MANIFEST'or key=='DECORATION_VALIDATION_ENABLED'then
  assert(value==false,'release diagnostic enabled: '..key)
 end
end
assert(c.PLACE_ELEVATOR_BUTTON_ENABLED==false,'test elevator controls enabled')
assert(c.UNDERGROUND_REVEAL_ALL_ENRICHMENTS_FOR_TESTING==false,'test reveal enabled')
assert(c.STRETCH_HEIGHT_GRID_DUMP_PATH=='','test terrain dumps enabled')
assert(c.FULL_MAP_PLAYABLE and c.SURFACE_STRETCH_AT_START,'release must keep complete expanded terrain')
print('release configuration: exhaustive diagnostics/traces/manifests disabled, expansion retained')
