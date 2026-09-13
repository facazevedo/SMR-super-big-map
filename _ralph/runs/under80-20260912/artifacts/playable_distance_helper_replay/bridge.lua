return function(owner)
 local _G=setmetatable({}, {__index=owner,__newindex=owner})
 local function mark_grid_bridge_read(name)
				local direct = rawget(_G, name)
				rawset(_G, name, nil)
				local read_ok, value = pcall(function() return _G[name] end)
				rawset(_G, name, direct)
				return read_ok and value or nil
			end
			local function mark_grid_bridge_write(name, value)
				local direct = rawget(_G, name)
				rawset(_G, name, nil)
				local write_ok = pcall(function() _G[name] = value end)
				local unexpected_direct = rawget(_G, name)
				rawset(_G, name, nil)
				local read_ok, inherited = pcall(function() return _G[name] end)
				rawset(_G, name, direct)
				return write_ok and (unexpected_direct == nil or unexpected_direct == value)
					and read_ok and inherited == value
			end
 return mark_grid_bridge_read,mark_grid_bridge_write
end
