# Headless game control (provider-neutral)

Operational facts verified live on 2026-09-01 from a Claude Code session. They hold for any
Ralph session provider; nothing here is agent-specific. Verifying these again costs a game
launch, so read them instead of rediscovering them.

## Launch, drive, tear down

```powershell
# Launch hidden. Reports ready_s, rev, and menu:true when the main menu is interactive.
python D:\PROJS\SMR\smr-harness\cli.py daemon start --json --hidden --timeout 300

# Submit work. This is the same mechanism the acceptance executor uses for T0.
python D:\PROJS\SMR\smr-harness\cli.py run-file --json --timeout 30 <script.lua>

# Tear down and prove nothing survives.
python D:\PROJS\SMR\smr-harness\cli.py quit --json
```

Measured: hidden launch reaches an interactive menu in about 15 s (`ready_s` 14.4, port open
after 7.6 s). `quit` reports `tracked_stopped` with an empty `untracked_pids`; confirm
`Get-Process MarsDebug` is empty afterwards, because the acceptance contract requires a
zero-process teardown.

`--hidden` passes `-hidden` to `MarsDebug.exe` alongside `-nointro -no_interactive_asserts
-stdout`. There is no separate headless mode to enable, and
`_ralph/tools/execute_surface_only_acceptance.ps1` already starts the daemon this way, so a
timing run needs no launch changes.

## Reaching the mod

The mod runs in its own sandbox environment. `rawget(_G, "SuperBigMap")` is **nil** — at the
main menu and generally. Use the production access path:

```lua
local mod
for _, candidate in ipairs(ModsLoaded or {}) do
    if candidate.id == "SuperBigMap" then mod = candidate break end
end
local SBM = (mod and mod.env and mod.env.SuperBigMap) or rawget(_G, "SuperBigMap")
if type(SBM) ~= "table" then error("SuperBigMap mod environment not found") end
```

Engine globals (`GenerateRandomMap`, `ChangeMap`, `AsyncStringToFile`) *are* reachable directly
from a `run-file` chunk. `Game` and `CurrentMap` are `false` until a game exists.

Confirmed live at the menu: `mod.version` 1011, `GENERATOR_PATCH_VERSION` 316,
`SECTOR_PATCH_VERSION` 74, `EXPANDED_TERRAIN_TILES` 8192, `MAX_RANDOM_GENERATOR_TILES` 6144,
`LAZY_UNDERGROUND_SOURCE_GENERATION` true, and exactly two mods loaded
(`Toggle Console Log Off`, `Super Big Map`).

## Script conventions that avoid debug-build noise

- Wrap work in `CreateRealTimeThread(function() ... end)` with an `xpcall` inside, as the
  production generator does. A bare chunk cannot yield.
- Declare a new global with `rawset(_G, name, value)` before ordinary assignment. The debug
  build logs a `[LUA ERROR]` strict-global notice for a first ordinary assignment even though
  the assignment succeeds.
- Return evidence by writing a sentinel file with `AsyncStringToFile`, then read it from the
  host. Do not poll game state during a timed interval.

## CLI argument quirks

- `eval` wraps its argument in `return <expr>`, so pass an **expression only** — a leading
  `return` or a `local` declaration is a syntax error.
- `exec` takes statements but returns nothing useful; strict-global assignment inside it will
  not publish a value for a later `eval`.
- Prefer `run-file` with a real `.lua` file for anything beyond one expression.
- There is no `smr status`. `daemon status` exits 3 with `running: false` when idle, so treat
  exit 3 as "idle", not as a failure.

## Deployment

Only `python _ralph/tools/deploy.py sync|audit`. Audit must report `ok: true` with empty
`missing_in_destination`, `stale_in_destination`, and `content_mismatch`. The current payload is
35 files at `%APPDATA%\Surviving Mars Relaunched\Mods\super-big-map`. A `content_mismatch` list
means the working tree is ahead of what the running game would load — the game uses the
deployed copy, never the repository.

## Effort ladder and the `Progress:` line

The supervisor drives one effort ladder per provider from
`_ralph/runtime/overnight-super-big-map/cycles.jsonl`, which it appends after every cycle.

| Provider | Model | Ordinary rung | Escalated rung |
|---|---|---|---|
| `claude` | `claude-opus-5` | `high` | `max` (the UI's "Extra high") |
| `codex` | `gpt-5.6-sol` | `xhigh` | `xhigh` (historical constant) |

Claude Code's effort values are exactly `low`, `medium`, `high`, `max` — verified in the CLI
bundle (`["low","medium","high","max"]` in the value list, the `supportedEffortLevels` enum, and
the `applied.effort` enum), with the top rung gated on model support. There is no `xhigh`; that is
the Codex spelling. The supervisor accepts `-Effort xhigh` for Claude and maps it to `max` so one
operator habit works for both providers.

Escalation is ledger-derived and restart-safe: two consecutive worked cycles without
`Progress: yes` escalate the next cycle; one `Progress: yes` resets to the ordinary rung; a
missing line counts as no progress. Launch failures (provider outage) are recorded with
`launch_failure: true` and skipped entirely, so a quota outage cannot escalate the ladder.
`-NoAdaptiveEffort` pins the ordinary rung; `-Effort <tier>` pins one constant tier and disables
the ladder; `-StagnantCyclesBeforeEscalation` changes the threshold.

Every iteration must therefore end its final message with one `Progress: yes|no` line. The
supervisor reads the **last** match in the message, so quoting the convention earlier is safe.
