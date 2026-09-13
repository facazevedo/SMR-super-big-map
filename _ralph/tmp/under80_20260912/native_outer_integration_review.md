# Private integration draft review

Generated at1040749 while the standalone shadow source stays frozen. No production
file has been edited or deployed. The draft is not an accepted optimization.

## Deliberate preservation

- Original scalar coarse loop and its per-patch zero-angle cache remain intact
  inside fill_scalar_coarse; domain refusal uses that exact loop. The correction
  closure duplicates the literal cell expression, with its own per-patch cache.
  Existing source-extracted scalar tests should continue selecting the first loop;
  the embedded helper test redirects them to the generated source.
- The helper gains only a domain_qualified discriminator: false before numeric
  qualification, true before the first owned allocation. Domain refusal and native
  execution failure must not be conflated.
- New required native primitives are explicitly checked. Missing entries cannot
  disappear silently through Lua pairs(nil-field) enumeration.
- A qualified helper failure sets native_mask_failure, exits the current patch
  after owned scratch cleanup, stops subsequent patches, and marks ok_apply false
  before SetHeightGrid. The old OptimizationFailure report/message path is used;
  no scalar rescue or terrain installation follows a native failure.
- Resource/rocket planning, patch order, guard order, sampled bounds and spacing,
  resampling, exact core/protected disks, height blending, dirty regions, final
  grid installation and every downstream rebuild remain unchanged. No RNG call,
  object placement, rock-support rule or START/T1 boundary is changed.

## Gates still required

1. Complete the frozen standalone six-site shadow set, preserving the first batch's
   shutdown-preflight failure and its passing reference. Do not restart successful
   samples to seek better times.
2. Execute embedded helper/literal/failure tests and all80 accepted offline commands
   against the candidate. Preserve unsupported-domain behavior and cache lifetime
   coverage; do not weaken verifiers to accommodate a new path.
3. Test actual integrated rejection in the engine, proving a qualified mask failure
   leaves the installed terrain untouched, frees scratch/working grids and reports
   OptimizationFailure even when engine error() logs instead of throwing.
4. Review numeric certificate/source correspondence and eliminate the draft's
   research-only marker only after these gates are established. Conditional f32
   premises are documented; passing fixtures alone are not an all-input proof.
5. Run full native parity with the integrated fast path, then the immutable cold
   reference3/control and all five validation sites. The diagnostic kernel gains
   are not an end-to-end performance result or achievement of the startup target.

The duplicate scalar expression is intentional for this first research draft so
existing predecessor tests remain meaningful. Before promotion, verify both copies
are identical mechanically and ensure future tests exercise the correction copy,
not only the preserved scalar branch. Formatting/readability cleanup remains due.

## Injected native integration result

Atca6c963, both injected preparations returned the root-residual report and made
zero terrain-installation calls. Each released all14 tracked grids and left the
complete installed-height serialization hash unchanged. Each recorded a visible
OptimizationFailure. However, the game called preparation again and progressed
to T1 despite logged LUA ERRORs. The original expected-failure driver FAILed its
early-abort/single-call assumptions; this failure is retained. The full ordinary
verifier also FAILed the intentionally invalid final map, as it must.

transaction_evidence_audit.json characterizes only transaction containment,
cleanup and visible rejection. It does not convert the original failure test to a
pass or prove early startup abort. Successful-path correctness and all cold gates
remain required; no runtime verifier or engine behavior was changed to fit this test.
