@echo off
setlocal
rem Launch Surviving Mars and drop straight into a new expanded game at 14N134W with
rem RoughTerrain and EXPAND MAP already applied - i.e. the state just after START is pressed.
rem
rem Make a desktop shortcut to this file. It deploys the current repo payload first, so the
rem game always loads what is committed; the game only ever reads the Mods folder, never the repo.

set PROJ=D:\PROJS\SMR\super-big-map
set CLI=D:\PROJS\SMR\smr-harness\cli.py

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
