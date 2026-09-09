# Ichiran Perf Rework — Round 1 Completion Report

Date: 2026-09. Goal: rework Ichiran for much higher performance per
IMPLEMENTATION-PLAN.md, verified against a real environment.

## What was delivered (all committed, all parity-verified)

**Environment (fully working, workspace-contained):**
- SBCL 2.6.8 + PostgreSQL 16.15 + quicklisp installed natively (brew); DB
  restored from ichiran-260118.pgdump → 2,512,557 entries; add-errata done.
- All writable state lives under `local-env/` (pgdata, quicklisp copy, fasl
  cache, jmdict CSVs). `scripts/sbcl-wrapped` makes every SBCL run sandbox-safe
  (workspace-write only). Nothing outside the workspace is written.
- Parity gate: `scripts/parity.sh` → **782/782 assertions PASSED, 0 errors**
  (baseline suite was 764; corpus growth added lines, all still pass).
- Golden corpus: `data/golden-corpus.txt` (364 lines, expanded per R3's gap
  review: long run-ons ≥25 chars, counters 本/杯/個/人/円, missing conjugations
  ちゃう/とく/すぎる/らしい/そう/んです, rare readings 中/生/うち/行方/手前)
  + byte-identical baseline snapshot `data/golden-corpus-baseline.json` +
  `scripts/golden-diff.sh` (exit 0 = no drift).

**Performance modules (all behind flags, default OFF → zero behavior change):**
| Module | File | What it does | Verified |
|---|---|---|---|
| S1 seq-cache | `src/cache.lisp` | Thread-safe memo of entry/posi/uk/conj-data per seq | equality vs direct DB; hits accumulate; cross-sentence reuse |
| S2 prefetch | in `cache.lisp` + `dict.lisp` | One batched `IN` query per sentence for entries | no query regression (252–1101 ≈ baseline) |
| S4 trie | `src/trie.lisp` | Character-trie prefix-walk candidate search | 6/6 probes match brute force |
| S5 daemon | `src/daemon.lisp` | Persistent stdin→JSON stdout, warm process | valid JSON per line, error-safe |
| S5 driver | `src/driver.lisp` | lparallel pool, ordered results | 4 lines / 4 threads OK |
| find-word fix | `dict.lisp` | Stale substring-hash initargs fall back to DB (pre-existing crash) | fixed cross-sentence crash |

**Measured numbers (baseline, recorded in worklogs):**
- 139–1041 SQL queries per single sentence (per-candidate `calc-score` fan-out).
- Warm daemon: ~284 ms/sentence for a 14-char sentence with :with-info
  (vs ~1.2 s cold + per-invocation startup).
- S1/S2 reduce *cross-sentence* duplicate lookups (the daemon case) but NOT
  single-sentence counts — the single-sentence count is dominated by
  per-candidate conj-source-reading/conj-prop + gloss queries that are mostly
  unique per seq, so they don't dedup within one sentence.

## Key findings that reshape the plan

1. **S1 alone doesn't cut single-sentence queries** — each candidate's seq is
   mostly unique within a sentence; dedup only pays across sentences (warm
   daemon). The 500+ queries/sentence come from `get-conj-data`'s per-conj
   sub-queries + the `:with-info` gloss path.
2. **The real single-sentence levers** are (a) S3 in-memory dict (kill DB
   round-trips entirely) and (b) batching conj-data/gloss lookups per sentence
   (the next S2 step, unfinished). S4 trie cuts candidate count.
3. **Found + fixed a pre-existing crash**: `find-word`'s `*substring-hash*`
   fast path (`apply 'make-instance` on stale initargs) crashes on cross-
   sentence reuse — now falls back to DB. (This is exactly the kind of latent
   bug the golden corpus is designed to catch.)
4. **Subagents in this session cannot run SBCL** (they die silently on any
   quickload) — all SBCL-backed work was done inline. Read-only analysis
   subagents (R3 corpus review) worked and added real value.

## What remains (next round)

- **S3 in-memory dict** (`src/memdict.lisp`): load hot tables into hashes at
  boot; the biggest remaining single-sentence win (kill DB from hot path).
- **S2 v2**: batch conj-data + gloss/sense lookups per sentence (not just
  entries) — the next query-count lever.
- **S4 integration**: swap `join-substring-words*` inner loop to the trie
  behind `*trie-p*`.
- **I2**: add `--serve` mode to `cli.lisp` main (daemon); flip flags in build
  scripts; re-run full parity on all flag combos; measure final before/after.
- Fix `src/*.lisp` file modes (currently `-rw-------`; make `-rw-r--r--`).

## How to run everything

```bash
cd /Users/golybidoof/Projects/ichiran-master
./scripts/env-check.sh          # env healthy?
./scripts/parity.sh             # 782/782 gate
./scripts/golden-diff.sh        # byte-identical parity vs baseline
./scripts/bench.sh              # query/time/consing baseline
./scripts/golden-snapshot.sh    # regenerate baseline (after corpus changes)

# Enable S1/S2 cache in a session:
sbcl-wrapped --eval '(ql:quickload :ichiran :silent t)' \
             --eval '(load "src/cache.lisp")' \
             --eval '(setf ichiran/dict::*use-cache-p* t)'
```

## Guardrails honored
- No scoring/split/hint/errata constants changed (only additive flags + one
  crash-robustness fallback that preserves behavior).
- No DB schema changes. No test-assertion edits (suite grew only via corpus).
- Every behavior change ships behind a flag default OFF; parity green both ways.
