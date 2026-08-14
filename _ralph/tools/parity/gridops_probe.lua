-- Verify, in-game, the engine grid ops the full-4/3 Z transform port needs, and run the WHOLE
-- in-zone remap pipeline on a small synthetic grid so it can be compared cell-exactly with the
-- offline reference (`zonefit.py`) instead of trusting undocumented argument conventions.
--
-- Why: the task contract records that GridEnumZones returns labels (not height levels) and that
-- "GridMask argument conventions are unverified -- treat with care (measured failure)". The port
-- must apply a per-massif monotone remap to ~1.5% of an 8192^2 grid, which rules out per-cell Lua;
-- it therefore has to be built out of C-speed grid ops whose exact semantics must be known.
--
-- The synthetic grid deliberately reproduces 42S28W's numbers: interior min 4078 (so the clamped
-- never-lift shift is -437 and src_cap is 49479), a rim ring of artifact zeros that the interior
-- crop must exclude, two overlapping overflow hills that must MERGE into one massif at their base
-- level, one isolated overflow hill, and one hill below the cap that must NOT be touched.
--
-- Pipeline shape under test (what the port will do per massif, on a crop):
--   acc := affine(h) = h*8192/6144 + shift           -- U16; cells above src_cap overflow U16 and
--                                                       are ALWAYS inside a massif, so the massif
--                                                       pass overwrites them (measured below)
--   per massif: lut := GridReplace(h, integer LUT);  acc := GridLerp(acc, lut, component_mask)
-- Composing with Lerp against the running accumulator (not GridMin) keeps overlapping crops and
-- U16-overflowed affine cells correct without depending on saturate-vs-wrap behaviour.
--
-- Writes: __OUT_BASE__.txt (key,value evidence rows), __OUT_BASE__-in.raw (synthetic source,
-- U16), __OUT_BASE__-out.raw (transformed result, U16). Placeholders: __OUT_BASE__.

g_GridOpsStatus = "running"
g_GridOpsInfo = false
g_GridOpsError = false

CreateRealTimeThread(function()
	local ok, err = xpcall(function()
		local out = {}
		local function emit(fmt, ...)
			if select("#", ...) > 0 then
				out[#out + 1] = string.format(fmt, ...)
			else
				out[#out + 1] = fmt
			end
		end
		local checks_ok, checks_total = 0, 0
		local function check(name, want, got, extra)
			checks_total = checks_total + 1
			local pass = tostring(want) == tostring(got)
			if pass then checks_ok = checks_ok + 1 end
			emit("check,%s,%s,want=%s,got=%s,%s", name, pass and "ok" or "FAIL",
				tostring(want), tostring(got), tostring(extra or ""))
			return pass
		end
		local function note(k, ...)
			emit("note,%s,%s", k, table.concat({ ... }, ","))
		end

		local CAP = 65535
		local FLOOR = 5000            -- contract: 5 in-game metres for the lowest interior cell
		local MUL, DIV = 8192, 6144   -- destination / source tiles; exactly 4/3
		local BAND_MULT = 1.0 / 3.0   -- base = src_cap - BAND_MULT * (peak - src_cap)
		local W, H = 192, 192

		-- ---------------------------------------------------------------- synthetic source grid
		local g = NewComputeGrid(W, H, "U", 16)
		if not g then error("NewComputeGrid(U,16) failed") end
		local fmt, bits = IsComputeGrid(g)
		note("grid", string.format("%dx%d", W, H), tostring(fmt), tostring(bits))

		local FLOOR_VAL = 4078        -- 42S28W's measured interior minimum
		local hills = {
			{ name = "A_overflow_tall", cx = 62, cy = 62, r = 46, peak = 62760 },
			{ name = "B_overflow_merges_with_A", cx = 96, cy = 74, r = 40, peak = 55000 },
			{ name = "C_overflow_isolated", cx = 150, cy = 148, r = 28, peak = 51000 },
			{ name = "D_below_cap_untouched", cx = 42, cy = 150, r = 28, peak = 48000 },
		}
		for y = 0, H - 1 do
			for x = 0, W - 1 do
				local v = FLOOR_VAL
				for i = 1, #hills do
					local hi = hills[i]
					local dx, dy = x - hi.cx, y - hi.cy
					local d = math.sqrt(dx * dx + dy * dy)
					if d < hi.r then
						local t = 1.0 - d / hi.r
						local hv = FLOOR_VAL + math.floor((hi.peak - FLOOR_VAL) * t * t + 0.5)
						if hv > v then v = hv end
					end
				end
				-- rim ring of resample-artifact zeros: the interior measurement must exclude it
				if x == 0 or y == 0 or x == W - 1 or y == H - 1 then v = 0 end
				g:set(x, y, v)
			end
		end
		local raw_err = GridSaveRaw("__OUT_BASE__-in.raw", g)
		check("GridSaveRaw_in", "nil", tostring(raw_err))

		-- ---------------------------------------------------------------- min/max conventions
		local fmin, fmax = GridMinMax(g)
		check("full_min_is_rim_artifact", 0, fmin)
		check("full_max_is_tallest_hill", 62760, fmax)

		-- interior measurement by crop-copy (the contract forbids GridFrame-then-MinMax) and a
		-- crop round trip, which the port needs to work on per-massif sub-grids
		local inner = NewComputeGrid(W - 2, H - 2, "U", 16)
		inner:copyrect(g, box(1, 1, W - 1, H - 1), point(0, 0))
		local imin, imax = GridMinMax(inner)
		check("interior_min_excludes_rim", FLOOR_VAL, imin)
		check("interior_max", 62760, imax)
		check("copyrect_cell_matches_source", g:get(5, 7), inner:get(4, 6))
		local paste_probe = GridDest(g)
		paste_probe:copy(g)
		paste_probe:copyrect(inner, box(0, 0, 4, 4), point(10, 10))
		check("copyrect_writeback", g:get(1, 1), paste_probe:get(10, 10))
		paste_probe:free()

		local shift = math.min(0, FLOOR - math.floor((imin * MUL + 0.0) / DIV))
		local src_cap = math.floor(((CAP - shift) * DIV + 0.0) / MUL)
		check("shift_matches_contract", -437, shift)
		check("src_cap_matches_contract", 49479, src_cap)
		note("transform", "shift=" .. shift, "src_cap=" .. src_cap,
			"true_affine_max=" .. (math.floor((imax * MUL + 0.0) / DIV) + shift))

		-- GridMinMax with a mask and with return_offset (documented signature
		-- GridMinMax(grid, mask, scale, return_offset))
		local one = GridDest(g)
		GridMask(g, one, fmax, CAP)        -- mask of the single tallest cell
		local mm_ok, mmin, mmax, moff = pcall(GridMinMax, g, one, 1, true)
		note("GridMinMax_masked_offset", tostring(mm_ok), tostring(mmin), tostring(mmax),
			tostring(moff))
		one:free()

		-- ---------------------------------------------------------------- overflow mask + zones
		local mask = GridDest(g)
		GridMask(g, mask, src_cap + 1, CAP)
		local mask_lo, mask_hi = GridMinMax(mask)
		note("GridMask_range", "min=" .. tostring(mask_lo), "max=" .. tostring(mask_hi))
		local over_cells = GridCount(mask, 1, CAP)
		note("overflow_cells", tostring(over_cells))
		-- independent counts in Lua so GridCount's and GridMask's conventions are pinned down
		local manual, mask_bad = 0, 0
		for y = 0, H - 1 do
			for x = 0, W - 1 do
				local want = (g:get(x, y) > src_cap) and 1 or 0
				if want == 1 then manual = manual + 1 end
				if mask:get(x, y) ~= want then mask_bad = mask_bad + 1 end
			end
		end
		check("GridCount_matches_manual", manual, over_cells)
		check("GridMask_is_binary_in_range", 0, mask_bad)

		local zones = GridEnumZones(mask, 1) or {}
		note("zone_count", tostring(#zones))
		for zi = 1, #zones do
			local keys = {}
			for k, v in pairs(zones[zi]) do keys[#keys + 1] = tostring(k) .. "=" .. tostring(v) end
			table.sort(keys)
			emit("zone_fields,%d,%s", zi, table.concat(keys, ";"))
		end
		check("zones_found", 3, #zones)

		-- after labelling, each zone's cells hold its own level -> GridFind locates one, a masked
		-- GridMinMax reads its peak, and a scan of the (small) zone gives the peak position
		for zi = 1, #zones do
			local z = zones[zi]
			local lvl = z.level
			local fx, fy = GridFind(mask, lvl)
			local zmask = GridDest(mask)
			GridMask(mask, zmask, lvl, lvl)
			local zcount = GridCount(zmask, 1, CAP)
			local zmin, zmax = GridMinMax(g, zmask, 1, false)
			z.peak, z.cells = zmax, zcount
			local px, py
			for y = 0, H - 1 do
				for x = 0, W - 1 do
					if mask:get(x, y) == lvl and g:get(x, y) == zmax then
						px, py = x, y
						break
					end
				end
				if px then break end
			end
			z.px, z.py = px, py
			emit("zone,%d,level=%s,size=%s,find=%s:%s,masked_cells=%s,masked_min=%s,peak=%s,peak_at=%s:%s",
				zi, tostring(lvl), tostring(z.size or z.area), tostring(fx), tostring(fy),
				tostring(zcount), tostring(zmin), tostring(zmax), tostring(px), tostring(py))
			zmask:free()
		end

		-- ---------------------------------------------------------------- massifs (merge by base)
		-- highest peak first; a massif absorbs every zone whose peak lies in its base component
		local order = {}
		for zi = 1, #zones do order[#order + 1] = zi end
		table.sort(order, function(a, b) return (zones[a].peak or 0) > (zones[b].peak or 0) end)
		local absorbed, massifs = {}, {}
		for oi = 1, #order do
			local zi = order[oi]
			if not absorbed[zi] then
				local z = zones[zi]
				local over = math.max(1, z.peak - src_cap)
				local base = math.max(1, src_cap - math.ceil(BAND_MULT * over))
				-- connected component of (h >= base) containing this peak
				local bm = GridDest(g)
				GridMask(g, bm, base, CAP)
				local blabels = GridEnumZones(bm, 1) or {}
				local lvl = bm:get(z.px, z.py)
				local comp = GridDest(bm)
				GridMask(bm, comp, lvl, lvl)
				local carea = GridCount(comp, 1, CAP)
				local cmin, cpeak = GridMinMax(g, comp, 1, false)
				local members = { zi }
				for zj = 1, #zones do
					if zj ~= zi and not absorbed[zj] and comp:get(zones[zj].px, zones[zj].py) == 1 then
						members[#members + 1] = zj
						absorbed[zj] = true
					end
				end
				absorbed[zi] = true
				massifs[#massifs + 1] = {
					members = members, base = base, peak = cpeak, comp = comp,
					area = carea, level = lvl, base_zones = #blabels,
				}
				emit("massif,%d,members=%s,base=%d,seed_zone_peak=%s,comp_peak=%s,comp_cells=%s,comp_min=%s,base_level_zones=%d",
					#massifs, table.concat(members, "+"), base, tostring(z.peak),
					tostring(cpeak), tostring(carea), tostring(cmin), #blabels)
				bm:free()
			end
		end
		check("massifs_after_merge", 2, #massifs)

		-- ---------------------------------------------------------------- affine image (rounding)
		local function true_affine(h) return math.floor((h * MUL + 0.0) / DIV) + shift end
		local acc = GridDest(g)
		acc:copy(g)
		GridMulDivAdd(acc, MUL, DIV, shift)
		local aff_bad, aff_first, u16_over_examples = 0, "", {}
		for y = 1, H - 2 do
			for x = 1, W - 2 do
				local h = g:get(x, y)
				local want = true_affine(h)
				local got = acc:get(x, y)
				if want <= CAP then
					if got ~= want then
						aff_bad = aff_bad + 1
						if aff_first == "" then
							aff_first = string.format("h=%d want=%d got=%d", h, want, got)
						end
					end
				elseif #u16_over_examples < 4 then
					u16_over_examples[#u16_over_examples + 1] =
						string.format("h=%d true=%d u16=%d", h, want, got)
				end
			end
		end
		check("GridMulDivAdd_is_floor_plus_add_in_range", 0, aff_bad, aff_first)
		note("GridMulDivAdd_u16_overflow_behaviour", table.concat(u16_over_examples, ";"))

		-- ---------------------------------------------------------------- per-massif remap
		local function solve_k(Hh, T)
			-- k > 0 with Hh*k/(1-exp(-k*T)) = MUL/DIV  (slope 4/3 at the base: no crease)
			local target = (MUL + 0.0) / DIV
			if T <= 0 or Hh <= 0 then return 0 end
			if (Hh + 0.0) / T >= target then return 0 end
			local function fk(k) return Hh * k / (1.0 - math.exp(-k * T)) - target end
			local hi = 1e-9
			while fk(hi) < 0 do
				hi = hi * 2
				if hi > 1e6 then error("solve_k failed to bracket") end
			end
			local lo = 0.0
			for _ = 1, 200 do
				local mid = 0.5 * (lo + hi)
				if fk(mid) < 0 then lo = mid else hi = mid end
			end
			return 0.5 * (lo + hi)
		end

		for mi = 1, #massifs do
			local m = massifs[mi]
			local base_img = true_affine(m.base)
			local Hh = CAP - base_img
			local T = m.peak - m.base
			local k = solve_k(Hh, T)
			local denom = 1.0 - math.exp(-k * T)
			-- integer LUT for source values base..peak, clamped to the affine so the remap can
			-- only ever LOWER a cell (round-vs-floor can otherwise land 1 unit above it)
			local lut = {}
			local monotone, prev = true, -1
			for h = m.base, m.peak do
				local t = h - m.base
				local img = base_img + math.floor(Hh * (1.0 - math.exp(-k * t)) / denom + 0.5)
				local a = true_affine(h)
				if img > a then img = a end
				if img < prev then monotone = false end
				prev = img
				lut[h] = img
			end
			m.lut = lut
			local lut_grid = GridDest(g)
			lut_grid:copy(g)
			GridReplace(lut_grid, lut)
			local sample_bad, sampled = 0, 0
			local step = math.max(1, math.floor((m.peak - m.base + 0.0) / 16))
			for h = m.base, m.peak, step do
				local fx, fy = GridFind(g, h)
				if fx then
					sampled = sampled + 1
					if lut_grid:get(fx, fy) ~= lut[h] then sample_bad = sample_bad + 1 end
				end
			end
			check("GridReplace_applies_table_massif" .. mi, 0, sample_bad, "sampled=" .. sampled)
			-- merge: keep the running accumulator outside the component, take the remap inside it
			local merged = GridDest(g)
			GridLerp(acc, merged, lut_grid, m.comp, 0, 1)
			local lerp_bad_out, lerp_bad_in, in_cells = 0, 0, 0
			for y = 0, H - 1 do
				for x = 0, W - 1 do
					if m.comp:get(x, y) == 1 then
						in_cells = in_cells + 1
						if merged:get(x, y) ~= lut_grid:get(x, y) then lerp_bad_in = lerp_bad_in + 1 end
					elseif merged:get(x, y) ~= acc:get(x, y) then
						lerp_bad_out = lerp_bad_out + 1
					end
				end
			end
			check("GridLerp_inside_mask_massif" .. mi, 0, lerp_bad_in, "cells=" .. in_cells)
			check("GridLerp_outside_mask_massif" .. mi, 0, lerp_bad_out)
			acc:free()
			acc = merged
			local peak_img = lut[m.peak]
			emit("remap,%d,base=%d,base_img=%d,peak=%d,T=%d,H=%d,k=%.9g,peak_img=%d,monotone=%s,lut_step_at_base=%s,lut_step_at_peak=%s",
				mi, m.base, base_img, m.peak, T, Hh, k, peak_img, tostring(monotone),
				tostring(lut[m.base + 1] and (lut[m.base + 1] - lut[m.base]) or "na"),
				tostring(lut[m.peak - 1] and (lut[m.peak] - lut[m.peak - 1]) or "na"))
			check("massif_peak_lands_on_cap" .. mi, CAP, peak_img)
			check("massif_lut_monotone" .. mi, "true", tostring(monotone))
			lut_grid:free()
		end

		-- ---------------------------------------------------------------- result invariants
		local rmin, rmax = GridMinMax(acc)
		note("result", "min=" .. tostring(rmin), "max=" .. tostring(rmax))
		check("result_max_is_cap", CAP, rmax)
		local outside_bad, inside_bad, inside_high, at_cap, in_cells = 0, 0, 0, 0, 0
		local outside_first, inside_first = "", ""
		for y = 0, H - 1 do
			for x = 0, W - 1 do
				local h = g:get(x, y)
				local v = acc:get(x, y)
				if v == CAP then at_cap = at_cap + 1 end
				local owner
				for mi = 1, #massifs do
					if massifs[mi].comp:get(x, y) == 1 then owner = massifs[mi] break end
				end
				if owner then
					in_cells = in_cells + 1
					if v ~= owner.lut[h] then
						inside_bad = inside_bad + 1
						if inside_first == "" then
							inside_first = string.format("%d:%d h=%d want=%d got=%d", x, y, h,
								owner.lut[h] or -1, v)
						end
					end
					if v > true_affine(h) then inside_high = inside_high + 1 end
				elseif v ~= true_affine(h) then
					outside_bad = outside_bad + 1
					if outside_first == "" then
						outside_first = string.format("%d:%d h=%d want=%d got=%d", x, y, h,
							true_affine(h), v)
					end
				end
			end
		end
		check("outside_zones_exactly_affine", 0, outside_bad, outside_first)
		check("inside_zones_match_lut", 0, inside_bad, inside_first)
		check("inside_zones_never_above_affine", 0, inside_high)
		note("cells_at_cap", tostring(at_cap))
		note("cells_inside_massifs", tostring(in_cells),
			string.format("pct=%.4f", 100.0 * in_cells / (W * H)))

		-- element-wise GridMin, the alternative composition op (recorded, not used above)
		local mtest = GridDest(g)
		local mn_ok, mn_err = pcall(GridMin, acc, mtest, g)
		local mn_bad = 0
		if mn_ok then
			for y = 0, H - 1, 7 do
				for x = 0, W - 1, 7 do
					local want = math.min(acc:get(x, y), g:get(x, y))
					if mtest:get(x, y) ~= want then mn_bad = mn_bad + 1 end
				end
			end
		end
		note("GridMin_elementwise", tostring(mn_ok), tostring(mn_err), "mismatches=" .. mn_bad)
		mtest:free()

		local raw_err2 = GridSaveRaw("__OUT_BASE__-out.raw", acc)
		check("GridSaveRaw_out", "nil", tostring(raw_err2))
		emit("summary,checks_ok=%d,checks_total=%d,massifs=%d,zones=%d", checks_ok, checks_total,
			#massifs, #zones)

		local werr = AsyncStringToFile("__OUT_BASE__.txt", table.concat(out, "\n"))
		if werr then error("write failed: " .. tostring(werr)) end
		g_GridOpsInfo = string.format("checks %d/%d massifs %d zones %d", checks_ok, checks_total,
			#massifs, #zones)
		g_GridOpsStatus = (checks_ok == checks_total) and "ready" or "checks_failed"
	end, debug.traceback)
	if not ok then
		g_GridOpsError = tostring(err)
		g_GridOpsStatus = "error"
	end
end)
return "gridops_probe_started"
