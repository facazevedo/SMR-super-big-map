# Unproved positive whole-cell circle certificate

No production candidate or performance claim. Do not confuse this with the
rejected radius-expanded bucket-list query (native3263ms vsold2618ms).
Accepted baseline is now f4d1da6/v983. Slow61N still measures94.342s; its prior
coarse diagnostic decor stage was9768ms with727247 synthetic attempts. Detailed
helper timing is needed before choosing another implementation.

Possible different approach: preserve the existing circle index and exact query,
but cache only a conservative proof that an entire small spatial cell lies
strictly inside one obstruction circle expanded by a LOWER query-radius bound.
Future points in that cell with radius at least that lower bound are guaranteed
hits. Only positive certificates persist across appends; never cache negative
answers beyond the matching list generation. A circle hit is a pure boolean, so
this cannot change rejection precedence, candidate traversal or RNG draws.

Candidate certificates could be learned lazily after an existing exact hit,
without building the rejected large per-radius bucket lists. Evaluate the farthest
cell corner from that actual hit circle, using an outward-rounded upper distance
and inward-rounded lower reach. Every intermediate and all boundary rounding must
be proved conservative for the native integer/double domains; reject unsupported
numbers and retain the exact old query. List/circle immutability is a premise to
audit, not a global cache assumption. Bound memory and query warm-up overhead.

Before promotion: independent exhaustive/old/new tests, strict tangency and numeric
edges, appended circles and list lifetimes, then full native query shadow with
zero differences and genuinely reduced work. No blind positive return, changed
query/candidate count, skipped random draw or use of diagnostic time as cold gain.
This note is a research lead only, not a proved algorithm or reason to lower any
correctness standard. No experiment has tested this hypothesis yet.
