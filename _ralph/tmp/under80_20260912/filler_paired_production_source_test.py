"""Scope/transaction guard, not a proof of native correctness or speed."""
from pathlib import Path
import subprocess
root=Path(__file__).resolve().parents[3]
source=(root/'Code/sbm_map_generation.lua').read_text()
begin='-- BEGIN NATIVE FILLER MASK CACHE'
end='-- END NATIVE FILLER MASK CACHE.'
assert source.count(begin)==source.count(end)==1
helper=source[source.index(begin):source.index(end)+len(end)]
for forbidden in ('debug.', 'getfenv', 'math.random', 'stream.rand', 'GridStableRandomPos', 'Config.'):
 assert forbidden not in helper, forbidden
assert 'math.type(from) == "integer"' in helper
assert 'dst:copy(entry.grid)' in helper and 'originals.GridMask(src, dst, from, to, scale)' in helper
assert 'GridAddMulDiv(delta, expected, -1)' in helper and 'GridAbs(delta)' in helper
assert 'scope.dest_input == src' in helper and 'src == scope.source' in helper
assert helper.count('stats.pair_byte_bound')==1
install=source.index('local filler_close, filler_stats, filler_failure')
call=source.index('local results = { pcall(CallWithClutterCapture, map,',install)
close=source.index('local close_ok, good, why = pcall(filler_close)',call)
mark=source.index('local mark_restore_ok = mark_grid_bridge_write',close)
serial=source.index('local serial_restore_ok, serial_restore_error',mark)
maps=source.index('map.Width = saved_map_width',serial)
failure=source.index('if filler_failure then return nil end',maps)
assert install<call<close<mark<serial<maps<failure
assert 'GENERATOR_PATCH_VERSION = 305' in (root/'Code/sbm_version.lua').read_text()
assert "'version', 993" in (root/'metadata.lua').read_text()
changed=subprocess.check_output(['git','diff','--name-only','56fbf44','--','Code','metadata.lua','items.lua'],cwd=root,text=True).splitlines()
assert sorted(changed)==['Code/sbm_map_generation.lua','Code/sbm_version.lua','metadata.lua'],changed
assert subprocess.check_output(['git','show','56fbf44:Code/sbm_terrain_copy.lua'],cwd=root).replace(b'\r\n',b'\n')==(root/'Code/sbm_terrain_copy.lua').read_bytes().replace(b'\r\n',b'\n')
assert 'scope.pending.destination and other == scope.place' in helper
assert 'originals.GridCircleSet(scope.place_guard, value, center, radius)' in helper
assert 'originals.GridCircleSet(entry.eligible, value, center, radius)' in helper
assert 'dst:copy(entry.eligible)' in helper and 'originals.GridAnd(dst, other)' in helper
assert 'scope.place_guard' in helper and 'compare_guard(scope.place, scope.place_guard' in helper
assert '33554432 / (w * h * 8)' in helper
assert '(2 * scope.capacity + 4) * w * h * 4' in helper
assert helper.index('wrappers.GridOpFree = function') < helper.index('start_wrapper = function')
print('PASS actual v993 source scope, native transactions, integer/ownership guard and accepted terrain preservation')


