# v958 rocket sampling acceptance

Production: `1159341a943f20b863adfe0d88d405c36dfdfd78`, generator guard274,
payload958. The only production algorithm change is rocket height caching and
winner-only relief. Deployed payload matched38/38 files before every launch.

All ten standing rules pass for15S67E,24S74W,45S120W,61N136W and17S11W.
`v958_matrix/verification.json` contains five exact predecessor comparisons with
no issues. Each compares complete Surface/Underground height/pass grids, resource
sites, pad descriptors, grounded-rock transforms and ordinary/private-stream
outputs against the accepted v957 scenario A. Eight automated gates pass at each
site. The raw judge's two review-only fields remain pending by design:

- Seed parity: exact runtime outputs and the RNG/cache-lifetime source review in
  `v958_SOURCE_REVIEW.md` satisfy the separate review requirement. No seed or RNG
  changes, no map-dependent hardcodes, no cached live-clearance decisions.
- Process: every accepted checkpoint identifies1159341/payload958, exact audited
  deployment, distinct fresh PID and creation identity, matching loaded-version
  logs, completed snapshots, clean normal exit and correctly bounded seed pins.
  The finite runner/audit checks these; no foreign process was reused or stopped.

Source review and exact output equality preserve the accepted v957 sampled visual
review, including seamless top-ups, wall/spike repairs and grounded rocks. This
is not a claim that new screenshots were inspected or every possible map tested.
Unexpanded code is unchanged: the five accepted v957 native controls are reused
for authored reveal/imprint comparisons, with a fresh v95814N native control.

The fresh14N benchmark is164.263/162.198/161.749s before and
148.226/149.898/146.075s after: median162.198 ->148.226s, saving13.972s (8.6%).
All three repeated outputs equal the predecessor exactly; reference_audit.json
has no issues. The new native control is28.388s. Five additional correctness
samples are147.265,142.225,132.770,199.791 and139.538s, in the scenario order above.
T0 is immediately before START action body after NewGame; T1 includes surface
completion and post-pipeline revalidation. Diagnostic reads occur after T1.

All54 established offline commands and81,267 scorer regression assertions pass.
The new regression demonstrated red before implementation. Temporary buttons,
previous optimizations and the vanilla-mod installation model are unchanged.

The first new-helper native control capture was incomplete and is preserved
outside the accepted matrix. It was replaced by a fresh complete control, not
reclassified as passing. A bounded read-only post-exit process retry corrected
the new wrapper; it never kills or reuses a process. Ralph remains stopped.
