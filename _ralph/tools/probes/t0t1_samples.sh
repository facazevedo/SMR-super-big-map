#!/usr/bin/env bash
# Cold-process T0->T1 samples of the DEPLOYED mod. One fresh MarsDebug.exe per sample.
CLI="D:/PROJS/SMR/smr-harness/cli.py"
LUA="D:/PROJS/SMR/super-big-map/_ralph/tools/probes/t0t1_stopwatch.lua"
N=${1:-3}
grep -n "'version'" "C:/Users/fazevedo/AppData/Roaming/Surviving Mars Relaunched/Mods/super-big-map/metadata.lua"
for i in $(seq 1 "$N"); do
  echo "=== sample $i ==="
  python "$CLI" quit --timeout 30 >/dev/null 2>&1; sleep 2
  python "$CLI" daemon start --hidden --timeout 300 2>&1 | tail -1
  python "$CLI" run-file --timeout 60 "$LUA" >/dev/null 2>&1
  got=""
  for _ in $(seq 1 180); do
    r=$(python "$CLI" eval --timeout 25 "tostring(T0T1)" 2>&1 | head -1)
    case "$r" in nil*|connection*|*"timed out"*) sleep 5;; *) got="$r"; break;; esac
  done
  echo "${got:-NO RESULT (timed out waiting)}"
  python "$CLI" quit --timeout 60 2>&1 | tail -1
  sleep 3
done
echo "=== done ==="
