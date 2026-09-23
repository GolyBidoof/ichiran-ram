# Load and throughput: where the time goes and what to do next

Context: the the visual novel dialogue lines (`the visual-novel dialogue sample`) profiled as
a representative workload. Everything below was measured on this machine.

## What these sentences actually cost

| path | per line | for the 7 lines |
|---|---|---|
| DB, serial | 181.87ms | 25.46s |
| RAM, serial | 11.15ms | 1.56s (16.31x) |
| RAM, 8 workers | 2.24ms | 0.313s (81x) |

| path | queries per line |
|---|---|
| DB | **1727** |
| RAM | **0** |

The query number is the headline: on curated corpus text the DB path issues
~17 queries per line, but on dialogue it issues **1727** — 100x more. VN text
is full of names (遠坂, ロンドン), casual contractions (なって, っていうか,
じゃあ) and long conjugated forms (追われて, 繋いで, 炎上して, しちゃってたら,
承知しない), and every unknown or derived candidate triggers more lookups.
That is why the RAM advantage is *larger* on real reading material (16.3x)
than on the curated benchmark (13.4x), and it is why further work belongs in
the analyzer, not in I/O.

## The 85s load: fixed, 84.7s -> 8.9s

Two changes, both committed:

1. **Keyset pagination** in all five integer loaders (84.7s -> 70.3s). They
   paged with `ORDER BY <key> LIMIT n OFFSET k`, so Postgres re-scanned and
   discarded `k` rows per chunk. `conj_source_reading` needs 42 chunks for its
   8.4M rows, so it scanned ~21x more rows than it returned.
2. **Columnar snapshot** (`src/int-snapshot.lisp`, 70.3s -> 8.9s). Raw bytes
   for the typed columns, UTF-8 for the pools, and the hash indexes rebuilt on
   load from the columns they derive. 1.5GB on disk for 7.2GB of tables.
   Buffered I/O was the single biggest factor in the snapshot itself: two
   syscalls per pool entry meant ~20M syscalls, and an 8MB userspace buffer
   took the write from 50.3s to 4.2s.

Rebuild with `scripts/build-snapshot.sh`.

### Where the remaining ~9s goes

Materialisation, not I/O: ~7GB of typed vectors to allocate and zero, ~10M
Lisp strings to build from the pools, 1.5GB to read, and the index tables to
rebuild. Ranked options:

1. **Parallel load across tables** (low risk, ~2-3x on the load). The six
   tables are independent; the snapshot reader is sequential today. Threads
   per table need per-thread sources, but no format change. Expected 8.9s ->
   3-4s.
2. **Drop the derived hash indexes entirely** (medium risk, moderate effort).
   `text-index` (3.1M + 5.3M entries) exists to map text -> pool index. A
   sorted `(text-id)` permutation plus binary search answers the same query
   with one 12MB array instead of two multi-GB hash tables — and it would
   remove both the rebuild cost at load and a large share of resident memory.
   This is the highest-value structural change left, because it attacks load
   time *and* the 8.1GB footprint.
3. **Lazy/partial load** (low risk). `conj_source_reading` is 2.85GB and 27.4s
   of the SQL load. Loading it on first need would make a kana-only or
   name-lookup start nearly instant. Needs a "loaded on demand" state in the
   table gating, which already exists in the form of `*complete-tables*`.
4. **True mmap** (high effort, high risk). The typed columns are already raw
   byte arrays and could be mapped in place. The blockers are the string pools
   (Lisp strings cannot be mapped — they would need to become
   `(buffer . offset)` references) and the hash indexes (see option 2). Worth
   doing only after 2, since 2 removes much of the reason for the indexes.

## Worker count on this machine (measured)

140 the visual novel dialogue lines, best of two runs per setting, 10P+4E cores:

| workers | wall | speedup | per line |
|---|---|---|---|
| 1 (serial) | 1.939s | 1.00x | 13.85ms |
| 2 | 0.926s | 2.09x | 6.62ms |
| 4 | 0.422s | 4.59x | 3.02ms |
| 6 | 0.305s | 6.35x | 2.18ms |
| 8 | 0.255s | 7.59x | 1.82ms |
| **10** | **0.248s** | **7.82x** | **1.77ms** |
| 11 | 0.280s | 6.93x | 2.00ms |
| 13 | 0.292s | 6.63x | 2.09ms |
| 14 | 0.343s | 5.66x | 2.45ms |
| 20 | 0.299s | 6.49x | 2.14ms |

So yes, more workers help — **up to the performance-core count, then they
hurt**. Past 10 the extra work lands on the four efficiency cores and the
batch cannot finish until its slowest member does, so throughput falls. The
old default (`cpu-count - 1` = 13) was 15% slower than the optimum; the
default is now the P-core count.

Two things cap the curve at ~78% efficiency even at 10: SBCL's GC is
stop-the-world, so worker allocations serialize at collection time, and an
8GB structure with data-dependent access is memory-latency bound rather than
throughput bound. Both are addressable (bigger young generation / fewer
collections, and the index work below), but neither is a worker-count problem.

### Accommodation: GPUs, NPUs and other accelerators

Not worth pursuing here, and the reasoning is structural rather than a matter
of effort:

- **The hot path is branchy pointer-chasing, not dense arithmetic.** Romanize
  enumerates substrings, does hash lookups into an 8GB dictionary, builds
  candidate structs, then searches a lattice. GPUs need thousands of
  independent, uniform, branch-free operations; this is the opposite.
- **Random access into 8GB is latency-bound.** GPUs have enormous bandwidth
  and poor dependent-load latency, and the working set does not fit in
  cache. Offloading would trade fast CPU cache hits for slow global-memory
  round trips.
- **Per-sentence work is only ~11ms** and the parallelism is already
  saturated at the sentence level (7.8x on 10 cores). A kernel launch plus
  synchronization costs ~0.1-1ms, and the kernel itself would be dominated by
  divergence, because candidate lattices are ragged and data-dependent.
- **NPU/ANE is not applicable at all.** Apple's Neural Engine runs fixed
  neural-network operations through Core ML; there is no general-purpose
  path, and this romanizer has no neural component.
- **CUDA is moot on this hardware**, and would not change the fit analysis.

Where hardware could still help, if anything: **CPU SIMD (NEON/AVX)** for the
matching inner loops specifically (comparing many candidate substrings at
once, or a bitset FST), and more performance cores. Both are modest next to
the algorithmic work below.

## Throughput: the analyzer core, not I/O

Post-Tier-0 profile of the serial path (`sb-sprof`), now that the DB is gone:
`calc-score` 37.5% cumulative, the segfilters collectively large,
regex character-class compilation ~9-12%, `int-entry-by-seq` 4%,
`filter-in-seq-set` 2.5%.

Ranked:

1. **FST candidate generation** (the plan's Tier 2.2). Replaces the O(n^2)
   substring enumeration and its per-substring dictionary lookups with one
   pass emitting every match at every position. Targets the largest allocator
   and the seeding cost together.
2. **A candidate/score memo per position** (medium risk; must be opt-in).
   `calc-score` at 37.5% is recomputed per candidate; whole classes of
   candidates share inputs.
3. **Re-check regex compilation on this corpus specifically.** The golden
   corpus never calls `kanji-regex` (`scanner-misses=0`), which is why
   memoizing it measured as no help. Dialogue with kanji and proper nouns may
   well call `kanji-mask`/`kanji-regex` per word, and cl-ppcre in this tree has
   **no scanner cache at all**, so each call compiles. Worth instrumenting on
   `the visual-novel dialogue sample` before writing any code — the earlier lesson was that
   the sampling profile over-reports this and the A/B is authoritative.
4. **More workers.** 13 cores are available and the measurement used 8.

## What the parallel ceiling actually is (measured, not profiled)

Parallel efficiency tops out at ~78% (10 workers, 7.82x). The obvious suspect
was SBCL's stop-the-world GC serializing the workers. It is not: measured
over the 140-line the visual novel workload, GC is **1.6-3.0% of wall** in parallel and
0.2% serial, while **860MB is consed per run — 6.1MB of garbage per line**.
Allocation at that rate is a memory-bandwidth cost, and an 8GB structure with
data-dependent access is latency bound, so the ceiling is the memory
subsystem rather than collection pauses. The lever is therefore *cons less*,
which is the analyzer-side work below.

A note on methodology: `sb-sprof` flat reports on this macOS build are **not
trustworthy** for attribution. It reported `foreign function write` at 31.9%
of a workload that issues **zero** queries and writes nothing per line, and
earlier it invented a `-[deoc_ultraInput featureValueForName:]` frame. Three
separate conclusions here were reversed by measuring instead of profiling.
Use sampling profiles to find *candidates*, and A/B runs to decide.

### Allocation reduction: INTERSECTION predicates

`intersection` was used in boolean contexts all over the scoring path
(`kanji-break-penalty`, `calc-score`, and the segment filters), and builds a
fresh result list on every candidate. Replaced with a `%any-in-common` macro
that short-circuits on `member` with no allocation.

Byte-identical on both gates (`PARITY_OK`, `GOLDEN_DIFF_OK`). Measured A/B in
one process, 140 the visual novel lines, best of 3:

| config | before | after | delta |
|---|---|---|---|
| serial | 1.601s | 1.585s | -1.0% |
| 10 workers | 0.255s | 0.242s | -5.1% |
| 14 workers | 0.242s | 0.240s | -0.8% |

So a real but modest win, borderline noise on the serial path. Kept because
it removes allocation on the path that the bandwidth analysis above says is
the limiter, and because a predicate is the honest construct for a boolean
test — but it is not a headline number.

## The one thing that would change everything

A 32GB+ host would let `save-lisp-and-die` bake the whole 8.1GB dictionary,
which makes startup effectively instant and shares read-only pages between
processes. It is not available here, which is exactly why the snapshot exists.
Long term, options 2 + 4 above are what remove that dependency: an mmap'able
layout with offset-based pools would give instant, shared, database-free
startup on a 16GB machine.
