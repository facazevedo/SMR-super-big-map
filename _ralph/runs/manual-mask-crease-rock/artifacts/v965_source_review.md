# v965 primary-agent source / RNG review

Native translation batches independent rows within one already-selected crease
track. Discovery, selection/ties, scalar refinement, track order, narrow monotone
quintic feathering, terminal-strip repair, clipping and source repair are unchanged.
Refinement and joins access only their own along-row. Each track is fully translated
and feathered before later tracks read the live grid. No placement or RNG changes.

The U16 kernel validates integer extents, row independence and physical-edge
anchoring. Odd boundaries and even coordinate ramps implement exact inclusive
extents. Exact doubling copyrect replication avoids native resampling quantization.
F32 sums are exact for the bounded U16 operands, then clamp to the original maximum.
Singleton padding retains original heights. Scratch is released on both success and
failure. Failure is explicit and prevents publication of the private height grid.

Rejected mixed-format row arithmetic and nominal-identity resampling probes are
retained as failed evidence, not shipped. The final native kernel passes 16 cases,
including 8192-row strips in both axes/directions, with zero full-grid differences
and identical modified counts (native_track_probe2/result.json). Scratch aggregate
time was 948ms scalar versus 265ms native; this is not a START-to-T1 measurement.

All 63 offline commands pass. Primitive test: 69,125 assertions including production
integration/failure routing. Full scalar predecessor versus batched detector/kernel/
order test: 655,391 assertions over 28 overlapping tracks. Existing full-size guard
fixtures retain all original assertions; a scalar-storage adapter represents the
native backend, separately covered by kernel and real-native tests. No gate weakened.

Rock grounding, resource masks, placements, private/game RNG, temporary UI buttons,
terrain Z policy and final rebuild/revalidation timing have no changes in this unit.
Cold full-output/process evidence is required separately before acceptance; no new
visual screenshot sign-off is claimed by this source review.
