# Measured results

Every number is from `scripts/bench-all.sh` on the recorded machine (Apple
Silicon, 14 logical CPUs, SBCL 2.6.8, PostgreSQL 16). Wall time is the whole
process, so it includes starting up; "to first answer" is the time from process
start to the first line romanized, which is what a user actually waits for.
Warm is best of three consecutive passes inside one process, over the dumpable
lines of the corpus (blank lines and `#` comments are skipped).

## Time

| corpus | path | wall | to first answer | warm best | per line |
| --- | --- | --- | --- | --- | --- |
| golden-corpus (382 lines, 4093 chars) | database | 86.48s | 22.38s | 20.152s | 52.76ms |
| | RAM snapshot | 13.05s | 2.14s | 1.523s | 3.99ms |
| | baked core | 7.80s | 1.25s | 1.498s | 3.92ms |
| vn-paragraphs (39 lines, 645 chars) | database | 14.03s | 4.13s | 2.234s | 57.29ms |
| | RAM snapshot | 7.18s | 0.64s | 0.204s | 5.24ms |
| | baked core | 2.48s | 1.26s | 0.207s | 5.30ms |
| vn-paragraphs2 (84 lines, 1665 chars) | database | 29.31s | 8.00s | 6.086s | 72.45ms |
| | RAM snapshot | 8.66s | 0.97s | 0.546s | 6.50ms |
| | baked core | 3.70s | 1.25s | 0.503s | 5.99ms |

Reading is 11 to 15 times faster than the database path, and the core image
reaches a first answer in about 1.25s where the database takes 4 to 22 seconds.

The RAM and core paths parse at the same speed. The core's advantage is
entirely startup: the snapshot path spends 2.9 to 3.1s loading the dictionary
before it can answer anything, and the core has already done that at
build time.

For a single sentence the database path is not catastrophically slower, because
its startup is small next to per-line cost. The gap opens on paragraphs: the
database is 52 to 72ms per line against 4 to 6.5ms.

## Space

| thing | size |
| --- | --- |
| PostgreSQL database | 3717 MB |
| snapshot, integer layer | 1644 MB |
| snapshot, sense layer | 26 MB |
| baked core | 466 MB compressed |
| live heap of the whole dictionary | 2739 MB |

The live heap is the interesting number. Before the string pools were encoded
the same dictionary sat around 8GB, because the memory was dominated not by the
text but by eight million separate string objects and two eight-million-entry
hash tables. Removing those objects is what made the whole dictionary fit in a
466MB core, and what made the core possible on a 16GB machine at all.

## Where startup time went

Snapshot load, before and after this round:

| phase | before | after |
| --- | --- | --- |
| `conj_source_reading` decode | 2.79s | 0.79s |
| `kanji_text` decode | 1.87s | 0.55s |
| `kana_text` decode | 1.04s | 0.37s |
| `entry` decode | 0.51s | 0.45s |
| rebuild derived indexes | 1.15s | 0.33s |
| total snapshot load | 7.31s | 2.49s |
| sense layer | 0.77s (SQL) | 0.33s (snapshot) |
| dictionary load | 8.10s | 2.9s |

`int-snapshot-load` prints this breakdown to `*trace-output*`, so it can be
re-measured rather than taken on trust:

```
SNAPSHOT-PHASES decode=2.16s rebuild-indexes=0.33s
  conj_source_reading          decode=  0.78s rebuild= 0.17s
  kanji_text                   decode=  0.55s rebuild= 0.00s
  entry                        decode=  0.45s rebuild= 0.00s
  kana_text                    decode=  0.37s rebuild= 0.00s
  conjugation                  decode=  0.01s rebuild= 0.09s
  conj_prop                    decode=  0.00s rebuild= 0.07s
```

## What is left

Startup is now small enough that no single remaining piece dominates:

- loading the system itself is about 3.0s before any dictionary work. The
  baked core avoids it entirely, which is most of why the core reaches a first
  answer four times sooner.
- `conj_source_reading`, 0.78s of decode, is now one 150MB UTF-8 blob, so the
  cost is character conversion rather than object construction. Storing that
  blob as character codes would turn it into a memory copy.
- parsing is 3.9 to 6.5ms per line and is now the largest component of a warm
  run. The hotpath audit puts `get-seg-splits` at 43% of allocation; the split
  representation is still cons lists, and flattening it is the next real win.
  `apply-segfilters` already returns early once nothing survives.

## Zero-database core

A baked core no longer needs PostgreSQL at all. Measured with the server
stopped: all 382 golden lines analyze, serialize and open no connections, and
the JSON is byte-identical to the database-backed reference. With the server
running `scripts/ram-parity.sh` reports RAM_PARITY_OK.

Finding the remaining connections was the hard part, because `dict-segment` and
friends are compiled with `(speed 3)` and the connecting caller is inlined away,
so the socket error appeared to come from `dict-segment` itself with no frames
above it. Intercepting `open-database` located each one:

  * the `:is-arch` cache is built by SQL and `calc-score` consults it for every
    candidate through `is-arch`, and nothing else ever populated it. Warming it
    at build time (which also bakes the suffix cache, 5532 entries) removed it;
  * `word-info-str`, `get-kanji-words` and `find-word-info` opened connections
    directly and now use `with-dict-connection`;
  * `exists-reading` was a bare query with no gate and now reads from RAM;
  * `restricted_readings` is not a resident table, so a core that never calls
    `load-dictionary` never installed it. That left
    `ram-restricted-readings-available-p` false and sent every restricted sense
    back to SQL, which failed on lines as ordinary as いただきます. The fetch
    moved into `load-restricted-readings` and the build bakes it too (2745
    seqs), passing the connection spec explicitly because the build binds none.

One more trap: the compact text hashes still exist under the integer backend,
they are simply never filled, so testing `(boundp '*kana-by-text*)` selected an
empty hash. The check has to be for a non-empty one.

## Baked prefix trie: implemented, measured, rejected

The trie builder read `*kana-by-text*`, which the integer backend never fills,
so every trie ever built was empty: 0 texts, 1 node, reported as success in
0.1s. It now walks the encoded text pool instead. Two further traps: the pool
holds the DISTINCT texts while the table's `n` slot is its row count, so
driving the loop from `n` ran off the end of the offsets array.

The fixed trie builds for real: 8411392 texts, 13303350 nodes. It is not shipped,
because it does not pay:

| line | no trie | trie |
| --- | --- | --- |
| 一日本漫画家協会 | 0.490 ms | 0.492 ms |
| 聖杯戦争。 | 0.168 ms | 0.212 ms |
| いただきます | 0.762 ms | 0.876 ms |

It also needs more heap than the core is saved with, and died with
HEAP-EXHAUSTED at the default dynamic space. The reason is that candidate
windows are nearly all valid prefixes in these dictionaries, so there is nothing
for a prefix index to prune. The code stays, off by default and behind
`TRIE_TABLES`, but no trie core is shipped.

## 350k character magazine

18939 lines, 335008 characters, average 17.7, longest 170, and heavily mixed:
169k hiragana, 82k kanji, 38k katakana, 22.5k punctuation, 20.9k Latin and 19.9k
fullwidth, with the OCR and Latin noise the corpus was chosen for.

    SERIAL   lines=18939 wall=19429.6ms ms/line=1.026
             p50=0.808 p90=1.944 p95=2.768 p99=5.690 max=21.931
             GC 136.5ms, 688.3kB consed per line
    PARALLEL workers=10 wall=2577.3ms ms/line=0.136
             speedup=9.97x efficiency=99.7% skew=1.00x errors=0 cache=99%

The slowest lines are now simply the longest ones, 119 to 148 characters. The
two shapes that used to be pathological are not any more: 一日本漫画家協会 is
0.490 ms, down from 26.7 ms, and 聖杯戦争。 is 0.168 ms, down from 31 ms. Both
are explained by the caching work, not by the trie.

Cached profile, inclusive:

    JOIN-SUBSTRING-WORDS     60.8%
    JOIN-SUBSTRING-WORDS*    45.4%
    FIND-BEST-PATH           26.6%
    FIND-SUBSTRING-WORDS     23.5%
    FIND-WORD-FULL           20.3%   98.5 calls/line
    GET-SEG-SPLITS           14.8%   130.1 calls/line
    GEN-SCORE                14.3%   128.5 calls/line
    CALC-SCORE               11.3%   13.1 calls/line
    FILL-SEGMENT-PATH         7.5%

The per-worker `gen-score` cache does its job: `CALC-SCORE` falls from 130
calls per line uncached to 13.1 cached.

## What is left, revised

- Candidate generation is 60.8% and is the only large block left. It is 1.87M
  dictionary lookups for 335k characters, about eleven per character, and that
  is structural rather than wasteful.
- GC is 0.7% of serial wall, so allocation is not worth chasing by itself,
  even though the run conses 688kB per line.
- The longest lines cost about 2.4x more per character than the average, so the
  remaining super-linear term sits in candidate count times path search.

## First-character direct indexing (CSR)

The statistical profile put the text lookup clearly on the map:

    COMPARE-POOL-STRING        13.6% self     14.4% total
    INT-TEXT-POOL-INDEX         1.4% self     16.3% total

A lookup is a binary search in `int-text-pool-index` over `TEXT-ORDER`, which is
sorted by `STRING<`, and therefore by character code. Every text equal to the
target must begin with the target's first character, and all texts beginning with
one character form a contiguous run of that sorted order. So the search can be
narrowed to one character's run, and a character with no run at all ends the
lookup outright, which is what Latin text and rare kanji windows hit.

The index is CSR shaped: one flat `(unsigned-byte 32)` vector of 65537 offsets
per text table, where the texts beginning with BMP code C occupy the half-open
run `[offsets[C], offsets[C+1])`. Two adjacent array reads replace the first
comparison rounds, 256KB per table stays in cache, and an empty bucket is free
because `low == high` skips the loop. Codes outside the BMP have no bucket and
take the full range.

It is built in `int-register-text-table`, in one pass over the already sorted
order, before that function's early return for snapshot loads, so both the
database and snapshot paths get it. A baked core holds these tables in its heap,
which means the finished array is part of the saved image: the core pays nothing
for it at startup. That is also why no snapshot format change was needed, and
why the 1.6GB snapshot did not have to be regenerated.

Measured over 3000 lines of `the 350k-character magazine sample`:

    kana_text   3079757 entries   158 buckets   log2 21.55 -> 13.89 comparisons
    kanji_text  5331635 entries  5682 buckets   log2 22.35 -> 10.97 comparisons

Both tables bucket their entire contents, so coverage is exact.

Results, all with byte-identical output:

    lookup alone   186966 calls   252.8ms -> 60.9ms   4.15x
    serial         6000 lines     paired A/B, 6 rounds, 8.9% median
    parallel       18939 lines    paired A/B, 7.9% mean, 10 workers

Every ON round beat every OFF round in both paired tests.

A methodology note, because it nearly produced a wrong conclusion: comparing
whole benchmark runs across two cores does NOT resolve an effect this size. The
same core varied by 6% run to run (0.986 to 1.107 ms per line serial), which is
wider than the gain. Running the benchmark once per core suggested the parallel
path had regressed, and it had not: the paired in-process A/B, toggling the slot
between the saved array and an empty one, shows a consistent 7.9% win. Toggling
rather than rebuilding the array matters too, because rebuilding touches all 8.4M
entries and evicts the caches that the next measurement depends on.

### Two bugs the RAM test caught before any core rebuild

Both were found by loading the snapshot on the RAM path rather than by building
a core and debugging the result:

  * the defstruct default `#()` is a SIMPLE-VECTOR, which fails the new slot's
    `(simple-array (unsigned-byte 32) (*))` declaration. Every construction path
    that omits the slot signalled a type error, the snapshot loader included. The
    default has to be built with the element type.
  * `int-register-text-table` despite its name also registers `entry`,
    `conjugation`, `conj_prop` and the rest, whose objects are a different
    structure. The hook is narrowed to `kana_text` and `kanji_text`, and the
    builder refuses anything that is not an `int-text-table`.

Validation on RAM before rebuilding: 71999 probes (sampled pool texts, their
one-character extensions and suffixes, the empty string, ASCII, and BMP and
non-BMP characters) with 0 mismatches against the unbucketed search, and 0 JSON
differences over 6000 lines with the index on and off.

`scripts/ram-parity.sh` still reports RAM_PARITY_OK against the database
baseline.
