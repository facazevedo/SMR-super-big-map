# v967 rock-capture experiment: correctness pass, performance not retained

Experimental commit3c03de4, v967/guard283, passes all65 offline commands and allten
rules across five scenarios (eight automated plus separate source/RNG and process
review). Complete terrain, placements, individual grounding and seed evidence are
identical. All nine standard acceptance processes exited normally. The correctness
signoff is v967_all_ten_rules_review.json; it is NOT an overall performance acceptance.

Reference START-to-T1 samples112.006/112.143/113.642s, median112.143s, versus accepted
v966 median113.024s: observed0.881s lower. Native control30.103s. Rock capture counter
median2478->2437ms, only41ms lower, so the total difference cannot be attributed fully
to the capture change. Surface contacts6342 and lowered rocks160 unchanged; total rock
rays29309->29272. The fixture's larger work reduction was not representative of this
map's real opportunity.

Five single-run samples:15S67E112.338s;24S74W112.461s;45S120W109.202s;
61N136W170.052s;17S11W113.678s. Later samples were slower than their older predecessors.
Two predeclared additional45S runs returned106.792 and108.099s, exact outputs and normal
exits. All three retained: no outlier removal or cherry-picking.

To distinguish changing test conditions from a code regression, a predeclared
A/B/A/B comparison used unchanged v967 (A) and a detached accepted-v966 checkout (B):

| Order | Code | START-to-T1 |
|---|---|---:|
|A1 (second repeat)|v967|108.099s|
|B1|v966|107.414s|
|A2|v967|105.219s|
|B2|v966|104.996s|

Candidate mean106.659s; predecessor106.205s: candidate0.454s slower. The predecessor
also ran slower than its historic103.324s, so the larger late slowdown is not unique
to the candidate. Nevertheless, this comparison does not establish a reliable gain.
All bracket outputs/gates match, processes are distinct and exit normally, deployments
are audited against their actual source checkout. Root source/HEAD was not changed by
these tests. The candidate deployment was restored and audited after the bracket.

Decision: revert only3c03de4. Keep accepted masks and crease application (v966/56b8a1f).
The experiment remains recoverable in Git; all timing and correctness evidence remains.
Do not count its0.881s reference difference in the retained optimization total.
