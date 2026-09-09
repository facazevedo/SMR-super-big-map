# v965 native crease translation: not accepted as a speedup

Experimental code checkpoint 4931670 (guard281). All 63 offline commands pass.
Three fresh 14N134W START-to-T1 samples: 114.588 / 115.302 / 113.347s;
median114.588s, versus accepted v964 median114.512s (+0.076s, within variation).
Native control29.380s. All four processes exited normally. Complete predecessor
and repeat outputs, automatic gates and ordinary/private RNG evidence pass the
reference audit with no issues. No five-site acceptance was attempted because
the measured-improvement condition failed. No all-ten/five-scenario claim for v965.

The native kernel is exact and faster in isolated scratch tests, but that does not
establish a full loading-time gain. One further in-scope crease refinement will be
tested: cache the exact original quintic basis by width, retaining evaluation order,
rounding, clipping and slopes. Compare that combined candidate directly to v964,
not to this unaccepted intermediate. Original results remain preserved in full.
