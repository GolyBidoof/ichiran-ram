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
