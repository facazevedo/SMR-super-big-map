-- Preserve the native generator's actual random draws, including requests that
-- could not fit on its smaller placement grid. No rerolls or debug APIs.
local SBM = rawget(_G, "SuperBigMap")
local Quota = {}
SBM.AnomalyQuota = Quota

function Quota.Begin(generator, env)
	local original = env.rhelpers
	if type(original) ~= "table" or type(original[2]) ~= "function" then
		return function() end
	end
	local fields = { "AnomEventCount", "BonusCountEvent", "AnomTechUnlockCount",
		"AnomFreeTechCount", "BonusCountFreeTech" }
	local kinds = { "sequence", "sequence", "unlock", "complete", "complete" }
	local requested, next_draw, valid = {}, 1, true
	local helpers = {}
	for k, v in pairs(original) do helpers[k] = v end
	helpers[2] = function(range, ...)
		local value = original[2](range, ...)
		-- OnGenerateLogic draws these five quotas before its first procedure.
		-- Verify the range identities/order; an incompatible generator must not
		-- turn an unrelated random draw into an invented anomaly quota.
		if valid and next_draw <= #fields then
			if range ~= generator[fields[next_draw]] or type(value) ~= "number"
				or value < 0 or value ~= math.floor(value) then
				valid = false
			else
				local kind = kinds[next_draw]
				requested[kind] = (requested[kind] or 0) + value
				next_draw = next_draw + 1
			end
		end
		return value
	end
	env.rhelpers = helpers
	env.map.SuperBigMapRequestedAnomalies = false
	return function(success)
		if env.rhelpers == helpers then env.rhelpers = original end
		if success and valid and next_draw > #fields then
			env.map.SuperBigMapRequestedAnomalies = requested
		end
	end
end

function Quota.Targets(requested, source, current, standard_current, factor)
	local targets = {}
	for kind, count in pairs(current) do targets[kind] = count end
	for _, kind in ipairs({ "complete", "unlock", "sequence" }) do
		local native = source[kind] or 0
		local demand = type(requested) == "table" and requested[kind] or nil
		if type(demand) == "number" and demand >= 0 and demand == math.floor(demand) then
			native = math.max(native, demand)
		end
		local special = math.max(0, (current[kind] or 0) - (standard_current[kind] or 0))
		if native > 0 or current[kind] ~= nil then
			targets[kind] = special + math.floor(native * factor + 0.5)
		end
	end
	return targets
end
