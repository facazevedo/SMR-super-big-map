-- The shipped shader payload for complete underground darkness: the five sources under Shaders/
-- carry the mark helpers at every stage, and ShaderCache/ holds the zero-byte bypass entries
-- for the reflection shaders (never the darkness shader, which stays vanilla).
local checks = 0
local function check(ok, message) assert(ok, message); checks = checks + 1 end
local function read(path)
	local f = io.open(path, "rb"); if not f then return nil end
	local s = f:read("*a"); f:close(); return s
end

-- Every stage is gated on the per-frame flag (hr.MeshDebugParam2 == SBM_MARK_FLAG): with the flag
-- off, no store is marked, SbmIsMarked is false (so every decode is the identity), and the two
-- manual samplings fall back to the vanilla hardware sample expressions.
local files = {
	["SbmReflectionMark.fh"] = { "SbmEncodeMark", "SbmDecodeMark", "SbmIsMarked", "16384.0f", "64.0f",
		"#define SBM_MARK_FLAG 1396853041", "return MeshDebugParam2 == SBM_MARK_FLAG;",
		"return SbmMarkingOn() && max(v.x, max(v.y, v.z)) >= SBM_MARK_THRESHOLD;" },
	["Reflections.fx"] = { '#include "SbmReflectionMark.fh"', "SbmStoreValue(pixPos", "all(equal(own_color, broadcast3(0.0f)))",
		"\tBRANCH\n\tif (!SbmMarkingOn())\n\t\treturn rgb;" },
	["ReflectionDenoising.fx"] = { '#include "SbmReflectionMark.fh"', "own_marked", "SbmDecodeMark(tex2DFetch(ReflectionMap" },
	["ReflectionConvolution.fx"] = { '#include "SbmReflectionMark.fh"', "SbmSample2x2", "SbmDecodeMark(tex2DFetch(Input",
		"if (!SbmMarkingOn())\n\t\t\treturn tex2DLod(Input, uv, 0, LinearClampCS).xyz;" },
	["ApplyReflections.fx"] = { '#include "SbmReflectionMark.fh"', "if (SbmIsMarked(tex2DFetchLod(ReflectionMap, sbm_own, 0).xyz))", "DISCARD",
		"SbmMarkingOn() && lod < 1.0f",
		"SbmMarkingOn() ? sbm_l0 : tex2DLod(ReflectionMap, screen, 0, TrilinearClampPS).xyz" },
}
for name, needles in pairs(files) do
	local s = read("Shaders/" .. name)
	check(s, "shipped shader source missing: Shaders/" .. name)
	for _, n in ipairs(needles) do
		check(s:find(n, 1, true), name .. " lacks: " .. n)
	end
	check(not s:find("\r", 1, true), name .. " must use LF line endings")
end
-- The trace must not store an unmarked value anywhere: every store of the reflection texture
-- goes through SbmStoreValue.
local trace = read("Shaders/Reflections.fx")
for line in trace:gmatch("[^\n]*RW_textureStore%(Reflections,[^\n]*") do
	check(line:find("SbmStoreValue", 1, true), "unmarked reflection store: " .. line)
end

-- Cache bypass entries: the 47 distinct cache entries the 81 reflection-chain variants of the
-- shipped game resolve to (defines that do not change the program share an entry), all zero bytes.
local count, nonzero = 0, 0
local p = io.popen('dir /b "ShaderCache"')
for name in p:lines() do
	if name:match("^%d+$") then
		count = count + 1
		local f = assert(io.open("ShaderCache/" .. name, "rb"))
		if #f:read("*a") ~= 0 then nonzero = nonzero + 1 end
		f:close()
	end
end
p:close()
check(count == 47, "expected 47 cache bypass entries, found " .. count)
check(nonzero == 0, "cache bypass entries must be zero bytes")
check(not read("ShaderCache/12784368302082105887"), "the darkness shader's cache entry must not be bypassed")
print("underground darkness payload: " .. checks .. " checks passed")
