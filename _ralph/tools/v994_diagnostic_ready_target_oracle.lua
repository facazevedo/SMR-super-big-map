-- Executable lifecycle model for the process-local ready-target diagnostic bridge.
local installs, materializations, green_receipts = 0, 0, 0
local State = {}
local function publish(surface, descriptor, report)
	assert(type(surface) == "table" and type(descriptor) == "table" and type(report) == "table")
	assert(descriptor.state == "ready-for-first-access")
	State.ready = { surface=surface, descriptor=descriptor, report=report }
end
local function install(surface, descriptor, report, state_surface, maps2)
	local target = State.ready
	local exact = type(target) == "table" and target.surface == surface
		and target.descriptor == descriptor and target.report == report
		and state_surface == surface and surface.descriptor == descriptor
		and surface.report == report and descriptor.state == "ready-for-first-access"
		and descriptor.attempts == 0 and descriptor.generation == 0 and not maps2
	if not exact then return false end
	installs = installs + 1
	return true
end
local function materialize(surface, diagnostic)
	local target = State.ready
	if diagnostic and (type(target) ~= "table" or target.surface ~= surface
		or target.descriptor ~= surface.descriptor or target.report ~= surface.report) then
		return false
	end
	if type(target) == "table" and target.surface == surface then State.ready = nil end
	materializations = materializations + 1
	return true
end
local function block(surface)
	if State.ready and State.ready.surface == surface then State.ready = nil end
end

local descriptor = { state="ready-for-first-access", attempts=0, generation=0 }
local report = {}
local surface = { descriptor=descriptor, report=report }
local debugger_reference = { surface_stable_published=true }
assert(debugger_reference.surface == nil) -- the iter236 lookup was invalid by construction
publish(surface, descriptor, report)
assert(install(surface, descriptor, report, surface, false))

local other_surface = { descriptor=descriptor, report=report }
assert(not install(other_surface, descriptor, report, surface, false))
assert(not install(surface, {}, report, surface, false))
assert(not install(surface, descriptor, {}, surface, false))
assert(not install(surface, descriptor, report, other_surface, false))
assert(not install(surface, descriptor, report, surface, {}))

local saved = State.ready
State.ready = nil
assert(not install(surface, descriptor, report, surface, false)) -- loaded ready is not same-session
assert(materialize(surface, false)) -- ordinary loaded-ready materialization remains allowed
State.ready = saved
assert(materialize(surface, true) and State.ready == nil)
publish(surface, descriptor, report)
block(surface)
assert(State.ready == nil)

-- Stage control flow: a failed identity path cannot publish a green arm receipt.
local function stage_arm(identity_ok, install_ok)
	if not identity_ok then return false end
	if not install_ok then return false end
	green_receipts = green_receipts + 1
	return true
end
assert(not stage_arm(false, true) and not stage_arm(true, false))
assert(stage_arm(true, true))

print("ok=true")
print("debugger_reference_surface_absent=true")
print("published_ready_target_exact=true")
print("wrong_surface_descriptor_report_state_maps_rejected=5")
print("loaded_ready_diagnostic_install_rejected=true")
print("loaded_ready_ordinary_materialization_allowed=true")
print("target_consumed_on_materialization=true")
print("target_cleared_on_block=true")
print("failed_arm_green_receipts=0")
print("successful_arm_green_receipts=" .. tostring(green_receipts))
print("installs=" .. tostring(installs))
print("materializations=" .. tostring(materializations))
