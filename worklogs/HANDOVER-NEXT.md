# Ichiran Performance Work — Handover for the Next Agent

*Written 2026-09 after the R1–R5 + benchmarking sessions. This supersedes the
earlier `HANDOVER.md` addendums for anything that conflicts. Everything here
is grounded in actual session results — verify with the listed commands, don't
trust prose.*

---

## 0. TL;DR — where things stand

- **A working environment**: SBCL 2.6.8 + PostgreSQL 16 (`jmdict` db) +
  quicklisp, all writable state in-workspace (`local-env/`). Parity 782/782,
  golden byte-identical, **flags default OFF** (zero behavior change).
- **The big architectural goal is DONE and committed**: compact in-RAM
  dictionary (R1/R4/R5), compact trie (R3), and a working zero-DB serving
  core. All behind default-OFF flags.
- **The #1 historical blocker was a wrapper bug**, now fixed: see §3.
- **Open problem for the next agent**: one conjugation-parity gap
  (te-iru decomposition: DB splits しています → して+います, RAM → してい+ます)
  that needs a full-dict load to debug — see §7. And the full-dict core dump
  needs a 64GB host (this Mac caps SBCL at 16GB).

---

## 1. Environment (all verified)

| Component | How to use |
|---|---|
| SBCL | `scripts/sbcl-wrapped` — THE ONLY way to run SBCL. Sets in-workspace fasl/quicklisp. |
| PostgreSQL | `localhost:5432`, db/user `jmdict`, password `password` (data in `local-env/pgdata/`). If it's down: `pg_ctl start -D local-env/pgdata`. |
| Parity | `./scripts/parity.sh` → `PARITY_OK` (782/782) |
| Golden | `./scripts/golden-diff.sh` → `GOLDEN_DIFF_OK` (byte-identical) |
| Per-table bench | `BENCH_CONFIG='("kana_text" ...)' ./scripts/sbcl-wrapped --dynamic-space-size 16384 ... --load bench-config.lisp --eval '(bench-config:main)'` |

**SBCL arg order (verified, painful to learn):** `--dynamic-space-size` MUST
be first; with `--core`, the order is `--dynamic-space-size N --core <file>
--no-userinit --eval ...` (everything after `--core` is treated as Lisp
options). The wrapper handles this; when calling raw `/opt/homebrew/bin/sbcl`
replicate it.

**Loading order for any test script**: always
`--eval '(ql:quickload :ichiran :silent t)'` THEN
`--eval '(load "src/memdict-compact.lisp")'` THEN `--load <your file>` —
otherwise your file fails at READ time with "Package X does not exist".

---

## 2. Committed work (git log, newest first)

| Commit | What | Verified |
|---|---|---|
| `7bdcabd` | R5 table-gated RAM lookups (`memdict-call` checks `*loaded-tables*`), `memdict-reset`, `memdict-kanji-kana-fallback`, `bench-config.lisp` | parity+golden green; benchmark findings in `worklogs/TABLE-BENCHMARK.md` |
| `591795f` | R5 analyzer wiring: find-word kana+kanji, calc-score entry/uk/posi, get-senses-raw, get-conj-data → RAM behind `*memdict-p*`; shims for compact-entry/conj-prop/sense-prop | parity+golden green; individual lookups DB-identical (senses-raw EQUAL T) |
| `35082d9` | R5 full-dict loaders (all 9 tables) + RAM lookups (senses-raw, non-arch-posi, uk, entry-by-seq, conj-data, has-conj-p) | loads bare + with ichiran |
| `c72534b` | adjoin-word shims for compact structs (analyzer runs on serving core) | core romanize byte-identical |
| `118b5f1` | memdict-load `:tables` param (kanji too); build-image.sh TABLES knob | kana+kanji load verified |
| `bbe6968` | `scripts/serve-core.sh` — zero-DB stdin→JSON dict-lookup server | live: こんにちは → correct row, miss → `[]` |
| `293751c` | `sbcl-wrapped --core` support (skip quicklisp setup for core images) | core loads, stats shown |
| `d0a75a6` | **CRITICAL**: fix `sbcl-wrapped` discarding `--dynamic-space-size` | 14GB heap now honored (was always 4GB) |
| `fd35e4a` | R4 minimal-core build path (postmodern only) | full kana dict bare load fits 8GB |
| `cd29d15` | R3 compact trie (one edge-hash + node vector) | 0 mismatches vs brute force; 198MB/1M entries |
| `6aaefb8` | R4 decouple memdict-compact (postmodern only) + separate shims file | bare load OK |
| `48de65c` | S2-v3 substring-hash nil-sentinel (skip DB probe for non-dict substrings) | 12–33% fewer queries, output identical |

Earlier baseline (before this agent's rounds): S1 cache, S2 batching,
S3 DAO memdict, S5 daemon+driver, S6 char-scans — all behind flags.

---

## 3. The critical discoveries (read these first)

1. **`sbcl-wrapped` discarded `--dynamic-space-size`** (commit `d0a75a6`).
   The parser did `shift 2` with NO replacement, so every run used the 4GB
   default — ALL earlier "16GB" attempts (incl. the pre-session R4 core
   builds) actually ran at 4GB and "heap exhausted at exactly 4294967296
   bytes". If a future build "exhausts at 4GB", check the wrapper flag
   handling first.

2. **The 16GB wall is really two walls**:
   - (a) loading the compact dict ON TOP of the `:ichiran` analyzer baseline
     — FIXED by decoupling memdict-compact (loads with postmodern only);
     full kana+kanji (~7GB) fits an 8GB bare heap.
   - (b) `save-lisp-and-die` needs ~2× dict headroom — kana-only core (3GB
     dict → 129MB compressed core) builds on this Mac; full 9-table
     (12.2GB raw, ~13–16GB with indexes) load works but the DUMP exceeds
     16GB. Needs a 32–64GB host (the user has 64GB).

3. **Golden-diff false drift**: `golden-diff.sh` writes
   `/tmp/golden-current.json` and deletes it on success. If two runs overlap
   (or a stale file lingers), you can see spurious "GOLDEN_DIFF_DRIFT". When
   in doubt, re-run it alone with a clean /tmp. The committed state IS
   byte-identical (verified multiple times).

4. **worklogs/ is gitignored** — the `.md` files there (FINAL-REPORT.md,
   TABLE-BENCHMARK.md, HANDOVER*.md) exist only on disk, not in git. Code
   commits are what matter.

---

## 4. The R5 in-RAM dictionary (the current headline feature)

`src/memdict-compact.lisp` loads ALL dictionary tables as compact defstructs
with interned strings:

| Table | Rows | MB (measured) |
|---|---|---|
| kana_text | 3,289,512 | 2,683 |
| kanji_text | 5,435,705 | 4,325 |
| entry | 2,512,557 | 633 |
| conjugation | 2,343,276 | 340 |
| conj_prop | 2,358,731 | 287 |
| conj_source_reading | 8,386,607 | 3,929 |
| sense | 251,648 | 38 |
| gloss | 434,112 | 256 |
| sense_prop | 407,620 | ~300 (est) |
| **TOTAL** | ~25M | **~12.2 GB** (+ indexes ≈ 13–16 GB) |

**Enable**: `(setf ichiran/dict::*memdict-p* t)` after loading
memdict-compact + memdict-compact-shims + `(memdict-load :chunk 100000)`.
**Default OFF → zero behavior change.**

**RAM lookups** (all individually verified DB-identical): `memdict-find`
(kana+kanji), `memdict-entry-by-seq`, `memdict-senses-raw` (EQUAL T vs DB
for seq 1289400, incl. the pos/s_inf/stagk/stagr/field tag filter),
`memdict-non-arch-posi`, `memdict-uk`, `memdict-conj-data`,
`memdict-has-conj-p`, `memdict-kanji-kana-fallback`.

**Table gating** (`memdict-call` in dict.lisp): each lookup only serves from
RAM when its required table is in `*loaded-tables*`; otherwise NIL → DB
fallback. This makes partial loads correct (found by the benchmark — see §6).

---

## 5. The R4 serving core (zero-DB for dict lookups)

- `scripts/build-image.sh` → `local-env/ichiran-serving.core` (129MB):
  postmodern-only image with the full 3.08M-row kana compact dict in RAM,
  zero DB. Loads instantly; serves lookups via `scripts/serve-core.sh`
  (stdin→JSON; verified こんにちは → correct row, miss → `[]`).
- The full analyzer quickloads on top (`--core <core> --eval
  '(ql:quickload :ichiran :silent t)'` + shims + `*memdict-p* t`) and
  romanizes **byte-identical** to the DB path.
- Full kana+kanji core (7GB dict) loads but the dump needs 32GB+.

---

## 6. Per-table benchmark — what helps which sentences (the repo pitch)

Method + full results in `worklogs/TABLE-BENCHMARK.md` (`bench-config.lisp`,
one process per config, S1 cache OFF). 8-sentence corpus across hiragana /
katakana / kana+kanji / kanji-heavy / paragraph.

| Config | Total queries | vs DB-only |
|---|---|---|
| DB-only | 5919 | — |
| +kana_text | 4871 | −17.7% |
| +kanji_text | 4302 | −27.3% |
| **+sense+gloss+sense_prop** | **2135** | **−63.9%** ← the big win (only ~0.6GB) |
| +conjugation ALONE | 3132 | −47.1% but WORSE than senses-only |
| +conj_prop (no csr) | 4899 | −17.2% (worse — trio needed) |

**Recommended load order (impact-per-GB, differs from naive order):**
1. kana_text (2.7GB) — foundation, −18%
2. kanji_text (4.3GB) — foundation, −27%
3. **sense + gloss + sense_prop (0.6GB)** — the big win, −64%
4. entry (0.6GB) — cheap, small extra
5. conjugation + conj_prop + conj_source_reading (4.6GB) — as a full trio,
   last (conj tables HURT if loaded partially).

**Per-sentence-type**: hiragana/katakana need kana_text+senses; kanji-heavy
need kanji_text+senses (biggest absolute wins); paragraphs compound all
three.

---

## 7. What did NOT work (measured, reverted / open) — save the next agent time

1. **R2 per-winning-sentence batching of reading-str-seq + short-sense-str**
   (handover §5's design): implemented, measured **NET-NEGATIVE** in fresh
   processes (~15 batch queries per sentence > per-seq savings), reverted.
   The nil-sentinel fix (`48de65c`) was the real, behavior-preserving win.

2. **Lazy miss-queue batching** (ensure-entry/posi/uk push misses, drain in
   IN-batches): caused a **query explosion** (seq-set composite keys never
   matched the single-seq seeds → re-query + batch overhead), reverted.

3. **Slice-based full-parity testing is unreliable**: hand-rolled partial
   loads pollute hash keys (a います row landed under the wrong key in one
   test) and can't reproduce complete scoring context. **Don't debug parity
   with slices — use the full `memdict-load` on a 64GB host.**

4. **The te-iru conjugation-parity gap (OPEN)**: for 日本語を勉強しています,
   DB splits しています → して + います ("shite imasu"), RAM → してい + ます
   ("shiteimasu"). Root cause NOT fully found; it's in the suffix-teiru /
   get-conj-data interaction under the RAM path, needs full-dict context to
   debug. Individual conj-data lookups match DB field-for-field, so it's
   likely a scoring-order effect from RAM-served rows. This is the one
   byte-parity gap with `*memdict-p*` ON.

5. **Full 9-table core dump** exceeds this Mac's 16GB SBCL cap (load works;
   dump needs 32GB+). Not a code defect.

6. **conj tables loaded partially make queries WORSE** (§6) — must be a trio.

---

## 8. Next steps for the next agent

1. **Debug the te-iru parity gap** on the 64GB host (or a smaller targeted
   experiment): compare `calc-score` for してい/います rows under RAM vs DB
   with the FULL dict loaded; the goal is `*memdict-p*` ON ⇒ byte-identical
   romanize on the golden corpus.
2. **Run the full verification on the 64GB host**: full `memdict-load`,
   `*memdict-p* t`, then `parity.sh` + `golden-diff.sh`. Also try the full
   9-table core dump there (32GB+ heap).
3. **Wire the serving core to serve the full romanize DB-free**: the core
   holds the dict; the analyzer on top still hits DB for the few lookups not
   yet RAM-wired (e.g. suffix map, restricted_readings, counters). The
   `memdict-call` gating makes per-table offload safe to extend.
4. **Per-table benchmark on the 64GB host**: confirm the conj trio's marginal
   value with all 9 tables actually loaded (the 16GB wall prevented the final
   config here).
5. Re-verify parity + golden after each change (both currently GREEN).

## 9. Useful one-liners

```bash
cd /Users/golybidoof/Projects/ichiran-master
./scripts/parity.sh            # 782/782 gate
./scripts/golden-diff.sh       # byte-identical gate
printf 'こんにちは\n' | ./scripts/serve-core.sh   # zero-DB lookup
BENCH_CONFIG='("kana_text" "kanji_text" "entry" "sense" "gloss" "sense_prop")' \
  ./scripts/sbcl-wrapped --dynamic-space-size 16384 --non-interactive \
  --eval '(ql:quickload :ichiran :silent t)' \
  --eval '(load "src/memdict-compact.lisp")' \
  --load bench-config.lisp --eval '(bench-config:main)'
```
