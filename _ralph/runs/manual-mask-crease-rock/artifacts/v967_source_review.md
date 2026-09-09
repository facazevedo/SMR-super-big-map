# v967 primary-agent source / RNG review

Baseline: accepted v966/56b8a1f. The full derivation is in rock_source_review.md.
Cache only immutable bounding-box scalars/visual coordinates during one non-yielding
Capture. Reuse original Y-coordinate arithmetic across X columns. Reject a ray only
when ground<source_z+((min_z-tile)-visual_z), proving even the original segment bottom
cannot be a supported contact. Keep equality and all original remaining conditions,
coordinates, ray endpoints, contact order, rounding and formulas.

The per-rock Apply implementation is byte-for-byte unchanged. No shared lowering,
terrain edits, resizing, rotation, XY movement, gameplay-object eligibility changes,
RNG calls or seed handling changes. Earlier masks, crease repairs, resource rules,
entrance handling, temporary buttons and final revalidation are untouched.

The actual candidate passes 1,443 differential assertions over360 fixtures, checking
complete native-contact records, individual lowering, final positions/contact census,
and unchanged Apply source. Geometry scalar calls66,645->2,493; capture rays13,093->12,350.
The predecessor fails the new work-reduction assertion, recorded separately. Existing
grounding and all prior regression checks remain required with no assertion changes.

This source review is separate from offline results, fresh START-to-T1 measurements,
five-scenario full-output comparisons and exact process/deployment signoff. No new
visual screenshot claim; inherited visual evidence requires complete output identity.
