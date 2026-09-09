# In-RAM Dictionary & Zero-DB Serving (docs/RAM-DICTIONARY.md)

This fork can run ichiran's dictionary lookups from RAM instead of PostgreSQL
— from a 4-table "lite" config on a laptop up to a full 9-table image on a
big host. Everything is behind flags that default OFF: with flags off, the
code paths are byte-identical to upstream.

## Contents

- [Quick start](#quick-start)
- [Requirements](#requirements)
- [How it works](#how-it-works)
- [Table gating (partial loads are correct)](#table-gating-partial-loads-are-correct)
- [Load order and memory](#load-order-and-memory)
- [Serving cores](#serving-cores)
- [Verification](#verification)
- [Benchmarks](#benchmarks)
- [Troubleshooting](#troubleshooting)
- [Known limits](#known-limits)

## Requirements

- SBCL (local dev on 2.6.8; Docker image pins 2.2.4), quicklisp, PostgreSQL 16.
- RAM per preset (dict size + `save-lisp-and-die` needs ~2× headroom):
  kana-only and `lite` (~3.3GB dict) build on a 16GB Mac; `full` (~12GB
  dict, all 9 tables) needs a 32–64GB host to build and hold.

## Quick start

Production RAM serving REQUIRES `src/memdict-compact-shims.lisp` loaded
(i.e. `(ql:quickload :ichiran/ram)` or the manual `--eval` sequence below):
`memdict-compact` alone only fills the hashes — without the shims'
defmethods on the analyzer generics, RAM rows never reach scoring,
compounding, or conjugation.

```bash
# 1. DB + environment as usual, then load 4 tables (~3.5GB RAM):
./scripts/sbcl-wrapped --dynamic-space-size 14336 --non-interactive \
  --eval '(ql:quickload :ichiran :silent t)' \
  --eval '(load "src/memdict-compact.lisp")' \
  --eval '(load "src/memdict-compact-shims.lisp")' \
  --eval '(ichiran/conn:with-db nil
            (ichiran/memdict-compact:memdict-load
              :chunk 100000
              :tables (list "kana_text" "sense" "gloss" "sense_prop")))' \
  --eval '(setf ichiran/dict::*memdict-p* t)' \
  --eval '(ichiran:romanize "こんにちは")'
# => "konnichiwa" (kana + senses served from RAM, rest from DB)
```

Or build a reusable image (no per-boot load, still needs the analyzer
quickloaded on top for full romanize):

```bash
PRESET=lite ./scripts/build-image.sh --out local-env/ichiran-lite.core
# kana-only:            ./scripts/build-image.sh
# full 9-table (32GB+ host): PRESET=full ./scripts/build-image.sh
# + baked trie:         TRIE_TABLES='"kana_text"' ./scripts/build-image.sh
```

Presets: `lite` = kana_text+sense+gloss+sense_prop (~3.3GB dict, builds on a
16GB Mac, covers ~60% of queries). `full` = all 9 tables (~12GB dict,
needs a 32–64GB host to build and hold).

## How it works

`src/memdict-compact.lisp` loads dictionary tables as compact `defstruct`
rows with interned strings, indexed per analyzer access pattern (by text, by
seq, by sense-id, …). `src/memdict-compact-shims.lisp` (full-ichiran context
only) gives the structs the analyzer's generic interface (`seq`, `text`,
`word-conj-data`, `adjoin-word`, …), so RAM rows flow through scoring,
compounding, and conjugation exactly like DB rows.

`ichiran/dict::*memdict-p*` (default `nil`) routes hot lookups to RAM:

| Analyzer query | RAM function | Needs |
|---|---|---|
| find-word kana/kanji | `memdict-find` | that side's text table |
| entry by seq | `memdict-entry-by-seq` | entry |
| uk rows | `memdict-uk` | sense+sense_prop |
| non-arch posi | `memdict-non-arch-posi` | sense+sense_prop |
| senses+gloss | `memdict-senses-raw` | sense+gloss+sense_prop |
| conj triples | `memdict-conj-data` | conjugation trio |
| has-conj guard | `memdict-has-conj-p` | conjugation |
| reading strings | `memdict-text-by-seq` | per side |
| short gloss | `memdict-short-sense-str` | sense+gloss (+sense_prop for pos filter) |
| conj lists/props | `memdict-select-conjs`, `memdict-conj-props` | conjugation / conj_prop |
| orig-text probes | `memdict-find-by-seq-text` | per side |
| counter ids/stags | `memdict-counter-ids/stags` | sense_prop |
| substring windows | RAM-seeded `substring-hash` (+ optional trie) | text tables |

Deliberately still on DB: suffix map (already in-memory via `*suffix-cache*`),
`restricted-readings` (never fired in the benchmark corpus), counter readings
(2 batched queries once per process), conj-parent joins (rare).

Two rules keep RAM serving correct:

1. **Copy-on-return.** The analyzer mutates readings (`word-conjugations`,
   `hintedp`) and `nconc`s find-word results. Every kana/kanji row crossing
   into the analyzer is a fresh copy, so the RAM indexes never get polluted
   across sentences (this exact bug once leaked compounds into the index and
   crashed a later sentence with `integer = record`).
2. **DB row order is mirrored.** Per-key lists load in ascending id order and
   are normalized once after load, so scoring tiebreaks usually agree with the
   DB path (see [Known limits](#known-limits)).

## Table gating (partial loads are correct)

`memdict-call` serves a lookup from RAM only when **all** tables it needs are
in `*loaded-tables*`; otherwise it returns NIL and the caller uses the DB.
The senses trio and the conjugation trio gate as units — benchmarks showed
partial conj loads are *slower* than DB fallback. `memdict-table-loaded-p`
lets hot paths trust a RAM miss and skip the DB entirely when loaded.

## Load order and memory

Measured rows and RAM (local full DB):

| Table | Rows | RAM |
|---|---|---|
| kana_text | 3,289,512 | 2.7 GB |
| kanji_text | 5,435,705 | 4.3 GB |
| entry | 2,512,557 | 0.6 GB |
| conjugation | 2,343,276 | 0.3 GB |
| conj_prop | 2,358,731 | 0.3 GB |
| conj_source_reading | 8,386,607 | 3.9 GB |
| sense+gloss+sense_prop | ~1.1M | ~0.6 GB |

Impact-per-GB load order (measured, `worklogs/TABLE-BENCHMARK.md`):
kana_text → kanji_text → **sense trio (−64% queries alone)** → entry →
conjugation trio last, only together.

## Serving cores

`scripts/build-image.sh` dumps a bare (postmodern-only) image with tables
preloaded; `scripts/serve-core.sh` serves stdin→JSON lookups with zero DB.
`local-env/ichiran-lite.core` (168MB compressed) holds kana+senses. The full
analyzer quickloads on top of a core and romanizes identically (verified).

`save-lisp-and-die` needs ~2× dict headroom: kana-only and lite cores build
on a 16GB Mac; the full 9-table dump needs 32GB+.

## Verification

- `scripts/parity.sh` — test suite, must print `PARITY_OK`.
- `scripts/golden-diff.sh` — byte-identical romanize output vs baseline.
- Every `memdict-load` ends with `MEMDICT-VERIFY-OK <table> ram=N db=N`
  per table (row counts vs `SELECT count(*)`). A `VERIFY-FAIL` means the load
  is corrupt — this gate exists because unordered `LIMIT/OFFSET` paging once
  silently loaded only 1.55M of 2.5M entry rows. Loads always `ORDER BY` a
  unique key now.
- `tests.lisp` has `ram-gating-test` + `ram-helpers-test`: fixture-based unit
  tests (no DB, no big loads) covering gating, ordering, determinism,
  copy-on-return, counters, and the verify gate.

## Benchmarks

Method: `scripts/bench-config.lisp`, fresh process per config, S1 cache OFF,
`romanize :with-info t`, per-sentence DB query counts + wall time.
8-sentence corpus: DB total 5845 queries → lite 2459 (**−58%**, every
sentence −52…−63%). Full page (19 paragraphs, 4.3K chars): 180,985 →
89,335 queries (**−51%**), 19.8s → 10.3s (**−48%**) on localhost. Over a
remote DB the query-count win matters more than local wall time. Details:
`worklogs/TABLE-BENCHMARK.md`, `worklogs/R6-REPORT.md`.

## Troubleshooting

- **Heap-exhausted during load/dump**: raise `--dynamic-space-size`
  (e.g. 14336 on a 16GB Mac) and check the flag actually reached SBCL —
  `scripts/sbcl-wrapped` honors it but SBCL requires runtime opts before
  `--eval` args, so pass it through the wrapper rather than appending raw
  `sbcl` flags after `--eval`s.
- **VERIFY-FAIL**: the load is corrupt — `(ichiran/memdict-compact:memdict-reset)`,
  then reload fresh in a fresh process (stale/partial state from an earlier
  load in the same image does not clear itself).
- **Golden drift on one sentence**: re-run first — `golden-diff` is bimodal
  on one knife-edge tiebreak sentence even with all flags off (see Known
  limits); RAM output sits inside the analyzer's natural DB-vs-DB variation.

## Known limits

- **Knife-edge tiebreaks.** Where two segmentations score (near-)identically
  (`toiu` vs `to`+`iu`, `nanjikara` vs alternatives), DB and RAM can pick
  different winners because candidate order differs — and DB-vs-DB runs can
  too (golden-diff is bimodal on one sentence even with all flags off).
  RAM output sits inside the analyzer's natural variation; deterministic
  tiebreaks are future upstream work.
- **Full-dict RAM parity** (`*memdict-p*` with all 9 tables) needs the 64GB
  host for final confirmation (this Mac caps SBCL at 16GB).
- S1 memo cache and full-RAM overlap: with all tables loaded the cache is
  pure overhead (RAM is checked first anyway).
