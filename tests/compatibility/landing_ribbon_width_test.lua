-- Owner 2026-10-03: on the Colony Site screen EXPAND MAP must not widen the decorations. The
-- title strip keeps vanilla's width, and the THREATS / RESOURCES ribbon ends at the last letter
-- of the widest name. Windows are plain tables with the fields the module reads.
local function B(x1,y1,x2,y2)
  return {x1=x1,y1=y1,x2=x2,y2=y2,minx=function(b)return b.x1 end,miny=function(b)return b.y1 end,
    maxx=function(b)return b.x2 end,sizex=function(b)return b.x2-b.x1 end,sizey=function(b)return b.y2-b.y1 end}
end
local function W(props,children)
  local w=props or {};for i,c in ipairs(children or {}) do w[i]=c;c.parent=w end
  w.scale=w.scale or 1;w.box=w.box or B(0,0,0,0)
  w.SetLayoutSpace=function(self,x,y,width,height) self.space={x,y,width,height}
    self.box=B(x,y,x+width,y+height) end
  w.GetEffectiveMargins=function() return 0,0,0,0 end
  w.SetBox=function(self,x,y,width,height) self.box=B(x,y,x+width,y+height) end
  w.InvalidateLayout=function(self) self.invalidated=(self.invalidated or 0)+1 end
  return w
end
local sbm={State={},Engine={Global=function(name)
  if name=='ScaleXY' then return function(scale,v) return v*scale end end end,Unpack=table.unpack}}
local env=setmetatable({SuperBigMap=sbm},{__index=_G});env._G=env
assert(loadfile('Code/sbm_pregame_toggle.lua','t',env))()
local toggle=sbm.PregameToggle

local strip=W({Dock='box',MinHeight=70},{W({Image='UI/CommonRemaster/title_pad.png'})})
local concrete=W({Id='idName',content_box=B(400,0,568,20)})
local metals=W({Id='idName',content_box=B(400,30,540,50)})
local hidden=W({Id='idName',visible=false,content_box=B(400,60,900,80)})
local ribbon=W({Dock='box',Image='UI/CommonRemaster/pg_header_small.png',box=B(-10,0,609,40)})
local row=W({content_box=B(0,0,600,300)},{ribbon,W({},{concrete,metals,hidden})})
local button=W({Id='idsuper_big_map_expand',measure_width=103})
local toolbar=W({LayoutHSpacing=60,scale=0.5},{button})
toolbar.ResolveId=function(self,id) return id=='idsuper_big_map_expand' and button or nil end
local bar=W({Id='idActionBar',measure_width=537,idToolBar=toolbar},{toolbar})
local context=W({measure_width=510})
local titles=W({measure_width=500})
local container=W({measure_width=537},{titles,context,bar})
local dialog=W({idActionBar=bar},{strip,row,container})

assert(toggle.InstallVanillaWidthDecorations(dialog)==2)
-- Title strip: the bar without EXPAND (537-103-30=404) is narrower than the text column (510),
-- so EXPAND adds 537-510=27 and the strip gets exactly that much less space.
strip:SetLayoutSpace(0,0,676,70)
assert(strip.space[3]==649,'title strip keeps vanilla width: '..strip.space[3])
-- When the bar without EXPAND is the widest child, only EXPAND's own width is removed.
context.measure_width,titles.measure_width=300,300
strip:SetLayoutSpace(0,0,676,70)
assert(strip.space[3]==676-(537-404),'only EXPAND width removed: '..strip.space[3])
context.measure_width,titles.measure_width=510,500
-- Ribbon: after the row's layout completes it ends at the widest visible name plus the image's
-- transparent edge (11 at scale 1), and later layout passes keep that edge.
row:OnLayoutComplete()
assert(ribbon.box:maxx()==579 and ribbon.box:minx()==-10,'ribbon placed at Concrete: '..ribbon.box:maxx())
ribbon:SetLayoutSpace(0,0,700,40)
assert(ribbon.box:maxx()==579,'later passes keep the edge')
-- Idempotent install, then full restore.
assert(toggle.InstallVanillaWidthDecorations(dialog)==2)
toggle.RestoreVanillaWidthDecorations(dialog)
assert(rawget(strip,'SetLayoutSpace')==nil and rawget(ribbon,'SetLayoutSpace')==nil and rawget(row,'OnLayoutComplete')==nil)
print('landing ribbon: title strip at vanilla width, ribbon ends at the widest name, restore clean')
