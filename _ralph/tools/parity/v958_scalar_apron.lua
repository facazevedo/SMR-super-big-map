-- Immutable scalar raster extracted from production 1159341 (v958), not an alternate oracle.
return function(grid, selected, policy)
	local apron_floor, apron_ceil = math.floor, math.ceil
	local apron_min, apron_max, apron_sqrt = math.min, math.max, math.sqrt
	local width, height = grid:size()
	local outer_short, outer_long, core_fraction = policy.outer_short, policy.outer_long, policy.core_fraction
	local modified = 0
	local shaped = 0
	local ok_apply, apply_error = pcall(function()
		for index, candidate in ipairs(selected) do
			-- An already-flat mountain base is a zero-edit opportunity. Retain its original terrain
			-- exactly; only marginal sites enter the feathered shaping loop below.
			if candidate.requires_edit then
				shaped = shaped + 1
				-- Vary scale and lobe phase deterministically by sector; there is no random-stream cost.
				local variant = ((candidate.sector_x * 17 + candidate.sector_y * 31
					+ index * 13) % 9) - 4
				local short_radius = outer_short * (1 + variant * 0.012)
				local long_radius = outer_long * (1 - variant * 0.009)
				local x0 = apron_max(0, apron_floor(candidate.x - long_radius - 2))
				local y0 = apron_max(0, apron_floor(candidate.y - long_radius - 2))
				local x1 = apron_min(width - 1, apron_ceil(candidate.x + long_radius + 2))
				local y1 = apron_min(height - 1, apron_ceil(candidate.y + long_radius + 2))
				for y = y0, y1 do
					for x = x0, x1 do
						local dx, dy = x - candidate.x, y - candidate.y
						local u = dx * candidate.mountain_x + dy * candidate.mountain_y
						local v = -dx * candidate.mountain_y + dy * candidate.mountain_x
						local ru, rv = u / short_radius, v / long_radius
						local radius = apron_sqrt(ru * ru + rv * rv)
						if radius < 1.12 then
							local nx, ny = 1, 0
							if radius > 0.0001 then nx, ny = ru / radius, rv / radius end
							local lobe3 = nx * nx * nx - 3 * nx * ny * ny
							local lobe2 = nx * nx - ny * ny
							local boundary = 1 + 0.055 * lobe3 + 0.035 * lobe2
							local normalized = radius / boundary
							if normalized < 1 then
								local weight
								if normalized <= core_fraction then
									weight = 1
								else
									local t = (normalized - core_fraction) / (1 - core_fraction)
									local smooth = t * t * t * (t * (t * 6 - 15) + 10)
									weight = 1 - smooth
								end
								local old = grid:get(x, y)
								if type(old) == "number" then
									local target = candidate.center
										+ candidate.gx * dx + candidate.gy * dy
									local detail = old - target
									local detail_retention = 1 - weight * weight * weight
									local value = apron_floor(target
										+ detail * detail_retention + 0.5)
									value = apron_max(0, apron_min(65535, value))
									if value ~= old then
										grid:set(x, y, value)
										modified = modified + 1
									end
								end
							end
						end
					end
				end
			end
		end
	end)
	return ok_apply, {modified=modified, shaped=shaped}, apply_error
end
