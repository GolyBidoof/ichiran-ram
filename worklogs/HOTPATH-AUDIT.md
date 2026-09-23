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

## The constraint that dominates all of the above, and its root cause

The RAM path is currently **not byte-identical to the database path**: 83 of
364 golden lines differ. Optimising the analyzer before closing that gap risks
making the divergence harder to attribute, and the stated requirement is
database-identical output. `scripts/ram-parity.sh` exists to hold that line.

The divergences are **one root cause, not many**. Structural diffing by JSON
path shows the dominant signature is `seq` on 72 lines, `gloss` on 70 and
`reading` on 48, and in every case the *sets* are equal and only the order
differs, always inside the `alternative` and `kana` lists. Worked example,
golden line 10:

```
db  alternative seqs: [1536000, 1445980, 1446740, 2207550, ...]
ram alternative seqs: [1445980, 1536000, 1446740, 2207550, ...]
same set: True
```

Both entries score 16. The order is decided by `stable-sort` on
`segment-score` in `expand-segment-list`: a stable sort preserves the input
order for ties, so **the candidate list order decides the output**, and it is
the only thing that differs.

Where the order comes from, measured on `kana_text` for text `とう`:

| | row ids, in the order returned |
|---|---|
| database (`select-dao`, no ORDER BY) | `52034, 51967, 52012, 52046, 52201, 52326` |
| RAM (`memdict-find`, sorted by id) | `51967, 52012, 52034, 52046, 52201, 52326` |

Identical sets, different order, and note that the database order is **not**
id order: `52034` precedes `51967`. `select-dao` carries no ORDER BY, so
Postgres returns heap order, and `dict.lisp:774-798` deliberately sorts the
RAM side by `id` on the stated assumption that id order mirrors it. On this
database it does not.

Two ways to close it, and they are a real choice:

1. **Store the heap rank.** Capture `SELECT id FROM <table>` (no ORDER BY,
   i.e. the same seq scan the analyzer sees), record each row's physical
   position, and sort RAM lookups by that rank. Keeps the database output
   bit-for-bit as it is today, which is what "identical to the database
   version" demands, at the cost of a new column in the snapshot and a
   fragility: heap order is a physical artifact that changes if the table is
   rewritten, so the snapshot must be rebuilt whenever the database is.
2. **Give the database path an explicit ORDER BY.** Cleaner and stable, but it
   *changes the database path's output* on these 72 lines from heap order to
   id order, so it is a product behaviour change and the baseline would have
   to be regenerated. It cannot be described as a no-op.

Option 1 is the only one that satisfies the stated constraint without changing
the reference, so it is the recommended next step. Everything else, including
the zero-risk items below, should wait behind it.

## Zero-risk wins, queued behind parity

These do not change output and can be done mechanically, in this order:

- `apply-segfilters` returns a fresh one-element list even when a filter
  accepts its input, and the chain keeps running after a filter has already
  rejected everything. Returning the input unchanged and short-circuiting on
  empty are pure wins at 13.7% of allocation.
- `parse-suffix-val` (881 calls/line) re-parses table values that are fixed at
  `init-suffixes` time. Pre-parse into structs or bit flags.
- The 727 `create-scanner` calls per line cover **3 distinct patterns**, so
  they are string literals. A runtime cache was measured and lost (1.653s and
  1.692s against 1.585s), but `load-time-value` on a literal is a different
  mechanism: it removes the hash lookup entirely rather than paying for it to
  avoid a compilation. Worth one measurement, unlike the cache.
- `subseq-slice` already avoids copying characters, but `adjust-array` with
  `:displaced-to` still allocates an array header per call, so 1,171 calls
  per line is roughly 56KB of headers. Small next to 6.26MB, but it disappears
  for free once splits carry `(start . end)` integers instead of slice
  objects.
