# Incomplete process gate - preserved, not accepted

15S67E process40436 / FILETIME134334564947317750 completed its rules report and
post-rules snapshot, but quit(0) did not terminate it within60 seconds. Subsequent
DAP connection timed out. Diagnostics found no crash/assert signature and verified
the exact owned process. Cause is not established. The CLI's exact-handle stop
terminated only that process after preserving diagnostics; no foreign game existed.
engine_terminated.log is NOT a normal flushed-shutdown acceptance log.

The original v964_matrix directory was renamed to v964_matrix_shutdown_failed;
all reports, snapshot and process identity remain. A new full five-site matrix
is run separately on the unchanged committed/deployed5c8ce53 candidate. This run
cannot be counted as an accepted process. Native scratch experiments affect only
private grids in separate main-menu processes, not these map artifacts.
