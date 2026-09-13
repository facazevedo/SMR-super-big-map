-- Add only twelve coarse phase switches to one source function. No module reload.
return function(source)
 local edits={}
 local function before(anchor,phase)
  local a,b=source:find(anchor,1,true)
  if not a or source:find(anchor,b+1,true)then return false,'ambiguous bootstrap anchor: '..phase end
  local inserted='\tbootstrap_phase("'..phase..'")\n'
  source=source:sub(1,a-1)..inserted..source:sub(a)
  edits[#edits+1]={anchor=anchor,inserted=inserted,phase=phase}
  return true
 end
 local specs={
  {'\tlocal map = env and env.map\n','preflight'},
  {'\tlocal wonder_markers = ArtefactMapGet(map, "BuriedWonderMarker")','wonder_assignment'},
  {'\tmap:SuspendPassEdits("SuperBigMap_NativeWonderClearance")','native_wonder_clearance'},
  {'\tlocal native_resume_ok, native_resume_err = pcall(','native_wonder_resume'},
  {'\tlocal spawn_surface_anchor = Global("SpawnUndergroundPassage")','surface_bridge_setup'},
  {'\tlocal padded_surface_grid = new_grid(expanded_hex_w, expanded_hex_h, 16, unbuildable_z)','surface_bridge_copy'},
  {'\tsurface_map.buildable.z_grid = padded_surface_grid','surface_bridge_bind'},
  {'\tlocal successful = {}','passage_spawn_clearance'},
  {'\tlocal resume_ok, resume_err = pcall(map.ResumePassEdits, map, "SuperBigMap_PassageBootstrap")','passage_resume'},
  {'\tRestoreSurfaceBuildableBridge()\n\tif not ok or err ~= true or not resume_ok then','surface_bridge_restore'},
  {'\tlocal plan_ok, plan_stats = AlignPassagePairsToSharedHex(map, { source_bootstrap = true })','common_hex_planning'},
  {'\tif not VerifyBootstrapPassages(map, successful, desired_passages) then','verification'},
 }
 for _,spec in ipairs(specs)do local ok,why=before(spec[1],spec[2]);if not ok then return nil,why end end
 return source,edits
end
