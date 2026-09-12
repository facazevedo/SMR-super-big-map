# v978 repeated Lua evaluation

Two small measured changes, based on accepted v977 (`b5fb059`):

1. `sbm_engine.lua` snapshots only the standard Lua `type` and `pcall` primitives
   at module load. It does not capture IsKindOf, IsValid, AsyncRand, terrain APIs,
   class tables or other game globals: every original live lookup remains in its
   original place. Protected calls, their argument lists, success tests, returned
   tuples and failure paths are literal unchanged code. The sandbox's own rawget
   adapter is neither replaced nor bypassed. As with normal local Lua primitives,
   replacing type/pcall themselves requires reloading this module; those are not
   mutable game APIs. The full-module oracle strips the one declaration and
   requires exact predecessor source equality, then checks172114 results/trace
   fields, including errors, nil holes, live engine rebinding and RNG fallback.

2. The outer-mask loop caches the literal three-term harmonic only for angle0,
   within one patch and keyed by the current sine function. The existing missing
   atan2 fallback remains0; it is NOT changed to atan. Nonzero angles execute the
   exact previous expression, and sine rebinding invalidates reuse. Term order,
   arguments, association, protection, U12 rounding, native resampling and final
   blending are unchanged. The new oracle compares86905 exact coarse/domain/
   patch-lifetime fields with v977, including missing/present atan2 and rebinding.
   The older shortcut oracle still isolates cell arithmetic; lifetime behavior
   is explicitly covered separately. Math.sin is the standard pure C primitive
   in the measured engine. No stateful replacement sine-call-count contract is
   introduced or claimed.

Fresh diagnostics are separate from acceptance: `zero_harmonic_profile_reference_3`
has full predecessor/individual-rock parity and an outer stage of3521ms; its
relief function profiler deliberately adds overhead. The first setup used a wrong
predecessor path and launched no game. Attempt2 failed on an unavailable main-menu
wrapper and closed its owned PID normally; the corrected hook uses the already
captured factory helper. `engine_primitives_profile_reference` has full predecessor
parity, diagnostic T1=87.978s and relief3629ms. That diagnostic uses a chunk-isolated
environment proxy to model primitive binding; production uses lexical locals.
Do not call these samples cold benchmarks. Both successful processes quit normally.

No changes to candidate selection/order, shared/private RNG draws, source generation,
height correction, rock support, resource/rocket/elevator rules, retained buttons,
passability invalidation/rebuild sequence, readiness gates or timer boundaries.
All terrain changes still precede final and post-pipeline scheduled revalidation.
Runtime978/guard293 gives the changed terrain closure a fresh patch identity.

Full76-command offline suite, fixed committed/audited payload, three reference
cold runs plus control and all five scenarios are required for acceptance.

Initial `v978_offline` failed only the static outer-policy declaration-format
check (`local harmonic =`). The updated check verifies all three original sine
terms explicitly, preserving the irregularity requirement and strengthening its
formula coverage.75 other commands passed; the failed suite is retained. Full
rerun is `v978_final_offline`, not an overwrite or renamed success.
