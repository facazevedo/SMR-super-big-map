# Under-80-second optimization, 2026-09-12

User requested implementation after the feasibility assessment. Target: reference
14N134W and five existing validation scenarios below 80 seconds, measured from START
through required surface post-pipeline revalidation. All current rules, geometry
corrections, seeded placement, individual rock support, and temporary buttons stay.
No automatic Ralph process is running. Primary agent owns this investigation.

Starting HEAD fe39258, clean production worktree; runtime is accepted v972/guard288
(67fa4ab), 38/38 deployed files match. Accepted reference median 102.488s; 61N136W
150.018s. Old experiment artifacts remain unchanged. New evidence lives here.

Initial diagnostic `v972_profile_reference`: old setup returned PROFILE_ERROR
because source anchors did not match CRLF text. No replacement source was executed;
the driver continued generation. Preserve capture/parity and normal shutdown, but
do not call this an instrumented profile or mix it into declared timing acceptance.
New setup normalizes line endings and times source/destination creases and natural
aprons, in addition to the existing rocket/raster splits. Fresh successful profiles
of the reference and 61N136W are next.

Rejected earlier work to respect: exact dirty-region union reduced regional calls
but did not establish end-to-end improvement; final rebuild deferral broke read
dependencies; float32 crease joins differed in rounding. No blind reuse of those.
