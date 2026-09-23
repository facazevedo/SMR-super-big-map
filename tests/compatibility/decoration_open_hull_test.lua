SuperBigMap={Engine={Global=function()end}}
dofile('Code/sbm_decoration_geometry.lua')
local G=SuperBigMap.DecorationGeometry
local geometry={vertices={{0,0,0},{2,0,0},{0,2,0},{0,0,2}}}
local component={bounds={0,0,0,2,2,2},vertices={1,2,3,4},triangles={{1,2,4},{1,4,3},{2,3,4}}}
assert(G.PointOutsideComponentHull(geometry,component,{1,1,1}),'oblique outside point inside AABB was missed')
assert(G.PointInClosedComponent(geometry,component,{1,1,1})==false,'open hull separation must return proven outside')
assert(G.PointInClosedComponent(geometry,component,{.1,.1,.1})==nil,'open hull interior must remain ambiguous')
assert(not G.PointOutsideComponentHull(geometry,component,{1,1,0}),'shared boundary is not separated')
assert(not G.PointOutsideComponentHull(geometry,component,{1,1,1e-10}),'numerical boundary must remain conservative')
geometry.vertices[5]={3,3,3};component.vertices[5]=5
assert(not G.PointOutsideComponentHull(geometry,component,{1,1,1}),'a face plane without all-vertex exclusion is not a hull proof')
geometry.vertices[5]=nil;component.vertices[5]=nil
component.triangles={{1,3,2},{1,2,4},{1,4,3}}
assert(G.PointOutsideComponentHull(geometry,component,{1,1,1}),'missing oblique hull face needs a new separating direction')
assert(not G.PointOutsideComponentHull(geometry,component,{.2,.2,.2}),'convex interior cannot be excluded')
print('open mesh hull: complete separating projections, no inferred volume, strict conservative boundaries')
