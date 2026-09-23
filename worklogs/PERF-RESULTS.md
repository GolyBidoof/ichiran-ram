# Measured results

Every number here is from `scripts/bench-all.sh` on the recorded machine (Apple
Silicon, 14 logical CPUs, SBCL 2.6.8, PostgreSQL 16). Wall time is the whole
process, so it includes starting up; "to first answer" is the time from process
start to the first line romanized, which is what a user actually waits for.
Warm is best of three consecutive passes inside one process.

## Time

| corpus | path | wall | to first answer | warm best | per line |
| --- | --- | --- | --- | --- | --- |
| golden-corpus (382 lines, 4093 chars) | database | 85.85s | 21.81s | 20.331s | 53.22ms |
| | RAM snapshot | 13.00s | 1.94s | 1.521s | 3.98ms |
| | baked core | 7.38s | 1.25s | 1.391s | 3.64ms |
| vn-paragraphs (39 lines, 645 chars) | database | 14.08s | 4.11s | 2.284s | 58.57ms |
| | RAM snapshot | 7.70s | 0.61s | 0.211s | 5.40ms |
| | baked core | 2.47s | 1.26s | 0.201s | 5.16ms |
| vn-paragraphs2 (84 lines, 1665 chars) | database | 29.17s | 7.77s | 6.116s | 72.81ms |
| | RAM snapshot | 8.72s | 0.87s | 0.478s | 5.69ms |
| | baked core | 3.57s | 0.85s | 0.475s | 5.66ms |

Reading is 11 to 15 times faster than the database path, and the core image
starts in about a second instead of four to twenty-two.

Note that the RAM and core paths *parse* at the same speed. The core's advantage
is entirely startup, and the snapshot path's cost is the 3.2 to 3.5 seconds it
spends loading the dictionary.

## Space

| thing | size |
| --- | --- |
| PostgreSQL database | 3717 MB |
| RAM snapshot (`ichiran-int.snap`) | 1.61 GB |
| baked core (`ichiran-serving.core`) | 0.45 GB compressed |
| live heap of the whole dictionary | 2786 MB |

The snapshot was taken before the sense layer was included, so it holds the
integer layer only; the sense layer still comes from PostgreSQL at startup in
the snapshot path. The baked core includes both and needs no database.

The 2786 MB live heap is the interesting number. Before the pools were encoded
the same dictionary was around 8GB, because the memory was dominated not by the
text but by eight million separate string objects and two eight-million-entry
hash tables. Removing those objects is what made the whole dictionary fit in a
0.45 GB core.

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

The startup is now small enough that the remaining pieces are of similar size
and none of them is dominant:

- the sense layer, 0.9s, still read from PostgreSQL in the snapshot path. Folding
  it into the snapshot removes the database dependency as well as the time.
- `conj_source_reading`, 0.78s of decode, is now one 150MB UTF-8 blob, so the
  cost is the character conversion rather than object construction. Storing the
  blob as character codes would make that a memory copy.
- loading the system itself is about 3.0s before any dictionary work, which the
  baked core avoids entirely.
- parsing is 3.6 to 5.7ms per line and is now the largest single component of a
  warm run. `get-seg-splits` is 43% of allocation per the hotpath audit, and the
  split representation is still cons lists.
