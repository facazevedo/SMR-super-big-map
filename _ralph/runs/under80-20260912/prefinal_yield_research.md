# Unrun explicit pre-final-yield witness

Historical delayed probes show that the first scheduler dispatch AFTER the
protected generation pipeline is an aggregate-stable boundary. They do not
establish whether an explicit yield just BEFORE the immediate final rebuild
would suffice. The game-time hold is still active there; its later release is a
confounder that this hypothesis must not assume away.

prefinal_yield_probe.lua retains every production rebuild, invalidation, pause
reason and readiness predicate. It adds one Sleep(1) before the immediate final
call and records aggregate plus exact exposed pass-grid comparisons around the
yield, immediate rebuild, scheduled entry and scheduled rebuild. No file write
or async export intervenes between those observations; captures remain in memory.
This is not a benchmark and no rebuild removal or timer change is implemented.

If immediate output still differs from scheduled output, this narrow hypothesis
is disproved on that map. Even if they match, a single diagnostic is insufficient:
native hidden state, ordering dependencies, all sites, ordinary native revalidation
and complete output parity remain required before proposing any production change.
Do not conflate this witness with historical failed skips/caches/deferrals.

Run only after the immutable v979 acceptance matrix closes, using a new owned
process through profile.py and diagnostic query SBM_PREFINAL_YIELD_DIAGNOSTIC.
It has not executed yet and establishes no saving.

The diagnostic-only fixture first failed because both observed branches dropped
RebuildFinal's true return. The probe now preserves that return and restores the
original wrapper after the scheduled call; production itself was never changed.
Fixture checks retain all three calls (including an untouched underground call),
exactly one yield, five observations and five explicit comparisons. This tests
probe control flow only, not native equivalence. Preserve the failed fixture
result: exit1, prefinal_yield_probe_test.lua:26, production return value assertion.

Further source dependency: FinalizeDeferredStretchState calls RefreshSectors,
which reads map.buildable.z_grid through BuildableGridRatio after the immediate
final rebuild (sbm_map_bounds.lua). Dropping only its buildability work is not
automatically safe. ResetMapAreas also calls map.SetPlayArea; native state effects
are not established by exposed-grid equality. Both calls remain in the probe.

## Matched native observations: no demonstrated yield benefit

prefinal_yield_reference (PID38032) and prefinal_no_yield_reference (PID5732)
both completed with exact full predecessor/individual-rock/private parity and
normal shutdown. Both preserve every rebuild and all readiness conditions.
The second setup differs only by omitting Sleep(1) and adding a control label.

Both have the SAME observations: before/immediately after the observation point,
aggregate8866464044280494327 and exposed-grid hash8044847184966396978; after the
immediate rebuild, at scheduled entry and after scheduled rebuild, aggregate
-6029211315239114117 and exposed-grid hash4476470600821498358. The actual serialized
exposed grids are compared byte-for-byte, not only by hash. All observations have
GameTime0 and no pass-edit suspension reasons. Yield advances RealTime9905->9906;
the no-yield control stays9697. RealTime is frame based, not wall-duration timing.

Conclusion: this matched pair does NOT establish that an added yield canonicalizes
anything. No yield production change, removal, deferral or cached revalidation is
justified. The observations themselves may be relevant to native behavior; they
do not prove unobserved-state equivalence or buildability/dependency equivalence
on every map. Set this narrow optimization hypothesis aside, not historical rules.
