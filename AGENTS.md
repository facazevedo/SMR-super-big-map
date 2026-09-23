# Runtime testing order

The owner requires the slowest cases to be tested first in every regression or
optimization round. Rank scenarios by their worst measured surface START-to-T1
time, using underground loading time as a secondary ordering criterion. Use
current evidence and retain the exact difficult seeds; do not substitute easier
draws. The current first priorities are 17S11W, then 61N136W.

The latest accepted build 462 order is 17S11W, 61N136W, 24S74W, 45S120W, 15S67E,
then 14S36W (worst measured surface times 74.955, 74.386, 72.808, 68.696, 66.965,
66.877 seconds). Refresh this ranking from current evidence before a new round;
do not keep a stale order when newer measurements change it. Include save/reload
qualification of the slowest case before moving on to faster cases.

When changing order during a running batch, let the owned native game finish and
close cleanly, then reorder subsequent launches. Keep completed evidence; do not
restart already-passed identical-payload cases solely to change their order.
