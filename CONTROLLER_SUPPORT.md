# EXPAND MAP controller action

EXPAND MAP uses the game's native `XAction.ActionGamepad = "ButtonA"` binding.
On the Colony Site screen, press **Cross (×) on PlayStation** or **A on Xbox**
to toggle expansion. Press again to turn it off. The selection underline is
the same one used by the mouse action. Holding the button ignores repeat events.

START retains its vanilla binding: Xbox X / PlayStation Square. Selecting
expansion does not begin generation; START arms the selection, as before.
Normal platform confirm-button remapping and modal-dialog input routing remain
owned by the engine. No global controller hook, polling loop, generation change,
or executable modification is added.

The installed 1.1.0.403908 sources define:

- `CommonLua/Core/locutils.lua`: ButtonA maps to PlayStation Cross (or the
  platform's remapped confirm button). PS5 uses PS5 glyphs; Xbox uses the shared
  Xbox glyph set.
- `Lua/XDef/PGMissionLandingSpotRemastered.generated.lua`: START uses ButtonX.
- `Lua/XDef/MenuEntry.generated.lua`: toolbar entries show native gamepad glyphs.
- `CommonLua/X/XActions.lua`: shortcut dispatch honors IgnoreRepeated.

The regression fixture loads production SBM code and checks the shared binding,
selection/arming parity, reuse, rebuilds and restoration with platform protocol
doubles. It is not a physical-controller or console-hardware test.

## Live verification — 2026-09-19

Passed in the installed Windows debug engine, Lua revision 403908, mod version
999. The test entered the actual Colony Site dialog through vanilla NEXT actions
and injected normalized gamepad shortcuts into the native desktop dispatcher.
It did not emulate a console or use a physical controller.

- EXPAND MAP used `ButtonA`; START remained `ButtonX`.
- Successive confirm events toggled on and off, held-button repeats were ignored,
  and the selection underline followed the state.
- Native button activation used the same selection callback. Toggling alone did
  not arm expansion or start generation.
- A real modal dialog blocked the underlying toggle and hid its underline.
- Removing/reinstalling the action unregistered its shortcut and restored
  exactly one action with the correct binding.
- PS5 UI preview displayed `UI/PS5/Cross.tga` on the actual toolbar button.
  Xbox and Xbox Series preview runs passed the shared input checks. This PC
  build retains desktop A artwork for those preview flags; explicitly resolving
  the Xbox platform returned `UI/Xbox/ButtonA.tga`. This is glyph-resolution
  evidence, not a native Xbox rendering test. Runtime `Platform` flags were not
  modified.

The clean verification session reported no Lua errors. Local evidence is in
`MarsDebug.exe-20260919-15.22.32-6a91a1cb.log`; the disposable setup and live
probes are under `_ralph/tools/compatibility/controller_*.lua` (not mod payload).
All nine compatibility fixture files and Lua syntax checks passed. The installed
local payload matched the repository payload exactly.

Console release validation remains required: loading Lua mods, API availability,
8192-terrain memory/performance, generation, saving and gameplay on the actual
PS5 and Xbox Series builds. A controller binding alone cannot certify the
entire mod on those consoles or make a game build available for Xbox One.
