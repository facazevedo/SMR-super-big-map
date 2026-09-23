SuperBigMap={Engine={Global=function()end},DecorationGeometry={}}
dofile('Code/sbm_decoration_validation.lua')
local V=SuperBigMap.DecorationValidation
local before={complete=true,signature='verified bytes and native materials',parent=false,
 components={root={supported=true},piece={supported=false,defect=true}}}
local after={complete=true,signature=before.signature,parent=false,
 components={root={retained=true,frame_preserved=true},piece={retained=false,frame_preserved=true}}}
local ok,count=V.CompareComposition(before,after)
assert(ok and count==1,'classify inherited authored fragment separately from a new expansion gap')
before.components.piece.defect=false
assert(not V.CompareComposition(before,after),'inconclusive native support must never exempt a current defect')
before.components.piece.defect=true
assert(V.Classify({{supported=true},{defect=true,reason='native gap'}},true,false)=='confirmed defect',
 'composition comparison must not rewrite the physical-support result')
after.components.root.retained=false
assert(not V.CompareComposition(before,after),'a newly lost terrain or stacked support must fail')
after.components.root.retained=true;after.components.piece.frame_preserved=false
assert(not V.CompareComposition(before,after),'same asset with changed fragment pose must fail')
after.components.piece.frame_preserved=true;after.signature='modified vertices'
assert(not V.CompareComposition(before,after),'same filenames with changed geometry must fail')
after.signature=before.signature;after.complete=false
assert(not V.CompareComposition(before,after),'missing geometry remains unverified')
after.complete=true;after.parent='new parent'
assert(not V.CompareComposition(before,after),'attachment changes cannot pass')
after.parent=false;after.components.new_piece={frame_preserved=true}
assert(not V.CompareComposition(before,after),'new fragment must fail')
after.components.new_piece=nil;after.components.piece=nil
assert(not V.CompareComposition(before,after),'unexplained missing fragment must fail')
after.clipped={piece=true};assert(V.CompareComposition(before,after),'complete verified clipping is explicit evidence')
after.components.root=nil;after.clipped.root=true
assert(not V.CompareComposition(before,after),'an entirely unsupported native assembly is not validated')
print('composition: independent physical status, immutable geometry and pose, native roots, missing-data and mutation vetoes')
