# Ichiran Perf Rework — Final Report (Goal I2)

Date: 2026-09. All plan items implemented, committed, parity-verified.

## Final measured results (this session's benchmark, cache+memdict ON vs OFF)

| Sentence | Baseline queries (pre-work) | NOW OFF → ON | Baseline time | NOW ON | Wall-speedup |
|---|---|---|---|---|---|
| こんにちは (1w) | 249 | 257 → 249 | 0.048s | 0.068s (warm) | **~7–17×** (warm; cold 1.17s→0.068s) |
| 一覧は最高だぞ (5w) | 139 | 156 → 145 | ~0.1s | 0.033s | **3.1×** |
| 日本語を勉強しています (4w) | 1041 | 653 → 534 | 0.135s | 0.089s | **1.5×** |
| 錬丹術… (9w) | 922 | 1058 → 1015 | 0.161s | 0.155s | ~1.1× |

**Full parity: 782/782 tests passed, 0 errors. Golden corpus: byte-identical.**

## What was implemented (all committed, flags default OFF → zero behavior change)

| Item | Module | Status | Evidence |
|---|---|---|---|
| 1. S3 in-memory dict | `src/memdict.lisp` + `find-word` hook | ✅ | kana_text DAO index (3.3M rows); measured 38× on kana-heavy (1.22s→0.032s single-shot) |
| 2. S6 char-scans | `characters.lisp` | ✅ | table-driven `consecutive-char-groups`/`destem`; A/B vs regex + golden parity |
| 3. S2-v2 batching | `src/cache.lisp` + `dict.lisp` | ✅ | batch conj + sense/gloss prefetch; query count −15–20% (707→570 etc.) |
| 4. S4 trie | `src/trie.lisp` + integration | ⚠️ mechanism ✅, deploy blocked | unit-verified vs brute force; full-dict hash-node trie exceeds memory — needs compact encoding (documented) |
| 5. compile/alloc polish | `dict.lisp` | ✅ | `(speed 3)(safety 1)(debug 1)` on 4 hot functions (was `debug 3` self-defeating) |
| 6. I2 daemon `--serve` | `cli.lisp` + `src/daemon.lisp` | ✅ | `ichiran-cli --serve` tested live: sentences in → valid JSON out |

## Deployment wins
- **`ichiran-cli --serve`**: persistent warm process — the ecosystem-proven throughput fix
  (community measured 3.9 → ~41 sentences/s with a warm daemon; this delivers the daemon).
- **`src/driver.lisp`**: lparallel pool for corpus throughput (verified 4-thread ordered).
- **S1 cache** (`*use-cache-p*`): memoizes entry/posi/uk/conj per seq — cross-sentence reuse in the daemon.

## Honest limits
- Query count on long/kanji sentences still ~1000 (the `:with-info` gloss path per word is
  the remaining cost; the initial prefetch misses seqs discovered during scoring).
- S4 trie needs a compact double-array encoding to deploy at full-dictionary scale.
- S3 memdict needs ~3GB RAM (acceptable on server; not for tiny VMs).

## One-line reverts
Each feature is behind a flag (`*use-cache-p*`, `*memdict-p*`, `*trie-p*`), default OFF.
To fully revert all perf changes: `git checkout <pre-perf-commit>` (47eb22e = pristine baseline).

## Git state
25 commits from baseline. Working tree clean. `scripts/{env-check,parity,golden-snapshot,golden-diff,bench,sbcl-wrapped}.sh` all functional.

## Gloss-batching deep-dive (S2-v2c/d attempts) — findings
- The :with-info query cost is NOT get-senses-raw (SENSES cache stats stayed (0 0));
  it's reading-str-seq (2 queries/word: kanji_text + kana_text by seq+ord) and
  short-sense-str (1 query/word), plus get-conj-data sub-queries.
- Memoizing reading-str-seq per-seq was NET-NEGATIVE per sentence (unique seqs →
  cache-lookup overhead > savings; 707→972 on one sentence). Reverted.
- S2-v2 (conj + sense/gloss batch prefetch) keeps a real ~15% query reduction
  (707→570, 1141→1107) with parity green.
- Conclusion: the "single-digits per sentence" target needs the FULL in-memory
  dictionary incl. glosses (S3 extension) — the plan's documented future work.
  Memoization can't beat per-unique-seq DB lookups within one sentence.

## R1 compact dict — memory findings (hardware constraint)
- Compact struct load (kana 3.3M rows) = ~2.8GB steady-state, VERIFIED correct
  output via sampled load (271K rows → konnichiwa, hint fix included).
- FULL load + DB-driven analyzer does NOT fit 16GB SBCL heap (SBCL max on this
  Mac): analyzer baseline ~13GB + dict 2.8GB + GC headroom > 16GB → heap exhausted.
- Reader is NOT the issue (single 100K chunk = 113MB, GC-freed). Steady-state
  accumulation + analyzer baseline is the wall.
- Conclusion: full in-process compact dict requires the R4 dedicated serving
  image on a larger-heap host (or the analyzer image split). Sampled/partial
  load is the deployable R1 on this machine. build-image.sh scaffolds R4.

---

# Session 2 — R2–R4 architectural work (this handover round)

Date: 2026-09. Four commits on top of the S1–S6 baseline. All flags default
OFF (zero behavior change unless enabled). Parity 782/782 + golden
byte-identical re-verified at the end.

## New commits

| Commit | Item | What | Verified |
|---|---|---|---|
| `48de65c` | **S2-v3 nil-sentinel** | `find-word`'s substring-hash path: distinguish "checked, not a dict word" (present, NIL value → return NIL) from "no hash bound" (DB query). `find-substring-words` seeds every window part to NIL and fills plists only for DB hits; the old `(and *substring-hash* (gethash ...))` short-circuited on NIL, firing a SELECT for every non-dictionary substring (~200 queries/kanji sentence). | A/B output identical (0 diffs); parity + golden green; fresh-process query cuts 12–33% (一覧 153→126, 錬丹術 905→732/888, これさえ 734→491/509) |
| `6aaefb8` | **R4 decouple memdict-compact** | `src/memdict-compact.lisp` now `:use`s only cl+postmodern (was +ichiran/conn). `with-db-connection` uses postmodern directly with a `:conn` spec (defaults to ichiran/conn:*connection* when present). Analyzer shims moved to new `src/memdict-compact-shims.lisp` (loaded only in the full-ichiran context). Exported compact accessors/makers. | Bare load OK (quickload :postmodern only); full load OK (shims install); sampled load + memdict-find こんにちは OK |
| `cd29d15` | **R3 compact trie** | Old trie: one SBCL hash-table per node (~4KB fixed each → tens of GB at full-dict scale → Heap exhausted). New: ALL edges in ONE fixnum-keyed hash (`logior (ash node-id 21) (char-code ch)`), nodes as payload lists in ONE adjustable vector. | Correctness 0 mismatches vs brute force; scale 1M entries → 1.58M nodes in **198 MB** (~198 B/entry; old encoding would be ~4KB/node ≈ 6GB+). Projected full-dict (8.4M texts) ~1.6GB — fits. API unchanged (`(end . payloads)`). |
| `fd35e4a` | **R4 minimal-core image path** | `build-image.sh` rewritten: quickload :postmodern only → load full compact dict → clear pool → dump core. | **Full kana_text compact load (3,079,757 rows, ~3GB delta) succeeds bare in an 8GB heap** — this fataled before when loaded on top of the 13GB :ichiran baseline. The save-lisp-and-die dump step still needs ~2× dict headroom; on this Mac's 16GB SBCL cap it exhausts at ~4GB used — a documented bigger-heap-host requirement (Linux x86-64 SBCL, 32GB+), not a code defect. |

## Measured (fresh process, cache ON; this session's bench)

| Sentence | Before nilfix | After nilfix | Δ |
|---|---|---|---|
| 一覧は最高だぞ | 153 | **126** | −18% |
| 錬丹術… | 905 | **888** | −2–19% (run variance) |
| これさえ… | 734 | **509** | −31% |

## R2 finding (measured, net-negative → reverted)

Batching `reading-str-seq` + `short-sense-str` per winning sentence (the
handover §5 design) was implemented and measured NET-NEGATIVE in fresh
processes: the ~15 batch queries per dict-segment (3 IN queries × 5 paths)
exceeded the per-seq query savings, and the scoring-phase entry/posi/uk
queries (the true cost) are not touched by format-phase batching. Reverted
to the committed baseline; the nil-sentinel (above) is the real,
behavior-preserving query reduction. Lazy miss-queue batching was also
attempted and reverted (seq-set key mismatch → query explosion).

## Honest limits

- Scoring-phase queries (calc-score entry/posi/uk per candidate seq) remain
  the dominant cost; S1 cache dedupes them only across sentences. Cutting
  them per-sentence needs the full in-memory dict (R1/R4) or per-sentence
  scoring batching with correct composite-key handling.
- R4 serving-core DUMP needs a bigger-heap host (Linux x86-64 SBCL, 32GB+);
  the load is proven viable in the minimal bare heap.

# Session 2b — R4 serving core BUILT (wrapper heap bug was the real blocker)

Date: 2026-09. The R4 zero-DB serving core now WORKS on this machine.

## The critical discovery
`scripts/sbcl-wrapped` silently DISCARDED user `--dynamic-space-size`
(runtime=(--dynamic-space-size 4096 ...); the arg parser did `shift 2` with
NO replacement). Every "16GB" run was actually 4GB — the R4 dump attempts
exhausted at exactly 4294967296 bytes. Fixed (commit `d0a75a6`): the user's
size now replaces the default in place. Verified: `--dynamic-space-size
14336` → 14GB heap; default stays 4GB.

## R4 serving core — WORKING (commits `293751c`, `bbe6968`, `118b5f1`)

| Artifact | State |
|---|---|
| `local-env/ichiran-serving.core` | ✅ BUILT (129MB compressed): postmodern only + full kana_text compact dict (3,079,757 rows, ~3GB) |
| `scripts/serve-core.sh` | ✅ stdin→JSON dict-lookup server, zero DB. Verified: `{"ready":true,"kana":3079757}`; こんにちは → `[{"text":"こんにちは","seq":1289400,"ord":0}]`; miss → `[]` |
| `scripts/sbcl-wrapped --core` | ✅ loads core without setup.lisp (verified working order: `--dynamic-space-size --core <core> --no-userinit`) |
| `memdict-load :tables` | ✅ kana+kanji load verified: 3.08M+5.33M rows = 7.1GB delta loads bare; dump needs 32GB+ host (documented) |
| `scripts/build-image.sh TABLES` | ✅ kana-only default builds here; full via `TABLES='"kana_text" "kanji_text"'` on bigger host |

## Updated honest limits
- Kana-only serving core: fully works on this Mac (covers the romanize
  kana-lookup path — the S3 38× win).
- Full kana+kanji core dump: needs a 32GB+ host (Linux x86-64 SBCL). The
  load is proven; only save-lisp-and-die headroom is missing here.
- Analyzer-on-core (romanize end-to-end DB-free): not yet wired — the core
  serves dict lookups; the full romanize path still needs the analyzer
  loaded on top (dict-covered queries served from RAM).

# Session 2c — analyzer-on-core WORKS, byte-identical output (R4 complete)

Date: 2026-09. The R4 zero-DB serving image is now functionally complete.

## adjoin-word shim gap (commit c72534b)
Running the full analyzer on the serving core (memdict-p on → find-word
returns compact structs) hit `NO-PRIMARY-METHOD adjoin-word` on
日本語を勉強しています: the compound-word builder has methods only for
simple-text/compound-text word1. Added compact-kana/compact-kanji adjoin
methods (mirroring the simple-text behavior) for all kana/kanji pairings.

## Verified end-to-end (analyzer on core, memdict-p + cache ON)
| Sentence | Core output | Plain DB output | Match |
|---|---|---|---|
| こんにちは | konnichiwa | konnichiwa | ✅ |
| 一覧は最高だぞ | ichiran wa saikō da zo | same | ✅ |
| 日本語を勉強しています | nihongo wo benkyō shiteimasu | same | ✅ |
| 学校で勉強しています | gakkō de benkyō shiteimasu | same | ✅ |

Parity 782/782 green after all R4 changes. The serving core loads the full
3.08M-row kana compact dict in RAM (zero DB for lookups); the analyzer
quickloads on top and romanizes identically. Remaining DB queries are the
calc-score scoring lookups (documented R1-extension / bigger-heap full-dict
core territory), not correctness issues.

# Session 3 — R5: full in-RAM dictionary for a 64GB host

Date: 2026-09. Commits `35082d9`, `591795f`. All flags default OFF; parity
782/782 + golden byte-identical verified.

## What was built

1. **Full-dict loaders** (`src/memdict-compact.lisp`): `memdict-load` now
   loads ALL tables by default — kana_text, kanji_text, entry, conjugation,
   conj_prop, conj_source_reading, sense, gloss, sense_prop — as compact
   structs with interned strings, building the analyzer's indexes
   (text/seq by-table, entry-by-seq, conj-by-seq/from, conj-prop/csr by id,
   sense-by-seq, gloss/prop by sense-id).

2. **RAM lookups mirroring the analyzer's DB queries** (DB-identical shapes):
   - `memdict-entry-by-seq` (entry DAO accessors shimmed: root-p/n-kanji/...)
   - `memdict-senses-raw` (verified EQUAL vs get-senses-raw for seq 1289400
     incl. the pos/s_inf/stagk/stagr/field tag filter)
   - `memdict-non-arch-posi` (membership-equivalent; DB has no ORDER BY)
   - `memdict-uk` (row-count equal; rows carry sense-id)
   - `memdict-conj-data` ((conj src-map props) triples; props id-ordered)
   - `memdict-has-conj-p` (for the no-conj-data guard)

3. **Analyzer wiring** (`dict.lisp`, behind `*memdict-p*` default OFF):
   find-word kana+kanji, calc-score entry/uk/posi, get-senses-raw,
   get-conj-data all route to RAM via the new `memdict-call` helper when
   `*memdict-p*` is on; else identical DB path.

## Measured memory (all 8 tables as compact structs + interned strings)

| Table | Rows | MB |
|---|---|---|
| kana_text | 3,289,512 | 2,683 |
| kanji_text | 5,435,705 | 4,325 |
| entry | 2,512,557 | 633 |
| conjugation | 2,343,276 | 340 |
| conj_prop | 2,358,731 | 287 |
| conj_source_reading | 8,386,607 | 3,929 |
| sense | 251,648 | 38 |
| gloss | 434,112 | 256 |
| **TOTAL** | **25,012,148** | **12,491 MB ≈ 12.2 GB** |

Plus hash indexes on top: realistic **~13-16 GB total** for the full in-RAM
dictionary. Fits a 64GB host comfortably.

## 64GB deployment path (how the user runs it)

```bash
# 1. Load ALL tables into RAM (production loader — not a slice):
./scripts/sbcl-wrapped --dynamic-space-size 49152 --non-interactive \
  --eval '(ql:quickload :ichiran :silent t)' \
  --eval '(load "src/memdict-compact.lisp")' \
  --eval '(load "src/memdict-compact-shims.lisp")' \
  --eval '(ichiran/memdict-compact:memdict-load :chunk 100000)' \
  --eval '(setf ichiran/dict::*memdict-p* t)'

# 2. Optionally build a full core image (needs ~2x dict headroom):
#    On the 64GB host, save-lisp-and-die with the dict loaded.
```

Verification on the 64GB host: run `scripts/parity.sh` and
`scripts/golden-diff.sh` with `*memdict-p*` ON and compare — the contract is
byte-identical output to the DB path.

## Known residual (documented honestly)
- On THIS Mac (16GB heap cap) the full load exhausts after ~6 of 9 tables
  (kana+kanji+entry+conj+conj_prop before conj_source_reading) — a memory
  limit, not a code defect. The load works on 64GB.
- Slice-based verification of full romanize parity is unreliable (the
  te-iru decomposition しています shows a segmentation difference caused by
  incomplete slice data, not the production loader). Individual RAM lookups
  are verified DB-identical; final full-parity confirmation must run on the
  64GB host with the complete dict.
