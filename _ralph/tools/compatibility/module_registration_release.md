# Editor module-registration repair (2026-09-21)

The published/editor-saved v1001 metadata had 30 code entries. Commit c2265fc
registered 35 in metadata.lua, but its items.lua registered only 30. Native
ModDef:UpdateCode rebuilds metadata.code from the items on an editor save.

Restored the five entries in both files in the existing 35-module load order.
Preserved the user's beta title and service IDs/version fields. Version 1004
includes the two native metadata-save increments during authoring verification.
No gameplay Lua or image changed. Native regenerated code_hash is
5502837756813861146.

## Evidence and limits

- module_registration_test.lua failed on the original missing item registration,
  then passed with 35 entries in identical order. All 46 host compatibility
  fixtures and payload Lua syntax passed.
- The authoritative deployment tool now rejects a current release with missing
  required modules, mismatched registration order, duplicate items or absent files
  before copying. Explicit historical benchmark snapshots retain their old policy.
- Native ModDef:UpdateCode preserves the 35-entry order. Module loading is checked
  through Mods.SuperBigMap.env.SuperBigMap, not the raw engine global namespace.
- Native DbgPackMod with the existing session-only image-compression workaround
  packed/unpacked all 43 files identically; the unpacked manifests pass the same
  35-entry registration check. No upload was invoked.
- The initial SaveWholeMod probe was invalid: it ran without a GED editor and
  logged missing editor/parent-cache assertions. Its later raw-global check was
  also incorrect. Its failed report/log are preserved; it is NOT an editor-save
  certification. The helper now requires an open editor and uses the mod namespace.
- Computer Use could not connect to its native pipe after retry/reset. A clean
  full editor save and actual Steam/Paradox republication still require the editor.

Artifacts: _ralph/tmp/registration_1002/ and
_ralph/tmp/packaging_344/registration_1004*. JSON reports are local test evidence,
not included in the downloadable mod.

No new scenario/timing measurement. Last validated c2265fc primary single run:
START -> T1 97.468 s, underground preparation 60.037 s. These measurements do not
certify the previously published 30-module configuration.
