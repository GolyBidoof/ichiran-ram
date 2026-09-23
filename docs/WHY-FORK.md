# Why this fork exists (docs/WHY-FORK.md)

Upstream [ichiran](https://github.com/tshatrov/ichiran) answers every dictionary
lookup from PostgreSQL while it analyzes text. A sentence asks the database for
every candidate word, reading, conjugation and gloss, which is thousands of
queries for one sentence, and all of them sit on the critical path. Over a
non-local database link that dominates everything, and even on localhost it is
the largest single cost in the analyzer.

This fork takes the database out of the serving path. The dictionary tables load
once into compact indexed structures in RAM, the analyzer's hot lookups route to
them behind flags that default to off, and the whole thing can be baked into one
file that is ready to answer in about a second with no database at all.

## What that is worth

| | PostgreSQL (upstream) | RAM snapshot | Baked core |
| --- | --- | --- | --- |
| One line, warm | 51.7 ms | 1.27 ms | 1.27 ms |
| One line, 10 threads | not measured | 0.121 ms | 0.122 ms |
| SQL queries per line | 17.12 | 0.28 | none on the serving path |
| Ready before any input | about 69 s | about 8.5 s | about 1.3 s |
| Memory held while serving | the database's own | 8.1 GB | 8.1 GB |

The whole dictionary fits in 8.1GB of heap, on one 1.6GB snapshot or inside a
469MB core, so a 16GB laptop can hold it and a container needs no database
service at all. On 18,939 lines of magazine text the database path needs about 16
minutes and the parallel RAM path takes 2.3 seconds.

## What is distinct here

- **In-RAM dictionary** (`src/memdict-compact.lisp`, `src/memdict-int.lisp`):
  per-access-pattern indexes, typed columns with interned pools for the six hot
  tables, copy-on-return so analyzer mutations never pollute the indexes, and the
  database's row order mirrored so scoring tiebreaks agree.
- **Snapshots** (`src/int-snapshot.lisp`, `src/sense-snapshot.lisp`): the loaded
  tables written as raw bytes, which turns a 72 second database load into 8.9
  seconds and lets the sense layer come from disk instead of SQL.
- **A baked core** (`scripts/build-image.sh`): the analyzer, the dictionary and
  the filled caches in one image, ready in about 1.3 seconds and serving with no
  database.
- **Parallel serving** (`src/serve-parallel.lisp`): one worker per core, output
  in input order, 10.9x to 12.8x on the machines measured.
- **Verification first** (`scripts/parity.sh`, `scripts/golden-diff.sh`,
  `scripts/ram-parity.sh`): the output is byte-identical to the database path,
  and the gates were built before the speed work rather than after it.

## Scope boundaries (what this fork does not do)

- No scoring, split, hint, synergy, penalty or errata changes.
- No database schema changes.
- With every flag off, the analyzer runs on PostgreSQL exactly as upstream does.

## For whom

Anyone who has to run ichiran over a lot of text, in a container, on a machine
with no database, or behind a latency budget: subtitle and OCR pipelines, corpus
and vocabulary analysis, card mining, and preparing Japanese text for other
tools.

`worklogs/` holds the development session notes, including every benchmark and
the ideas that were tried and rejected.
