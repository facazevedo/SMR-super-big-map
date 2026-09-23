local f=assert(io.open('Code/sbm_map_generation.lua','r'));local s=f:read('*a');f:close()
local body=assert(s:match('(function SuperBigMap.PrepareTemporarySourceForUnload.-)\nlocal function ReleaseRetainedNativeSourceMap'))
for _,case in ipairs({'owned','no_defer','missing_cancel','failed_cancel','foreign_owner','foreign_process'}) do
	local cancelled,resumed=0,0
	local map={SuspendPassEditsReasons={SuperBigMapVanillaSourceMigration=0},
		SuspendProcessReasons={Passability={PassEdits=0}},SuspendedProcessing={Passability={'pending'}}}
	if case=='foreign_owner' then map.SuspendPassEditsReasons.foreign=0 end
	if case=='foreign_process' then map.SuspendProcessReasons.Other={foreign=0} end
	function map:ResumePassEdits(reason)
		resumed=resumed+1;self.SuspendPassEditsReasons[reason]=nil
		if not next(self.SuspendPassEditsReasons) then self.SuspendProcessReasons.Passability=nil;self.SuspendedProcessing.Passability=nil end
	end
	local function cancel(m,process)
		cancelled=cancelled+1
		assert(process=='Passability' and m==map,'wrong teardown target')
		if case=='failed_cancel' then error('injected native failure') end
		m.SuspendProcessReasons[process]=nil;m.SuspendedProcessing[process]=nil
	end
	local env=setmetatable({SuperBigMap={},Global=function(name) if name=='CancelProcessing' and case~='missing_cancel' then return cancel end end},{__index=_G})
	assert(load(body,'production source teardown','t',env))()
	local ok=env.SuperBigMap.PrepareTemporarySourceForUnload(map,case~='no_defer')
	if case=='owned' then assert(ok and cancelled==1 and resumed==0 and not map.SuspendedProcessing.Passability)
	elseif case=='no_defer' then assert(ok and cancelled==0 and resumed==0)
	elseif case=='foreign_owner' then assert(not ok and cancelled==0 and resumed==1 and map.SuspendPassEditsReasons.foreign==0)
	elseif case=='foreign_process' then assert(not ok and cancelled==0 and resumed==1 and map.SuspendProcessReasons.Other.foreign==0)
	else assert(ok and resumed==1) end
end
print('source teardown: engine cancellation only after final owned use; normal flush fallback and foreign-owner protection')
