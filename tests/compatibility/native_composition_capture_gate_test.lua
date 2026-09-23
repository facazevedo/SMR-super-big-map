local file=assert(io.open('Code/sbm_map_generation.lua','rb'))
local source=file:read('*a');file:close()
local block=assert(source:match('(\t\tif Engine.MapDataEnvironment%(source.mapdata%) == "Surface" then.-)\n\t\tlocal object_transfer_token'))
local gate=assert(source:match('(\tif native_composition_error then ok, migration_error = false, native_composition_error end)'))
for _,case in ipairs({'success','missing','refused','thrown','underground'}) do
 local destination={SuperBigMapSupportIdSequence=5}
 local env=setmetatable({source={mapdata={},SuperBigMapSupportIdSequence=23},destination=destination,
  Engine={MapDataEnvironment=function()return case=='underground' and 'Underground' or 'Surface'end},
  SuperBigMap={DecorationValidation={CaptureNativeCompositions=function()
   if case=='thrown' then error('fixture failure') end
   if case=='missing' then return nil end
   return {captured=case~='refused',candidates=7}
  end}},error=function()end},{__index=_G})
 local fn=assert(load(block..'\nreturn true','native composition pre-transfer gate','t',env))
 env.ok,env.migration_error=pcall(fn)
 assert(load(gate,'native composition outer failure','t',env))()
 if case=='success' then
  assert(env.ok and destination.SuperBigMapNativeCompositionCapture.captured)
  assert(destination.SuperBigMapSupportIdSequence==23,'transferred support identities can collide')
 elseif case=='underground' then
  assert(env.ok and not destination.SuperBigMapNativeCompositionCapture,'surface capture ran underground')
 else
  assert(not env.ok and env.migration_error,'failed capture advertised migration success with log-only error()')
  assert(not destination.SuperBigMapNativeCompositionCapture)
 end
end
print('native composition migration: capture required, support identity sequence transferred, failures explicit')
