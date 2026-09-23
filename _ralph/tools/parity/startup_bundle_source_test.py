"""Current combined owner ordering and unchanged gameplay payload contract."""
from pathlib import Path
import subprocess
root=Path(__file__).resolve().parents[3]
def old(path):
    return subprocess.check_output(['git','show','1c75b81:'+path],cwd=root).replace(b'\r\n',b'\n')
# The v996 whole-file gameplay freeze was superseded by later authorized
# optimizations. Preserve the unchanged cache oracle and owner/write contracts;
# gameplay equivalence belongs to the behavioral fixtures and cold-game checks.
s=(root/'Code/sbm_map_generation.lua').read_text()
baseline=old('Code/sbm_map_generation.lua').decode()
start='-- BEGIN NATIVE PLAYABLE DISTANCE CACHE.'
end='-- END NATIVE PLAYABLE DISTANCE CACHE.'
assert s[s.index(start):s.index(end)]==baseline[baseline.index(start):baseline.index(end)]
i=s.index('local distance_close, distance_stats, distance_failure')
f=s.index('local filler_close, filler_stats, filler_failure',i)
c=s.index('local results = { pcall(CallWithClutterCapture, map,',f)
fc=s.index('local close_ok, good, why = pcall(filler_close)',c)
dc=s.index('local close_ok, good, why = pcall(distance_close)',fc)
restore=s.index('local mark_restore_ok = mark_grid_bridge_write',dc)
failure=s.index('if distance_failure or filler_failure then return nil end',restore)
assert i<f<c<fc<dc<restore<failure
helper=s[s.index('-- BEGIN NATIVE FILLER MASK CACHE'):s.index('-- END NATIVE FILLER MASK CACHE.')]
assert 'GridCount(delta, 0, 2147483647)' in helper
assert 'originals.GridCircleSet(scope.place_guard, value, center, radius)' in helper
assert 'originals.GridCircleSet(entry.eligible, value, center, radius)' in helper
for forbidden in ('debug.', 'getfenv', 'math.random', 'stream.rand', 'GridStableRandomPos', 'Config.'):
    assert forbidden not in helper
print('PASS startup owner nesting, unit-delta guards and unchanged distance cache')
