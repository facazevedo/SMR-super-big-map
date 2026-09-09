# v966 primary-agent source / RNG review

Combined crease candidate includes the exact native translation implementation
reviewed in v965_source_review.md. All invariants in that review remain applicable;
v965's end-to-end benchmark did not qualify, and is not an accepted predecessor.
The acceptance baseline remains v964/5c8ce53.

New refinement: a per-RepairInternalHeightStep cache of quintic coefficients keyed
only by integer span. Original (p-lo+0.0)/span becomes (relative+0.0)/span with the
same integer subtraction result. Every multiplication/addition forming smooth and
both tangent bases has its original grouping/order. The final v0/delta/m0/m1
expression has the original grouping/order, rounding and clamp. Endpoint sampling,
tangent limiting, track order, modified counts and terminal-strip logic are unchanged.
The cache cannot outlive this repair or contain terrain-dependent data. No RNG,
placements, resource masks, object transformations or temporary buttons are changed.

Differential fixture: 102,569 checks over 93 cached widths and repeated changing
endpoints/opposing slopes, all exact; confirms reuse rather than rebuilding. Full
predecessor detector/kernel/order fixture also passes 655,391 checks over 28 tracks.
The new reuse assertion fails on the pre-change source as expected (recorded red).

Two legacy test adaptations are explicit: extraction includes the cache's lexical
declaration, and the historical byte-for-byte feather scope certificate permits
only the literal reviewed basis-hoist rewrite. It still compares the entire body
to the predecessor plus that exact rewrite; all other edits fail. No sampling,
monotonicity, bounds, clipping or rounded-output assertion is removed. The two
initial suite failures are preserved in separate evidence directories, not hidden.

Full offline and cold acceptance evidence is required separately. Source review
does not assert benchmark success, five-site coverage, or new visual screenshots.
