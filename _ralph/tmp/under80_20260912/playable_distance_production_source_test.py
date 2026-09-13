"""Actual helper identity and supported transaction ordering, not native proof."""
from pathlib import Path
import subprocess
root=Path(__file__).resolve().parents[3]
source=(root/'Code/sbm_map_generation.lua').read_text()
begin='-- BEGIN NATIVE PLAYABLE DISTANCE CACHE.'
end='-- END NATIVE PLAYABLE DISTANCE CACHE.'
assert source.count(begin)==source.count(end)==1
helper=source[source.index(begin)+len(begin):source.index(end)].strip()
private=Path(__file__).with_name('playable_distance_helper.lua').read_text().strip()
assert helper==private.replace('return function(generator,class,read,write)',
 'function SuperBigMap.InstallNativePlayableDistanceCache(generator,class,read,write)',1)
for forbidden in ('debug.', 'getfenv', 'math.random', 'stream.rand', 'GridStableRandomPos', 'Config.'):
 assert forbidden not in helper,forbidden
assert "GridCount(delta,0,2147483647)" in helper
assert "scope.dest_source==src" in helper and "scope.thread==thread()" in helper
assert "originals.GridOr(scope.place,src,scope.bounds)" in helper
assert "w*h*6*4>16777216" in helper
install=source.index('local distance_close, distance_stats, distance_failure')
call=source.index('local results = { pcall(CallWithClutterCapture, map,',install)
close=source.index('local close_ok, good, why = pcall(distance_close)',call)
mark=source.index('local mark_restore_ok = mark_grid_bridge_write',close)
serial=source.index('local serial_restore_ok, serial_restore_error',mark)
maps=source.index('map.Width = saved_map_width',serial)
failure=source.index('if distance_failure then return nil end',maps)
assert install<call<close<mark<serial<maps<failure
assert 'GENERATOR_PATCH_VERSION = 306' in (root/'Code/sbm_version.lua').read_text()
assert "'version', 994" in (root/'metadata.lua').read_text()
changed=subprocess.check_output(['git','diff','--name-only','56fbf44','--','Code','Images','metadata.lua','items.lua'],cwd=root,text=True).splitlines()
assert sorted(changed)==['Code/sbm_map_generation.lua','Code/sbm_version.lua','metadata.lua'],changed
print('PASS v994 actual helper identity, bounded source/thread scope and transaction ordering')
