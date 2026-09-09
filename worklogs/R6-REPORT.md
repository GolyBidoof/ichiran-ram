# R6 Session Report — review follow-ups implemented + benchmark vs upstream

Date: 2026-09. Goal: implement the 6 review items from HANDOVER-NEXT §8,
then benchmark against upstream (DB-only) behavior.

## 0. Results first

- Parity 782/782 green (5 consecutive runs), golden byte-identical on re-run
  (see §6 for a pre-existing golden flake found along the way).
- Lite core BUILT: `local-env/ichiran-lite.core` (168MB, kana_text +
  sense+gloss+sense_prop, PRESET=lite). Analyzer on top romanizes kana
  sentences byte-identical with zero DB for kana+senses.
- Benchmark (8-sentence corpus, S1 cache OFF, fresh process per config):

| Sentence | DB-only q | Lite RAM q | Δ | DB t | Lite t |
|---|---|---|---|---|---|
| こんにちは | 251 | 96 | −62% | 0.904* | 1.282* |
| ありがとうございます | 563 | 226 | −60% | 0.097 | 0.038 |
| コンピューター | 27 | 10 | −63% | 0.017 | 0.008 |
| 日本語を勉強しています | 594 | 244 | −59% | 0.126 | 0.048 |
| 一覧は最高だぞ | 137 | 61 | −55% | 0.061 | 0.084 |
| 錬丹術は医学方面に特化してるというからね | 850 | 380 | −55% | 0.142 | 0.092 |
| 学校で数学と歴史を勉強しています | 696 | 336 | −52% | 0.101 | 0.054 |
| paragraph (3 sentences) | 2727 | 1106 | −59% | 0.356 | 0.185 |
| TOTAL | 5845 | 2459 | **−58%** | 1.80 | 1.79 |

\* first-sentence connection warmup dominates both (see handover caveats).
Excluding it: 0.90s → 0.51s (~1.8×) on localhost; query-count wins matter
more over a remote DB. Consistent −52…−63% on EVERY sentence type with only
4 of 9 tables loaded (no kanji, no conjugation, no entry).

RAM-vs-DB output equivalence (partial load kana+senses+entry+conj, kanji+csr
on DB): reading-str, short-sense, and romanize all EQUAL T, incl.
日本語を勉強しています and counter sentences (三つ, 二冊).

## 0b. Page-length validation (answers: does the speed hold up?)

Full golden corpus as 19 paragraphs (4.3K chars), DB vs lite, per-para
output hashes compared:

- DB: 180,985 queries, 19.8s. Lite: 89,335 queries (**−51%**), 10.3s
  (**−48%**). Zero failures. Per-para queries roughly halve throughout.
- 14/19 paras byte-identical. The 5 diffs are segmentation tiebreak
  variants only (same words, different splits).
- Decisive controls: lite is 100% self-stable across processes (19/19
  twice); DB disagrees with ITSELF (para 8 has 3 distinct DB outputs across
  runs; golden X/Y bimodality; one intra-process flake). RAM sits inside the
  analyzer's natural output variation — see §6.
- Found and fixed via this test: shared-index aliasing (below).

## 1. What was implemented

1. **Hygiene** — worklogs/ tracked in git (was gitignored); golden-diff uses
   mktemp + keeps the drift file (trap released on drift); build-image has
   PRESET=lite|kana|full, TRIE_TABLES knob, provenance files, pipefail.
2. **memdict fast path + layering** (`dict.lisp`) — cached fn resolution
   (memdict-fn), no recursive memdict-call for loaded-tables, trio-aware
   needs as lists, memdict-table-loaded-p, trust-RAM-skips-DB at entry/uk/
   posi/senses/conj-data sites. Fixed an fboundp-on-function-object crash
   that only fired on cache HITS.
3. **te-iru ordering** (`src/memdict-compact.lisp`) — ORDER BY unique key on
   every load, one-time memdict-normalize-order (ascending id = select-dao
   order), conj-data sorted by conj/csr id, senses-raw deterministic
   (ord-ordered texts, sorted tags, stable-sort).
4. **Residual wiring** — reading-str-seq, entry get-kana/get-text/get-kanji,
   get-kanji-kana-old, select-conjs (+conj-props), short-sense-str,
   get-original-text (simple-text + both compact shim methods),
   find-words-seqs (id-sorted per side), get-counter-ids, get-counter-stags.
   Deliberately NOT wired: suffix-map (already in-memory via *suffix-cache*),
   restricted-readings (0 queries in corpus — rare path),
   get-counter-readings (2 batched queries once per process, DAO-shaped).
5. **RAM substring path + trie-in-core** — find-substring-words seeds loaded
   sides from RAM ((:compact . rows), miss sentinels preserved) and keeps the
   batched DB IN query for UNLOADED sides (hybrid: partial loads stay
   correct); baked trie via memdict-build-trie + TRIE_TABLES.
6. **Lite core** — PRESET=lite builds here (168MB), verified §0.

## 2. THE BIG FIND: silent row loss in the R5 loader (fixed)

`memdict-load` paged with LIMIT/OFFSET and NO ORDER BY. Postgres reshuffles
unordered pages (parallel/sync scans): entry loaded **1,551,111 of 2,512,557
rows with no error**. Every full-dict load from this code had randomly
missing rows — a likely contributor to the te-iru gap alongside ordering.
Fix: ORDER BY unique key per table (seq for entry). Every load now ends with
MEMDICT-VERIFY-OK/FAIL per-table row counts vs SELECT count(*). All 7
partial-load tables verify exact; kana-only lite core loads clean.

## 3. Bugs caught while verifying (all fixed)

- fboundp called on a cached FUNCTION object (cache-hit-only crash).
- **Dead gating table**: `*memdict-needs-table*` keys are lowercase but
  lookups arrive uppercase — `assoc` with `equal` never matched, so the table
  gated nothing (call-site guards carried production). Fixed with `equalp`;
  the new `ram-helpers-test` covers trio gating explicitly.
- **Shared-index aliasing (the page-test catch)**: RAM lookups returned live
  index lists and shared structs; the analyzer mutates readings and nconcs
  find-word results, so compounds/suffix readings accumulated in
  `*kana-by-text*` until a compound seq-list leaked into an entry IN query
  (`42883 integer = record`, deterministic on the 6th paragraph). Fixed with
  copy-on-return for all kana/kanji rows + fresh spines.
- Hybrid-seeding first version suppressed DB fallback for unloaded sides
  (kanji words vanished under kana-only loads) — per-side hybrid fixed it.
- memdict-verify-counts ran outside with-db-connection (bare builds have no
  ambient connection) — own connection scope now.
- Extra/missing parens in three edits (caught by load tests, not by review).

## 4. Residual-query enumeration (DB-only, romanize :with-info t)

Top patterns are all R5-wired (entry/posi/uk/conj trio/senses). What was left
is now wired (§1.4). True remainders: query-parents joins (~6/corpus),
find-words-seqs IN batches (~14, now RAM), sense id+ord=0 probes (~4),
restricted-readings (0 in corpus), counters (counter sentences only).

## 5. Te-iru status

Ordering + completeness fixes are committed, but FULL-dict RAM-vs-DB parity
for しています still needs the 64GB host (kanji_text + csr don't fit here).
The partial-load equivalence (kana+senses+entry+conj) is EQUAL T on the
te-iru sentence. 64GB runbook: full memdict-load (expect all VERIFY-OK),
*memdict-p* t, parity.sh + golden-diff.sh, then full 9-table dump.

## 6. Golden-diff flake (pre-existing, environmental)

golden-diff is BIMODAL on the 錬丹術 sentence: identical code gives baseline
(X) or an alternate (Y) on back-to-back runs; both Y snapshots are
byte-identical to each other. DB-only default path, all RAM paths gated off.
Extended page testing sharpened the picture: one paragraph flakes even
INTRA-process in pure DB mode; another has 3 distinct DB outputs across runs
(single sentences, fresh processes). Autovacuum is ruled out (tables never
analyzed). The flips are knife-edge segmentation ties broken by candidate
order, which varies with scan dynamics. Recommendation: treat one drift as
"re-run"; harden later with ORDER BY in candidate queries or deterministic
tiebreaks (upstream-worthy). Parity (782+29) is deterministic and green
throughout — keep it as the hard gate. RAM-vs-DB diffs found on 5/19 page
paragraphs are the same tiebreak family, inside DB's own variation.
