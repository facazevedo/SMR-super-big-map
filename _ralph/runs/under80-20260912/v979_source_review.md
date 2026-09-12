# v979 immediate rock classification reuse

Compared with accepted v978 (3eafc30), only RockGrounding eligibility and its
immediate AnnotateDecorRelief caller change, plus guard294/version979. The caller
has just evaluated both shared exclusions as false. Only a private array append
intervenes: no object mutation, terrain query, engine call or yield. It supplies
the checked predicate identities; the receiver reuses the result only when both
still match its dynamically read Clone fields. Default callers and rebound
classifiers retain the original checks. This is not a class/map/object cache.

All scale, parent, entity/material, geometry, source terrain, native rays, support,
lowering, placement and failure handling remain unchanged. No RNG call, traversal,
coordinate, native terrain arithmetic, transaction or passability stage changes.
START and T1 and the scheduled post-pipeline revalidation remain unchanged; no work
moves after readiness. Existing terrain fixes and temporary debug buttons remain.

The predecessor oracle compares complete private capture records, native query
arguments, final positions, stamps and stats across qualified/default callers,
exclusions, parent/glued/pose cases, classifier rebinding and ray failures.
892079 exact checks pass; the fixture removes546 repeated predicate calls.

Before promotion, the non-deployed diagnostic classification_profile_reference
completed with full predecessor terrain/placement/private-stream/individual-rock
parity and zero grounding failures. Surface annotation2138ms, underground849ms;
diagnostic START-to-T1=88.538s is not a cold acceptance result. Owned PID48692
normally quit with full flushed logs. Candidate upvalues were joined to original
private cells; production does not use that diagnostic instrumentation.

Require77 offline commands and immutable cold reference3/control/five-site runs.
No sub80 claim follows from this source review. Inherited visual equivalence must
be supported by exact complete outputs, not a new screenshot claim.
