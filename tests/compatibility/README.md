# 1.1 compatibility regression fixtures

Run each fixture in a separate Lua 5.3+ process from the repository root:

```powershell
Get-ChildItem tests/compatibility -Filter '*_test.lua' | ForEach-Object {
    lua $_.FullName
    if ($LASTEXITCODE -ne 0) { throw $_.Name }
}
```

These tests exercise the production implementation with protocol doubles. They
cover allocation isolation, native delegation, real-path query semantics,
environment and footprint API changes, terrain write ownership/padding, forced
mask replacement, bounded class-query varargs, and discovery at initial placement
(including a prohibition on whole-map discovery sweeps, save-state defaults,
pending-only scans, and underground/vanilla isolation). They do not replace live
engine generation, movement, obstacle, save/load, or first-underground-access
tests. Live evidence and limitations are recorded in `COMPATIBILITY_1_1.md`.

The fixtures are not mod payload and do not alter the installed game.
