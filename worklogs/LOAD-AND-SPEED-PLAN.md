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

## The one thing that would change everything

A 32GB+ host would let `save-lisp-and-die` bake the whole 8.1GB dictionary,
which makes startup effectively instant and shares read-only pages between
processes. It is not available here, which is exactly why the snapshot exists.
Long term, options 2 + 4 above are what remove that dependency: an mmap'able
layout with offset-based pools would give instant, shared, database-free
startup on a 16GB machine.
