-- Headless acceptance probe: reveal/deep-scan only the final physical two-sector surface band,
-- then ask production code for the placed-object census.  It deliberately derives the band from
-- the live 20x20 sector grid and never refers to a map name, coordinate, seed, or sector label.
rawset(_G, "g_OuterRingRevealStatus", "running")
rawset(_G, "g_OuterRingRevealError", false)
rawset(_G, "g_OuterRingRevealPassed", false)
rawset(_G, "g_OuterRingRevealSummary", false)

CreateRealTimeThread(function()
	local ok, err = xpcall(function()
		local mod
		for _, candidate in ipairs(ModsLoaded or {}) do
			if candidate.id == "SuperBigMap" then mod = candidate break end
		end
		local sbm = (mod and mod.env and mod.env.SuperBigMap) or rawget(_G, "SuperBigMap")
		local deposits = sbm and sbm.DepositRules
		if type(deposits) ~= "table" then error("SuperBigMap DepositRules unavailable") end
		local map
		for _, candidate in ipairs(Maps or {}) do
			if candidate and candidate.mapdata and candidate.mapdata.Environment == "Surface" then
				map = candidate
				break
			end
		end
		local city, grid = map and map.City, map and map.City and map.City.MapSectors
		if not map or type(grid) ~= "table" then error("surface sector grid unavailable") end
		local min_col, max_col, min_row, max_row
		local sectors = {}
		for _, column in pairs(grid) do
			if type(column) == "table" then
				for _, sector in pairs(column) do
					if type(sector) == "table" and type(sector.col) == "number"
						and type(sector.row) == "number" then
						sectors[#sectors + 1] = sector
						min_col = min_col and math.min(min_col, sector.col) or sector.col
						max_col = max_col and math.max(max_col, sector.col) or sector.col
						min_row = min_row and math.min(min_row, sector.row) or sector.row
						max_row = max_row and math.max(max_row, sector.row) or sector.row
					end
				end
			end
		end
		if not (min_col and max_col and min_row and max_row) then error("no live surface sectors") end
		-- Structural pre-reveal census is intentionally marker-backed; the post scan census below
		-- switches production code into its placed-object acceptance mode.
		local _, before = deposits.CensusFinalOuterResourceTopUps(map,
			"headless pre-outer-deep-scan", false)
		local registered_anomaly_markers = {}
		for _, sector in ipairs(sectors) do
			for _, marker_list in pairs(sector.markers or {}) do
				if type(marker_list) == "table" then
					for _, marker in ipairs(marker_list) do
						if marker and marker.SuperBigMapAnomalyTopUp == true then
							registered_anomaly_markers[marker] = true
						end
					end
				end
			end
		end
		local registered_anomalies = 0
		for _ in pairs(registered_anomaly_markers) do registered_anomalies = registered_anomalies + 1 end
		local scanned, failed = 0, 0
		for _, sector in ipairs(sectors) do
			local outer = sector.col <= min_col + 1 or sector.col >= max_col - 1
				or sector.row <= min_row + 1 or sector.row >= max_row - 1
			if outer then
				local scan_ok = type(sector.Scan) == "function"
					and pcall(sector.Scan, sector, "deep scanned", nil)
				if scan_ok and sector.status == "deep scanned" then scanned = scanned + 1 else failed = failed + 1 end
			end
		end
		if failed ~= 0 then error("outer sector deep scan failed: " .. tostring(failed)) end
		Sleep(2000) -- allow revealed deposits and their deferred lifecycle work to settle.
		local census_ok, census = deposits.CensusFinalOuterResourceTopUps(map,
			"headless post-outer-deep-scan", true)
		local audit_ok, audit = deposits.AuditSurfaceTopUpPlacement(map)
		local function breakdown(values)
			local rows = {}
			for key, value in pairs(values or {}) do rows[#rows + 1] = tostring(key) .. "=" .. tostring(value) end
			table.sort(rows)
			return #rows > 0 and table.concat(rows, "+") or "none"
		end
		local terrain_audit = map.SuperBigMapOuterResourceTerrainAudit
		local cluster_plan = map.SuperBigMapResourceClusterPlanDiagnostic or {}
		g_OuterRingRevealSummary = string.format(
			"scanned=%d pre_resources=%d post_resources=%d placed=%d outermost_resources=%d guaranteed_outermost=%d guaranteed_outermost_placed=%d outermost_minimum=%d resources=[%s] anomalies=%d/%d anomaly_placed=%d registered_anomalies=%d anomaly_types=[%s] outside=%d effects_in_ring=%d effect_types=[%s] terrain_resources=%s terrain_modified=%s rocket_pads=%s rocket_modified=%s verified_mountain_pads=%s terrain_failures=%s/%s failure_reasons=[%s/%s] first_failures=[%s/%s] audit_violations=%s shortfall=%d outermost_shortfall=%d inner_band=%d/%d inner_shortfall=%d quota=%d/%d clusters=%s[%s-%s] cluster_shortfall=%s cluster_excess=%s cluster_resources=%s-%s resource_excess=%s cluster_extractors=%s-%s extractor_excess=%s anomaly_cluster_max=%d anomaly_cluster_overflow=%d cluster_total_max=%d cluster_total_overflow=%d cluster_plan=%s:%s:%s/%s/%s count=%s/%s required=%s/%s/%s results=[%s]",
			scanned, before.ordinary_resource_topups or -1, census.ordinary_resource_topups or -1,
			census.ordinary_resource_topups_placed or -1,
			census.ordinary_resource_topups_outermost or -1,
			census.guaranteed_resource_topups_outermost or -1,
			census.guaranteed_resource_topups_outermost_placed or -1,
			census.outermost_minimum or -1,
			breakdown(census.resource_breakdown),
			census.anomaly_topups or -1, census.anomaly_topups_total or -1,
			census.anomaly_topups_placed or -1, registered_anomalies,
			breakdown(census.anomaly_breakdown),
			census.anomaly_topups_outside_ring or -1, census.effect_topups or -1,
			breakdown(census.effect_breakdown),
			map.SuperBigMapOuterResourceTerrainReport
				and tostring(map.SuperBigMapOuterResourceTerrainReport.resources) or "n/a",
			map.SuperBigMapOuterResourceTerrainReport
				and tostring(map.SuperBigMapOuterResourceTerrainReport.resource_sites_modified) or "n/a",
			map.SuperBigMapOuterResourceTerrainReport
				and tostring(map.SuperBigMapOuterResourceTerrainReport.rocket_pads) or "n/a",
			map.SuperBigMapOuterResourceTerrainReport
				and tostring(map.SuperBigMapOuterResourceTerrainReport.rocket_pads_modified) or "n/a",
			map.SuperBigMapOuterResourceTerrainAudit
				and tostring(map.SuperBigMapOuterResourceTerrainAudit.verified_modified_mountain_rocket_pads)
				or "n/a",
			map.SuperBigMapOuterResourceTerrainAudit
				and tostring(map.SuperBigMapOuterResourceTerrainAudit.resource_failures) or "n/a",
			map.SuperBigMapOuterResourceTerrainAudit
				and tostring(map.SuperBigMapOuterResourceTerrainAudit.rocket_failures) or "n/a",
			map.SuperBigMapOuterResourceTerrainAudit
				and breakdown(map.SuperBigMapOuterResourceTerrainAudit.resource_failure_breakdown)
				or "n/a",
			map.SuperBigMapOuterResourceTerrainAudit
				and breakdown(map.SuperBigMapOuterResourceTerrainAudit.rocket_failure_breakdown)
				or "n/a",
			map.SuperBigMapOuterResourceTerrainAudit
				and tostring(map.SuperBigMapOuterResourceTerrainAudit.first_resource_failure) or "n/a",
			map.SuperBigMapOuterResourceTerrainAudit
				and tostring(map.SuperBigMapOuterResourceTerrainAudit.first_rocket_failure) or "n/a",
			audit and tostring(audit.violations) or "n/a",
			census.shortfall or -1, census.outermost_shortfall or -1,
			census.guaranteed_resource_topups_inner_band_placed or -1,
			census.inner_band_minimum or -1, census.inner_band_shortfall or -1,
			census.guaranteed_resource_topups_placed or -1, census.minimum or -1,
			terrain_audit and tostring(terrain_audit.resource_clusters) or "n/a",
			terrain_audit and tostring(terrain_audit.cluster_minimum) or "n/a",
			terrain_audit and tostring(terrain_audit.cluster_maximum) or "n/a",
			terrain_audit and tostring(terrain_audit.cluster_shortfall) or "n/a",
			terrain_audit and tostring(terrain_audit.cluster_excess) or "n/a",
			terrain_audit and tostring(terrain_audit.minimum_cluster_resources) or "n/a",
			terrain_audit and tostring(terrain_audit.maximum_cluster_resources) or "n/a",
			terrain_audit and tostring(terrain_audit.cluster_resource_excess) or "n/a",
			terrain_audit and tostring(terrain_audit.minimum_cluster_extractors) or "n/a",
			terrain_audit and tostring(terrain_audit.maximum_cluster_extractors) or "n/a",
			terrain_audit and tostring(terrain_audit.cluster_extractor_excess) or "n/a",
			census.maximum_anomalies_in_resource_cluster or -1,
			census.anomaly_resource_cluster_overflow or -1,
			census.maximum_total_members_in_resource_cluster or -1,
			census.cluster_total_member_overflow or -1,
			(tostring(cluster_plan.stage or "missing") .. "/"
				.. tostring(cluster_plan.strategy or "legacy")),
			tostring(cluster_plan.error or ""),
			tostring(cluster_plan.quota or 0), tostring(cluster_plan.outermost or 0),
			tostring(cluster_plan.inner_band or 0), tostring(cluster_plan.placed_clusters or 0),
			tostring(cluster_plan.desired_clusters or 0), tostring(cluster_plan.required or 0),
			tostring(cluster_plan.outermost_required or 0),
			tostring(cluster_plan.inner_required or 0), tostring(cluster_plan.results or ""))
		local terrain_ok = terrain_audit ~= nil
			and terrain_audit.resource_failures == 0
			and terrain_audit.rocket_failures == 0
			and terrain_audit.cluster_shortfall == 0
			and terrain_audit.cluster_excess == 0
			and terrain_audit.cluster_resource_shortfall == 0
			and terrain_audit.cluster_resource_excess == 0
			and terrain_audit.cluster_extractor_shortfall == 0
			and terrain_audit.cluster_extractor_excess == 0
			and (census.cluster_total_member_overflow or 0) == 0
		g_OuterRingRevealPassed = census_ok == true and audit_ok == true and terrain_ok
		if g_OuterRingRevealPassed ~= true then
			g_OuterRingRevealError = "outer ring placed-object gate failed: " .. g_OuterRingRevealSummary
			g_OuterRingRevealStatus = "error"
			return
		end
	end, debug.traceback)
	if not ok then
		g_OuterRingRevealError = tostring(err)
		g_OuterRingRevealStatus = "error"
		return
	end
	if g_OuterRingRevealStatus == "error" then return end
	g_OuterRingRevealStatus = "complete"
end)
return "outer_ring_reveal_started"
