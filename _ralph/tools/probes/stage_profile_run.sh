#!/usr/bin/env bash
# One cold-process, per-stage profile of the DEPLOYED super-big-map build at 14N134W.
# Boots a hidden game, injects stage_profile_14N134W.lua (which turns on the mod's built-in loading
# timer without redeploying), waits for T1, saves the game log next to this script's output dir,
# prints the T0->T1 line, and quits the game.
#   usage: stage_profile_run.sh [out_dir]     (default: _ralph/tmp/stage_profile)
# Parse the saved log with: python _ralph/tools/probes/parse_stage_profile.py <log>
CLI="D:/PROJS/SMR/smr-harness/cli.py"
HERE="$(cd "$(dirname "$0")" && pwd)"
LUA="$HERE/stage_profile_14N134W.lua"
OUT="${1:-D:/PROJS/SMR/super-big-map/_ralph/tmp/stage_profile}"
mkdir -p "$OUT"
STAMP=$(date +%Y%m%d-%H%M%S)
VER=$(grep -o "'version', [0-9]*" "C:/Users/fazevedo/AppData/Roaming/Surviving Mars Relaunched/Mods/super-big-map/metadata.lua" | grep -o "[0-9]*$")
echo "deployed version: $VER"
python "$CLI" quit --timeout 30 >/dev/null 2>&1; sleep 2
python "$CLI" daemon start --hidden --timeout 300 2>&1 | tail -1
python "$CLI" run-file --timeout 60 "$LUA" >/dev/null 2>&1
got=""
for _ in $(seq 1 60); do
  r=$(python "$CLI" eval --timeout 25 "tostring(STAGE_PROFILE_T0T1)" 2>&1 | head -1)
  case "$r" in nil*|connection*|*"timed out"*|*"could not"*) sleep 15;; *) got="$r"; break;; esac
done
echo "${got:-NO RESULT (timed out waiting)}"
LOG="$OUT/stage_profile_v${VER}_${STAMP}.log"
python "$CLI" logs --tail 6000 > "$LOG" 2>&1
echo "log: $LOG ($(grep -c LoadingTiming "$LOG") LoadingTiming lines)"
python "$CLI" quit --timeout 60 2>&1 | tail -1
