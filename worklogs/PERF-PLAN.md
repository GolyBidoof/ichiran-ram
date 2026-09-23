# Performance plan: where the remaining 2.6s goes and how to remove it

Baseline: full-RAM serving (integer layer + compact sense layer, 8.1GB heap)
over the 364-line golden corpus, `ichiran:romanize`, warm: **~2.6-2.8s**,
i.e. ~7.2ms per line. The DB path is ~18.9s, so RAM already buys 7.5x. This
plan covers what comes after that.

Everything below is either **measured** on this machine or explicitly marked as
an estimate. Two plausible optimizations were measured and **rejected**; they
are recorded so nobody spends a day rediscovering them.

## Measured facts

| finding | measurement |
|---|---|
| Residual DB queries | 17.1 per line (6224 over the corpus) |
| Per-query round-trip | 51.5us for a trivial `SELECT 1` |
| Socket share of CPU samples | ~29% (`write` 16.3, `__select` 6.4, `read` 3.1, `__connect` 1.3, `kqueue` 2.0) |
| Implied DB cost | ~0.4-0.7s of 2.6s (15-27%) |
| GC | **0.2% of wall time** (0.006s), despite 561MB consed |
| Thread scaling, 1456 lines | 2 threads 1.85x, 4 threads **3.79x**, 8 threads **4.91x**, no errors |
| Cores | 14 (10 performance + 4 efficiency) |

### Rejected after measurement

1. **Memoizing `kanji-regex`.** The profile showed `cl-ppcre:create-scanner`
   at 13% cumulative, so this looked like the cheapest win. It is not: the
   corpus never calls it (`scanner-misses=0` once instrumented), and the
   conjugation path that uses it is cold.
2. **Memoizing `simplify-ngrams`' scanner.** Scanner builds dropped 3436 -> 3,
   and the run got *slower* (3.01s vs 2.62s). Scanning is real work; compiling
   the scanner is not. The 13% attributed to `create-scanner` is really the
   matching work inside `regex-replace-all`, which a scanner memo cannot
   remove.

`cl-ppcre` only caches *string* patterns, so list parse trees do recompile; it
just does not matter at this scale.

3. **Allocation reduction.** 561MB consed per corpus run (1.5MB/line) and 77%
   of allocation samples are hash tables, which looks alarming. But GC is 0.2%
   of wall time, so this is not a wall-clock problem on SBCL here. Worth doing
   only where it also removes work (see A3), not for its own sake.

## Tier 0: finish the RAM wiring (measured target ~1.25x)

Remove the last 17.1 queries/line. Ranked by query volume from the callback
histogram:

Exact attribution from the `*query-callback*` histogram, RAM section only
(428 queries over 25 lines = 17.1 per line):

| query shape | count | call site |
|---|---|---|
| `kanji_text`/`kana_text` JOIN `sense_prop` | 119 | `find-word-with-pos` |
| `kanji_text`/`kana_text` by `id` | 74 | `get-dao` in the `best-kana-conj` parent walk |
| `conj_source_reading` by `(conj_id, source_text)` | 74 | inside `best-kana-conj` / `best-kanji-conj` |
| text by `(text, seq)` | 55 | `find-word-seq` |
| `kana_text` UNION (direct + `conj.from`) | 29 | `get-kana-forms*` |
| `kanji_text`, `conjugation` by `from` | 6 | `find-word-conj-of` |
| `sense`/`conjugation` by id or `(seq, from)` | ~71 | `get-conj-data`, short-sense path |

The `find-word-with-pos` share (119, the single largest) is worth calling out
because it looks like it should already be covered: `memdict-non-arch-posi`
exists, but it mirrors `get-non-arch-posi`, a different query. There is no RAM
mirror of `find-word-with-pos` (text + posi over the seq's senses), so it
queries the text tables joined to `sense_prop` once per candidate word. It
needs a new mirror, not just wiring.

Each is a small RAM mirror of an existing prepared query, the same pattern as
`memdict-query-parents`. Expected: 2.6s -> ~2.1s, plus better thread scaling
because threads stop contending on the connection pool.

Completing this is also what makes a genuinely **DB-free core** possible: with
zero queries on the serving path, the core needs no connection, no pool, and no
`__connect` at all.

## Tier 1: parallel sentence serving (measured 3.8-4.9x)

The dictionary is read-only after load, and sentences are independent, so this
is the largest available win for realistic input. Measured on 1456 lines with
no correctness errors: 1.85x / 3.79x / 4.91x at 2 / 4 / 8 threads.

Work needed:

- A worker pool sized to cores, chunking input on sentence boundaries
  (`basic-split`) rather than characters, so each worker keeps whole sentences.
- A thread-safety audit of shared mutable state before shipping: `*suffix-cache*`
  / `*suffix-class*` (`dict-grammar.lisp`), the `cl-ppcre` scanner cache, and
  per-thread Postgres connections. The experiment ran clean, but it ran without
  the S1/S2 caches enabled, which are additional shared state.
- Wire it into `scripts/serve-system.sh` (one worker per core, queue of
  sentences) and expose a paragraph-level entry point.

Expect the 8-thread number to improve once Tier 0 lands, since connection
contention is one reason it falls short of linear.

## Tier 2: the analyzer core (the real remaining cost)

With Tier 0 and 1 done, the remaining serial cost is candidate generation,
scoring and path search. From the CPU profile: `calc-score` 31.5% cumulative
(`classify` 4.6 self), `apply-segfilters` 20.7% cumulative across many
`segfilter-*` functions, `get-seg-splits` the single largest allocator (30.3%).
Note these percentages sum past 100% because they are cumulative, and the
socket share above overlaps them; treat them as shape, not exact budget.

- **A3a. FST candidate generation.** Replace per-substring dict lookups with a
  single pass over a finite-state transducer built from the dictionary keys,
  emitting every match at every position in O(n * L). This targets
  `find-substring-words` seeding and `get-seg-splits`, the two largest
  allocators, and removes the `memdict-find` decode from the inner loop.
  Estimated 1.5-2.5x on the serial path; the largest single algorithmic win
  available, and the design work already existed in the earlier plan.
- **A3b. Decode-free reads.** `int-text-row` is 6.5% of CPU samples because
  every lookup builds a plist and then a struct. Have the analyzer read columns
  directly, or memoize decoded rows per `(table, seq)`. Estimated ~5%.
- **A3c. Lattice/beam pruning.** Cap splits per position, prune branches whose
  partial score cannot win, and memoize the best score per position. Targets
  `find-best-path` and `calc-score`. Estimated 1.2-1.5x, larger on long
  sentences, which is exactly where a page of text spends its time.
- **A3d. Allocation in the splitter.** `get-seg-splits` allocating 30% is only
  worth attacking together with A3a/A3c, where the structure changes anyway.
  Do not do this on its own: GC is 0.2%.

## Tier 3: infrastructure (startup and multi-process)

- **mmap the columnar store.** The 82s load and the 8.1GB private heap both
  disappear if the integer columns live in a memory-mapped file: cores start
  instantly and several worker processes share one copy of the pages. Requires
  the on-disk format to match the in-memory layout (it nearly does already:
  the integer tables are flat typed vectors plus an interned string pool, so
  the work is serialising the pools and the two index vectors, and making the
  pools offset-based rather than Lisp-object-based).
- **Shared-memory worker model.** With mmap in place, parallelism (Tier 1)
  scales across processes rather than threads, side-stepping the Lisp
  shared-cache audit entirely and removing the heap cap.
- **Precompiled regexes / scratch reuse.** Low priority: measured to be
  irrelevant here.

## Honest ceiling estimate

Serial, after Tier 0 and Tier 2: **~1.0-1.3s** for the corpus (~3-4ms/line),
roughly 2x on top of today. With Tier 1 parallelism at 4-8 workers:
**~0.15-0.35s wall for the same 364 lines**, i.e. under 1ms per line, which is
the range where a page of text feels instant. The mmap work is what makes that
configuration cheap to start and hold, rather than a per-process 8GB cost.

The parts of this plan that are estimates are A3a-A3c; every number in the
"measured" table above was reproduced on this machine. Method, so each is
repeatable without the scratch scripts that produced them: load the layers with
`memdict-load-int` + `memdict-load`, set `*memdict-p*`, warm once, then time
`ichiran:romanize` over `data/golden-corpus.txt`; query shapes come from
counting `cl-postgres:*query-callback*`; thread scaling from the same workload
split across `sb-thread` workers, one connection per worker; GC share from
`sb-ext:*gc-run-time*`; per-query latency by timing 2000 trivial `SELECT 1`.
Each A/B was run in one process with a warm pass per variant, and the two
rejected optimizations were decided by that measurement, not by the profile.
