# Super Big Map historical best

This directory is the self-contained production payload for the accepted
diagnostics-off Surface baseline measured at **75.8132980 seconds** on
14N134W with the built-in `RoughTerrain` rule and preset.

The payload is the exact reconstructed iteration-266b dirty-worktree identity:
35 files, manifest SHA-256
`334D52B2670017A355DDB5EE84159EDD0CBE7E7EF9DB25ED578A5B914FEC0E45`.
It preserves `LazyUndergroundSourceGeneration=true`, disables diagnostics,
uses coalesced outer-ring publication, and does not use temporary source
backing, seed caching, completed-map caching, or warm reuse.

`payload-manifest.json` authenticates every payload file. The five-run cold
cohort is recorded in `cohort-receipt.json`; its median is 80.9716809 seconds
(5.1583829 seconds above the historical observation) and its sample coefficient
of variation is 2.2057406%, satisfying the corrected six-second/5% consistency
gate. `accepted-receipt-provenance.json` pins the original acceptance receipt.
