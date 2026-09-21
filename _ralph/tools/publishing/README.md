# Temporary publishing workaround

Authoring-side only, for the native blkPageCompress assertion reproduced while
compressing SBM's preview JPEG on game revision 403908. Both Steam and Paradox
use the same CreatePackageForUpload path. This tool stores non-Lua files unchanged
and compresses Lua, scoped to SBM's upload archive. It never initiates an upload.

Keep this directory outside the deployed mod. Do not register the helper in
metadata.lua or items.lua. The payload deployment script excludes all _ralph files.

With other game instances closed, run from D:/PROJS/SMR/smr-harness:

```text
python cli.py daemon start --visible
python cli.py run-file D:/PROJS/SMR/super-big-map/_ralph/tools/publishing/install_workaround.lua
```

Use the editor in that SAME game process for publishing. The helper survives the
uploader's ReloadLua calls, but NOT an application restart. A restarted editor
needs installation again. Retail Mars.exe has no debug adapter; do not try to
inject into it or launch a second game while it is running.

The helper's restore() function restores the original functions only if no other
tool replaced the hooks. Closing this game process also removes the workaround.

Verification: run `lua tests/compatibility/publishing_workaround_test.lua` from
the mod project. Native verification must pack/unpack the complete payload,
compare every file and check the flushed game log for the native assertion;
a disabled interactive assertion dialog is not evidence of a successful pack.
