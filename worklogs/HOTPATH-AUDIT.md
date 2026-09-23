# Hot-path audit: what is slow, what was tried, what it would take

Measurements are on the 140-line the visual novel dialogue corpus unless stated otherwise.
Two caveats up front, because both have already misled this work:

- `sb-sprof` flat reports on this macOS build **misattribute badly**. It put
  `foreign function write` at 31.9% of a workload that issues zero queries and
  writes nothing per line. Use it to nominate candidates only.
- Single-run A/B drifts **~10%**. The interleaved numbers below are trustworthy;
  the sequential ones are marked as such.

## Where the time and the garbage actually go

Per line (the visual novel corpus, measured by instrumenting call counts):

| call site | calls/line | share of allocation |
|---|---|---|
| `get-seg-splits` | 2,116 | **43.0%** |
| `subseq-slice` | 1,171 | small (a view; see below) |
| `parse-suffix-val` | 881 | small lists |
| `cl-ppcre:create-scanner` | 727 (3 distinct patterns) | ~10% with `CONVERT` |
| `calc-score` | 386 | **2.0%** |
| `find-word` / `find-word-full` | 342 | - |
| `apply-segfilters` | per split pair | **13.7%** |
| `find-best-path` | - | 4.3% |

Total: 6.26MB of garbage per line, 11.2ms/line serial, 1.7ms/line on 10
workers. So the work is dominated by **candidate/split enumeration**
(`get-seg-splits` + `apply-segfilters` = 56.7% of allocation), not by scoring.
`calc-score` was described in an earlier plan as "37.5% of CPU"; that figure
came from the unreliable sampler. Its allocation share is 2.0%, and the
sensitivity test below puts the entire filter machinery well below that claim.

## What has been attempted, and what happened

| target | attempt | outcome |
|---|---|---|
| Scoring-path allocation | replaced allocating `INTERSECTION` predicates with a non-allocating `%any-in-common` | **won**, ~6-7% serial (interleaved, 3/3 pairs) |
| Dictionary load | keyset pagination instead of `LIMIT/OFFSET` | **won**, 84.7s -> 70.3s |
| Dictionary load | columnar snapshot (raw columns, rebuilt indexes) | **won**, 70.3s -> 8.9s |
| Snapshot I/O | 8MB userspace buffering | **won**, write 50.3s -> 4.2s, read 21.8s -> 10.0s |
| Snapshot load | pre-sized index hash tables | marginal, 10.4s -> 10.0s |
| Parallel serving | worker pool, per-worker memo copies | **won**, 7.82x on 10 workers |
| Worker default | P-core count instead of `cpu-count - 1` | **won**, 15% vs the old default |
| Regex compilation | cache scanners by pattern (two keying strategies) | **lost**, 1.653s and 1.692s vs 1.585s serial |
| Regex compilation | memoize `kanji-regex` | no effect (never called on the golden corpus) |
| N-gram simplification | memoize `simplify-ngrams` | **lost**, 3.01s vs 2.62s |
| GC contention | hypothesised as the parallel ceiling | **falsified**: GC is 1.6-3.0% of parallel wall |
| GPU / NPU | structural fit analysis | not applicable (branchy pointer-chasing) |

## What it would take, per target

**1. `get-seg-splits` + `apply-segfilters` (56.7% of allocation).** This is the
real target and the only one with a large ceiling. `apply-segfilters` runs 16
filters over a growing split list, rebuilding it with `nconc` at every stage,
and each filter returns fresh lists. Two levels of fix:

- *Cheap:* short-circuit when the split list becomes empty (correct today, just
  wasteful), and have filters return the input pair unchanged rather than a
  fresh one-element list — the common "no objection" case. Bounded, no
  behaviour change, but the win is the allocation only.
- *Structural:* stop representing splits as lists of conses at all. An index
  pair array with a reusable per-sentence buffer would remove most of the 2,116
  × 16 allocations per line. This is a refactor of the split representation and
  its consumers, so it needs the corpus gate to stay green throughout.

The stubbing experiment (remove all 16 segfilters, all 17 synergies, or both
penalties) puts the whole filter machinery at roughly **1.5s serial per 140
lines with everything present**, with individual attributions inside the ~10%
drift, so treat the per-list numbers as upper bounds. Even a perfect
implementation of these lists cannot save more than that.

**2. FST / double-array trie for candidate generation.** The README-level
proposal, and it is the right shape for replacing O(n²) substring enumeration
with one linear pass. But note `subseq-slice` is already a **displaced array**
(`adjust-array` with `:displaced-to`), not a string copy, so the "never
allocate candidate strings" part of that argument is already implemented
upstream. The remaining win is the hash lookup and the slice header per
candidate. It is a multi-day change and it must reproduce the conjugation-aware
and character-class behaviour exactly, so it should be attempted only with
`ram-parity.sh` and `golden-diff.sh` green as the guard rails.

**3. `parse-suffix-val` (881 calls/line).** Pre-parse the suffix table once in
`init-suffixes` into structs or bitmasks so lookup allocates nothing. Bounded,
well-understood, and cheap to verify. Worth doing.

**4. Regex scanners (727 calls/line, ~10% of allocation).** Tried and lost.
The scanner is large to *store* but cheap to *build*, so a cache adds overhead
to avoid work that was never expensive. The one untried variant is precompiled
scanners at the call sites (`load-time-value`), which avoids the cache lookup
entirely — but given the two failures, set expectations low.

**5. `calc-score` (386 calls/line).** Lower priority than the plan claimed.
Its allocation is 2.0%. Bitmask POS classes and a transition matrix would be a
deep refactor of scoring rules, which the contract forbids changing; and
ichiran has no bigram connection matrix to replace, so the usual "dense cost
matrix" advice does not map onto this architecture.

## The constraint that dominates all of the above

The RAM path is currently **not byte-identical to the database path**: 83 of
364 golden lines still differ (alternative-reading seq selection, and kana case
in readings such as `来る 【クる】` vs `【くる】`). Optimising the analyzer before
closing that gap risks making the divergence harder to attribute, and the
stated requirement is database-identical output. `scripts/ram-parity.sh` exists
to hold that line.
