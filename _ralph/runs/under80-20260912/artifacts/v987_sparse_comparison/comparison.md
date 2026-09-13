# Accepted-v987 sparse wall spans (not additive)

| Span | Reference ms | 61N136W ms |
| --- | ---: | ---: |
| source-view RandomMapGenerator.DoGenerate on expanded backing | 15020 | 9702 |
| deferred underground passage bootstrap | 6404 | 1664 |
| surface engine decor pass | 419 | 9617 |
| helper crease repair destination | 3936 | 1572 |
| helper natural apron | 2153 | 1828 |
| helper native apron raster | 1895 | 1580 |
| surface prepare outer resource terrain | 2297 | 1852 |
| capture transferred decor relief from temporary terrain | 2203 | 2859 |
| surface resume combined pass edits | 5129 | 5711 |
| native final RebuildPassability | 9792 | 10633 |

Diagnostic wall time. Rows overlap/nest; no grand total, CPU attribution, or cold saving claim.

Split unchanged bootstrap into phase-only timings, especially native clearance, bridge copy, passage selection, resumes, and common-hex planning; no operation removal.
