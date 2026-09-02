# Ralph task contract — Rough Terrain revision

## Incorporated optimization contract

Read `_ralph/tasks/surface-loading-under-60s.md` completely before acting. Every
requirement in that contract is incorporated here and remains binding except where
this revision explicitly overrides it. The incorporated file must have SHA-256
`E5E85A5C3103F26B75C8908C2C18E62813651383E43645973ACF386EF32F11BF`; fail closed if
it differs.

This is a new run workspace. Preserve the earlier `surface-loading-under-60s` workspace
as historical evidence, but do not resume it or count any of its 14N134W results.

## Mandatory 14N134W game rule

Every fresh game at **14N134W** must have the built-in **Rough Terrains** game rule
enabled. This applies to the pinned v888 correctness reference, cold baseline, phase
profiles, optimization candidates, visual checks, retries, and all five final timing
samples. Evidence from a 14N134W game generated without this rule is invalid.

After `Game` exists and before random-map preset selection or surface generation, the
automation must perform and verify the equivalent of:

```lua
if type(Game) ~= "table" or type(Game.AddGameRule) ~= "function" then
	error("Rough Terrain benchmark rule requested but Game:AddGameRule is unavailable")
end
Game:AddGameRule("RoughTerrain")
if not IsGameRuleActive("RoughTerrain") then
	error("Rough Terrain benchmark rule did not activate")
end
```

Reuse the fail-closed `ROUGH_TERRAIN_BLOCK` in
`_ralph/tools/parity/run_parity.py` when that harness is used. Passing its exact
`roughterrain` token is mandatory for a 14N134W run. Adding the rule after the source
terrain preset has already been resolved is invalid; the selected random-map preset
must be `RoughTerrain`.

Each 14N134W artifact and timing row must record all of the following:

- coordinate `14N134W`;
- `IsGameRuleActive("RoughTerrain") == true` at generation start and at T1;
- the active game-rule IDs and the selected random-map preset;
- the pinned seed/input hash, commit, mod version, and T0/T1 markers required by the
  incorporated contract.

The automation must fail the sample before accepting evidence if the rule is absent,
the active-rule state cannot be proven, or the preset is not `RoughTerrain`. Do not
silently repair or reinterpret an already generated no-rule surface.

The 30S146E and 45S82E controls retain their incorporated baseline game-rule settings;
this override is specific to 14N134W. Rough Terrains changes only the source scenario
configuration for that coordinate. It does not authorize changing any mod placement,
top-up, spacing, terrain-fixing, outer-ring, audit, determinism, or timing rule.

Capture a new v888/f297615 14N134W reference with Rough Terrains enabled before any
production optimization. All optimized 14N134W results must match that corrected
reference exactly under the incorporated frozen-output contract. A prior reference
captured without Rough Terrains is not a valid comparison target.

## Model and escalation policy

Use `gpt-5.6-sol` with **high** reasoning by default. Extra-high reasoning is permitted
only after the harness detects a sustained measured plateau or for a genuinely major
code refactor. Record the plateau evidence or major-refactor rationale in the append-only
run memory before any extra-high work; preference alone is not an escalation reason.
Progress resets execution to Sol/high. This paragraph overrides any incorporated clause
that would require every strategy or every session to use Sol extra-high.

## Completion override

`DONE.md` is forbidden unless the incorporated eleven-sample performance and exact
equivalence gates pass and all five consecutive 14N134W final samples independently
prove the Rough Terrains activation and `RoughTerrain` preset requirements above.
