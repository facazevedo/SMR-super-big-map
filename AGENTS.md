# Runtime testing order

The owner requires the slowest cases to be tested first in every regression or
optimization round. Rank scenarios by their worst measured surface START-to-T1
time, using underground loading time as a secondary ordering criterion. Use
current evidence and retain the exact difficult seeds; do not substitute easier
draws. The current first priorities are 61N136W, then 24S74W.

Timings are measured in the owner's release-equivalent mode (2026-09-24): the
runner's default `--debug-hooks release` gives game threads the release build's
debug hook instead of the harness debugger's call/return/line hook, and rejects
runs where that cannot be verified. Never compare them with older debugger-hook
timings. Rock seating must finish before T1.

The metadata 1100 order is 61N136W, 24S74W, 17S11W, 45S120W, 14S36W, then 15S67E
(release-mode surface times 73.790, 71.528, 71.258, 62.131, 60.141, 59.930
seconds). Refresh this ranking from current evidence before a new round;
do not keep a stale order when newer measurements change it. Include save/reload
qualification of the slowest case before moving on to faster cases.

When changing order during a running batch, let the owned native game finish and
close cleanly, then reorder subsequent launches. Keep completed evidence; do not
restart already-passed identical-payload cases solely to change their order.
