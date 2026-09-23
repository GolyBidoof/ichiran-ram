# Performance history

How this project went from the upstream database-backed analyzer to a
zero-database serving core that answers roughly 40 times faster per line, and
about 430 times faster under the parallel server. Every entry names the commits
that did the work, so any claim here can be checked with `git show`.

The rule that shaped all of it: **the output must stay byte-identical to the
database version**. That constraint is why several plausible optimisations were
measured and then thrown away, and why the parity harnesses were built before
most of the speed work rather than after.

Measurements are per line of text unless stated. The two reference corpora are
the golden corpus (382 lines, the parity contract) and a 350k-character magazine
sample (18,939 lines, 335,008 characters, the throughput workload). The
throughput corpora are not distributed with this repository; see the note at the
end of this file.

## 1. Foundation: make the work measurable (C0)

Commits `eef64de`, `4dae04f`, `b162ae8`, `facd657`, `d0c2735`, `e1f8a1a`,
`91a7e11`, `c3724ff`.

Before any optimisation: a workspace-contained SBCL and PostgreSQL, a golden
corpus with a byte-identical baseline snapshot, `scripts/golden-diff.sh`, and
`scripts/bench.sh`. Every later improvement is quoted against these numbers.

Why it mattered: the parity contract turned "is this faster?" into a checkable
question and, more importantly, made "did this change the answers?" checkable
too. It caught real regressions later that no benchmark would have noticed.

## 2. Query reduction: fewer round trips

Commits `04beedf`, `29635e0`, `9ad5538`, `8d6933c`, `ba8f52e`, `7334e19`.

The analyzer issued a database query per candidate word, per reading, per
conjugation. Batched `IN` queries per sentence (entry prefetch, then conj and
sense prefetch), a `substring-hash` nil sentinel that lets a checked-and-absent
window skip its confirming probe, and finally Tier 0, which moved the residual
lookups into RAM.

| Improvement | Effect |
| --- | --- |
| Entry prefetch | One batched query per sentence instead of one per word |
| Conj + sense prefetch | Queries 707 to 570, then 1141 to 1107 on the benchmark corpus |
| `substring-hash` nil sentinel (`8d6933c`) | Removes a confirming probe for every window already known absent |
| Tier 0 (`ba8f52e`, `7334e19`) | Residual queries 17.1 to 3.0 to **0.28 per line** |

Why it helped: at ~50 ms per line the cost was dominated by round trips, not by
computation. Cutting query count is the single largest lever in the early phase,
and it is why the database path itself got faster before any RAM dictionary
existed. The reading-str memo experiment was removed again in `eb7455e` because
it measured net-negative per sentence, which is worth recording: batching won,
memoising did not.

## 3. In-memory dictionary: the first order-of-magnitude win

Commits `8217376`, `7bb3797`, `8e190d5`, `f350673`, `855dfaf`, `bbe2eb5`,
`f4d3b93`, `934f951`, `328f4b9`, `3f4d402`, `cb539ff`.

Three generations of RAM dictionary:

1. **plist conses** (`8217376`), then **DAO-based** (`f350673`): kana text served
   from RAM, measured **38x on kana-heavy input** (1.22s to 0.032s) and 4.3x on a
   mixed sentence.
2. **Compact structs** (`bbe2eb5`, `f4d3b93`): `defstruct` rows plus separate
   analyzer shims, so a row is a struct instead of a hash entry and a list.
3. **Integer-keyed columns** (`082c9ab`, `f14ab8a`, `e3f150c`, plus the R7
   series): the dictionary as typed column vectors with dense per-seq ranges and
   interned string pools.

Why it helped: the upstream schema stores one row per reading with all its
overhead, about 2.7GB for `kana_text` alone. Columns plus dense indexes remove
the per-row overhead, and the whole dictionary fits in about 8GB, which is what
made a baked serving core possible at all.

## 4. Parallel serving

Commits `71d6d75`, `dc92812`, `9a91f05`, `46b2073`, `f106806`.

Sentences are independent, so they are sharded across worker threads with
`map-lines-parallel`, one ordered result vector, and per-worker analyzer state
(score caches are per worker, not shared).

| Measurement | Effect |
| --- | --- |
| Tier 1 (`dc92812`) | **5.57x on 8 workers** |
| Worker-count tuning (`9a91f05`) | Default to performance cores; past that count throughput falls |
| Scaling curve (`46b2073`, `f106806`) | 8 workers 7.59x, 10 workers **7.82x**, 14 workers 5.66x |
| Final, 10 workers (this session) | 2.29s for 18,939 lines, 0.121 ms/line, **10.9x to 12.8x** |

Why it helped: the dictionary is read-only after load, so parallelising is nearly
free. The interesting finding is that more workers is worse: extra threads land on
efficiency cores. The default is now the performance-core count rather than
`cpu-count - 1`, which was 15% slower.

## 5. Snapshot and core: startup from 84s to under 1.3s

Commits `d88dc17`, `dbf7c03`, `3169ce8`, `37f7b38`, `2e20627`, `31dd22f`,
`5db3946`, plus `adff451`.

| Step | Dictionary load |
| --- | --- |
| Loading from PostgreSQL | **84s** |
| On-disk columnar snapshot (`d88dc17`) | 84s to **8.9s** |
| Encoding string pools as blobs (`dbf7c03`) | 7.31s to **5.47s** |
| Encoding text pools as blobs (`3169ce8`) | 5.47s to **2.61s** |
| Baked serving core (`2e20627`) | **1.21s to ready**, no database at all |
| Sense layer in its own snapshot (`5db3946`) | Removes the last startup dependency on PostgreSQL |

Why it helped: the layer is flat typed columns plus interned string pools, so it
can be written as raw bytes and read back with bulk reads. Building one Lisp
string per dictionary entry was most of the decode time; storing one concatenated
blob plus N+1 offsets removes that entirely.

Also `eff5408`: snapshots carry a build stamp and probe the database instead of
assuming it, which is why a rebuilt snapshot differs from an older one in exactly
those stamp bytes and nowhere else.

## 6. Parity: finding and fixing the divergences

Commits `83d9006`, `d56d432`, `65c2e3a`, `2b29eda`, `adff451`, `572e28d`.

`83d9006` added `scripts/ram-parity.sh` and it immediately found three
RAM-versus-database divergences. `d56d432` pinned one root cause (heap order
versus id order), `65c2e3a` matched the database's row order and candidate seed
order, and `2b29eda` closed the gap: **0 of 364 golden lines differ**.

Why it helped: this is the phase that made the speed work shippable. The subtle
one is ordering. The database path selects rows with no `ORDER BY`, so Postgres
returns ctid order, and the analyzer's stable sort by score keeps ties in input
order, so that physical order is visible in the output. Ranking rows by id
instead changed 72 of 364 golden lines. That fact is now recorded next to the
code that computes the ranks, and it is the reason that code looks the way it
does.

## 7. Micro-optimisation after parity

Commits `b3874bf`, `28e1019`, `c087760`, `e89398d`, `720ae9e`, `506f8f5`,
`14114b9`, `4f91c0f`, `1986044`, `1bc6e3c`, `97fcbef`, `fc7c43e`, `038a904`.

Once the answers were provably identical, the remaining time was attacked
function by function, guided by audits (`1986044`, `c087760`) rather than
intuition.

| Improvement | Effect |
| --- | --- |
| Stop rebuilding regex scanners per word (`b3874bf`) | Golden corpus RAM time to 1.27s |
| Build the suffix cache without a connection (`28e1019`) | Removes a connection from startup |
| Gloss JSON fragments cached in seq-indexed vectors (`506f8f5`) | Removes repeated JSON construction |
| Port the last raw SQL suffix predicate to RAM (`14114b9`) | Removes the last per-word query |
| Stop opening a connection per word (`4f91c0f`) | Removes a connection from the serving path |
| `get-seg-splits` memo per `find-best-path` (`e89398d`) | 74,810 calls, 26,985 distinct pairs, 63.9% hits, identity-keyed and call-scoped |
| `gen-score` cache per worker (`720ae9e`) | Packed fixnum key, 128.5 calls per line become 13.1 real computations |
| Warm the expensive shapes at startup (`1bc6e3c`) | Moves first-call cost out of the first request |
| Remove allocating `INTERSECTION` predicates (`97fcbef`) | Removes consing from the scoring path |
| Character-class scanners compiled once (`038a904`) | **1,491,524 scanner compilations to 6,000** over 3,000 lines; 11.9% best, 5.5% median |
| First-character direct index (`fc7c43e`) | Lookup 252.8ms to 60.9ms for 186,966 calls, **4.15x**; 8.9% serial, 7.9% parallel overall |
| Table-name dispatch without `string-downcase` (`038a904`) | 0.59% less allocation, measured across two revisions |

Why the last two mattered: `count-char-class` ran on the hot path and handed
cl-ppcre a raw pattern string on every call, and cl-ppcre's own cache does not
hold those patterns, so it recompiled 497 times per line. The first-character
index replaced two pointer dereferences per comparison with two adjacent array
reads inside a 256KB CSR table, which is why the lookup got 4x faster without
changing a single comparison's outcome.

## 8. Experiments that were rejected

Recording these is as important as recording the wins, because each one is a
plausible idea that a future reader would otherwise try again.

| Rejected | Evidence |
| --- | --- |
| Baked prefix trie (`c0072ca`, `cae131d`, `77eea9a`, `3651dd7`) | Builds correctly, 8,411,392 texts and 13,303,350 nodes, but is neutral to slower: 0.492 vs 0.490 and 0.212 vs 0.168 ms. Candidate windows are nearly all valid prefixes, so there is nothing to prune. Kept behind `TRIE_TABLES`, off by default |
| Reading-str memo (`eb7455e`) | Net-negative per sentence, removed |
| Trimming `*max-word-length*` 50 to 37 | Removes only 4.6% of windows, and is not safe: the number-plus-counter path admits windows longer than any dictionary text |
| Window pre-filter (this session) | Provably skip 16.28% of windows (721,226 of 4,429,093) but only 0.05% less allocation and no time gain |
| `kanji-regex` scanner cache (this session) | The cache never gains an entry; the function is called zero times on all three corpora. The compilations came from `count-char-class` |
| More workers (`46b2073`) | Past the performance-core count, throughput falls |

## 9. Where it ended up

All measured on the same machine, `romanize` per line, best of three.

| Corpus | Lines | Database | RAM | Baked core |
| --- | --- | --- | --- | --- |
| golden | 382 | 51.74 ms | 1.27 ms | 1.27 ms |
| visual-novel sample, batch 1 | 39 | 53.87 ms | 1.51 ms | 1.54 ms |
| visual-novel sample, batch 2 | 84 | 67.83 ms | 1.66 ms | 1.91 ms |

Time to the first answer, which is what a caller actually waits for: golden
23.03s, 0.97s, **0.54s**; the core is ready in a flat 1.27s because it loads
nothing. On the 350k-character magazine sample the database is out of range (about 16 minutes at
52 ms per line), while RAM and core take 23.8s and 27.3s serially, and 2.29s and
2.31s with 10 workers, which is 0.121 ms per line and roughly **430x the database
rate**.

Serial RAM and core are indistinguishable on that corpus: single passes came out
1.543 and 1.325 ms per line, so the run-to-run spread is about 15% and the
best-of-three ordering between them means nothing. The core's advantage is
startup, not throughput.

## 10. How the numbers were kept honest

Three habits, each adopted after being misled:

1. **Paired, interleaved A/B.** Cross-process comparisons on this machine vary by
   5 to 6%, which once suggested a parallel regression that did not exist. Later
   measurements interleave the two configurations in one process and report best
   and median, and a difference is only believed when every round separates.
2. **Deterministic metrics where possible.** Bytes consed and scanner-compilation
   counts do not have run-to-run noise, and they settled two questions that timing
   could not.
3. **Byte-level verification for build-time code.** The parity harness reads the
   snapshot, so it cannot see loader changes. Rebuilding the snapshot and
   comparing against the previous artifact can: after the loader refactor in this
   session, 1.72GB of table data and the whole sense snapshot are byte-identical,
   with only the build stamp differing.

## Benchmark corpora are not distributed

The throughput measurements in this file were taken on large samples of real
Japanese text (a 350k-character magazine sample, a manga-magazine sample, novel
prologues and visual-novel dialogue). Those files are third-party material, so
they are not distributed with this repository and appear in no commit.

Every harness takes its input from the `CORPUS` environment variable and falls
back to `data/golden-corpus.txt`, which this project authors itself:

```
CORPUS=/path/to/your/text.txt ./scripts/sbcl-wrapped --non-interactive \
  --load scripts/bench-lines.lisp --eval '(main)'
```

Line counts, character counts and timings are quoted above so the numbers stay
meaningful without the text: a 350k-character sample of magazine prose, dense in
OCR noise and Latin-alphabet garbage, and small visual-novel and prologue
samples.
