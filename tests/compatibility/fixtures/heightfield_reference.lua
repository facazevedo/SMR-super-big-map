-- Frozen build 1205 clipping reference for parity tests; never loaded by the mod.
local Geometry={}
local function Finite(n)return type(n)=="number" and n==n and n>-math.huge and n<math.huge end
local function Bounds()return {math.huge,math.huge,math.huge,-math.huge,-math.huge,-math.huge}end
local function Extend(b,p)for i=1,3 do b[i]=math.min(b[i],p[i]);b[i+3]=math.max(b[i+3],p[i])end end
function Geometry.TrianglesAboveHeightfield(triangles,height,tile,width,height_limit,error_bound,budget,extrema)
	if #triangles==0 or not Finite(tile) or tile<=0 or not Finite(error_bound) or error_bound<0
		or not Finite(width) or not Finite(height_limit) or width<=0 or height_limit<=0 then return false end
	local remaining=budget or 4096
	local minimum,maximum=math.huge,-math.huge
	local function clip(poly,a,b)
		local dx,dy=b[1]-a[1],b[2]-a[2]
		local padding=error_bound*(math.abs(dx)+math.abs(dy))
		local function side(p)return dx*(p[2]-a[2])-dy*(p[1]-a[1])+padding end
		local out={};local previous=poly[#poly]
		if not previous then return out end
		local before=side(previous)
		for _,current in ipairs(poly) do
			local after=side(current)
			if (before>=0)~=(after>=0) then
				local t=before/(before-after)
				out[#out+1]={previous[1]+t*(current[1]-previous[1]),previous[2]+t*(current[2]-previous[2]),previous[3]+t*(current[3]-previous[3])}
			end
			if after>=0 then out[#out+1]=current end
			previous,before=current,after
		end
		return out
	end
	for _,triangle in ipairs(triangles) do
		if #triangle~=3 then return false end
		local bounds=Bounds()
		for _,p in ipairs(triangle) do
			for a=1,3 do if not Finite(p[a]) then return false end end
			Extend(bounds,p)
		end
		local x0=math.floor((bounds[1]-error_bound)/tile)*tile
		local y0=math.floor((bounds[2]-error_bound)/tile)*tile
		local x1=math.floor((bounds[4]+error_bound)/tile)*tile
		local y1=math.floor((bounds[5]+error_bound)/tile)*tile
		if x0<0 or y0<0 or x1+tile>=width or y1+tile>=height_limit then return false end
		for x=x0,x1,tile do for y=y0,y1,tile do
			remaining=remaining-1;if remaining<0 then return false end
			local h00,h10,h01,h11=height(x,y),height(x+tile,y),height(x,y+tile),height(x+tile,y+tile)
			if not Finite(h00) or not Finite(h10) or not Finite(h01) or not Finite(h11) then return false end
			local corners={{x,y},{x+tile,y},{x+tile,y+tile},{x,y+tile}}
			for half=1,2 do
				local face=half==1 and {corners[1],corners[2],corners[3]} or {corners[1],corners[3],corners[4]}
				local poly=triangle
				for i=1,3 do poly=clip(poly,face[i],face[i%3+1]) end
				local gx,gy
				if half==1 then gx,gy=(h10-h00)/tile,(h11-h10)/tile
				else gx,gy=(h11-h01)/tile,(h01-h00)/tile end
				local margin=error_bound*(1+math.abs(gx)+math.abs(gy))
				local roundoff=1e-7*math.max(1,math.abs(h00),math.abs(h10),math.abs(h01),math.abs(h11))
				for _,p in ipairs(poly) do
					local clearance=p[3]-(h00+gx*(p[1]-x)+gy*(p[2]-y))
					if extrema then
						-- Proposal callers only need extrema when the WHOLE mesh floats.
						-- A nonpositive witness disproves that immediately. Full extrema
						-- mode remains available to the placement planner, including gaps
						-- below terrain; successful positive scans still visit every face.
						if extrema=="positive" and clearance<=0 then return false end
						minimum=math.min(minimum,clearance);maximum=math.max(maximum,clearance)
					elseif clearance<=margin+roundoff then return false end
				end
			end
		end end
	end
	if extrema then return minimum>0,minimum,maximum end
	return true
end

return Geometry.TrianglesAboveHeightfield
