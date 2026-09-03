@echo off
setlocal
rem Launch Surviving Mars and drop straight into a new expanded game at 14N134W with
rem RoughTerrain and EXPAND MAP already applied - i.e. the state just after START is pressed.
rem
rem Make a desktop shortcut to this file. It deploys the current repo payload first, so the
rem game always loads what is committed; the game only ever reads the Mods folder, never the repo.

set PROJ=D:\PROJS\SMR\super-big-map
set CLI=D:\PROJS\SMR\smr-harness\cli.py

rem The harness will not attach to a game it did not launch: an already-open MarsDebug.exe
rem surfaces as "port is open but not owned by this harness", which reads like a harness fault.
rem Say what to do instead.
tasklist /FI "IMAGENAME eq MarsDebug.exe" 2>nul | find /I "MarsDebug.exe" >nul
if not errorlevel 1 (
  echo [quickstart] Surviving Mars is already running.
  echo [quickstart] Close the game first, then run this shortcut again.
  pause
  exit /b 1
)

echo [quickstart] deploying current payload...
python "%PROJ%\_ralph\tools\deploy.py" sync >nul 2>&1
if errorlevel 1 (
  echo [quickstart] DEPLOY FAILED - run "python _ralph\tools\deploy.py audit" to see why.
  pause
  exit /b 1
)

echo [quickstart] launching the game ^(visible^)...
python "%CLI%" daemon start --visible --timeout 300
if errorlevel 1 (
  echo [quickstart] launch failed.
  pause
  exit /b 1
)

echo [quickstart] starting a new game at 14N134W, RoughTerrain, EXPAND MAP...
python "%CLI%" run-file --timeout 60 "%PROJ%\_ralph\tools\quickstart_14N134W.lua"

echo.
echo [quickstart] generation is running in the game window; it takes about a minute.
echo [quickstart] watch progress with: python "%CLI%" logs
endlocal
