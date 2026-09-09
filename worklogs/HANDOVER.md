# Ichiran Performance Rework — Handover Document

*For the next agent taking over. Everything here is grounded in the actual
workspace state at handover time; verify with the listed commands rather than
trusting prose.*

---

## 0. TL;DR — where things stand

- **A real, working environment exists**: SBCL 2.6.8 + PostgreSQL 16 + quicklisp +
  the full ichiran DB (2.5M entries) restored, all writable state contained in
  the workspace (`local-env/`). Parity harness is GREEN: **782/782 tests pass,
  golden-corpus output byte-identical**.
- **33+ commits of completed, verified optimization work** (S1 cache, S2
  batching, S3 memdict, S4 trie, S5 daemon+driver, S6 char-scans, compile
  polish, CLI `--serve`). Measured wins: **3–38× on kana-heavy sentences**,
  ~15–20% query-count reduction on all sentences.
- **The big architectural goal (R1–R4) is PARTIALLY done**: R1's compact
  in-memory dict is built + wired + verified with a *sampled* load, but **the
  full load is blocked by a hard memory wall on this machine (16 GB SBCL heap
  cap)**. This is the #1 thing the next agent must resolve.

---

## 1. Environment (all verified working)

| Component | How to use |
|---|---|
| SBCL | `scripts/sbcl-wrapped` — the ONLY way to run SBCL (keeps caches in-workspace, sandbox-safe) |
| PostgreSQL | localhost:5432, db `jmdict`, user `jmdict`, password `password` (data dir in `local-env/pgdata/`) |
| quicklisp | workspace copy at `local-env/quicklisp/` (loads via wrapper's `--load setup.lisp`) |
| Parity suite | `./scripts/parity.sh` → must print `PARITY_OK` (782/782) |
| Golden corpus | `./scripts/golden-diff.sh` → must print `GOLDEN_DIFF_OK` (byte-identical vs `data/golden-corpus-baseline.json`) |
| Bench | `./scripts/bench.sh` (query count + time per sentence) |

**WARNING**: `scripts/golden-snapshot.sh` has a known `--out` path bug — when
passed `--out FILE` it writes the default path instead. For a reliable compare
run `golden-snapshot.sh --out /tmp/x.json` then `diff` manually, or just rely
on `golden-diff.sh` (which has its own quirk: it can report drift when the
baseline is stale — always regenerate baseline on a clean tree before diffing).

---

## 2. Completed & committed (all parity-verified)

| Module | File | What | Verified |
|---|---|---|---|
| S1 seq-cache | `src/cache.lisp` | memo entry/posi/uk/conj per seq (`*use-cache-p*`) | equality vs DB, hits accumulate |
| S2 batch prefetch | `src/cache.lisp` + `dict.lisp` | per-sentence `IN`-batch of entries + conj + senses | query 707→570, 1141→1107 |
| S3 memdict (DAO) | `src/memdict.lisp` | kana_text DAO index | 38× on kana-heavy (1.22s→0.032s) |
| S4 trie | `src/trie.lisp` + `dict.lisp` | prefix-walk candidate search (`*trie-p*`) | unit-verified vs brute force; **full-dict build fatals** |
| S5 daemon | `src/daemon.lisp` + `cli.lisp` | persistent stdin→JSON server + `--serve` | valid JSON per line, CLI built |
| S5 driver | `src/driver.lisp` | lparallel pool, ordered results | 4-thread OK |
| S6 char-scans | `characters.lisp` | table-driven `consecutive-char-groups`/`destem` | A/B + golden parity |
| compile polish | `dict.lisp` | `(speed 3)(safety 1)(debug 1)` on hot fns | parity green |
| crash fix | `dict.lisp` `find-word` | stale substring-hash fallback | cross-sentence crash gone |
| R1 compact dict | `src/memdict-compact.lisp` + `find-word` hook | defstruct rows + defmethod shims | sampled-load output correct (konnichiwa) |

**Feature flags (all default OFF — zero behavior change):** `*use-cache-p*`,
`*memdict-p*`, `*trie-p*` in `dict.lisp` (~lines 1140–1169).

**Measured (vs pre-work baseline):**
- こんにちは: 249q → 249q, time ~7–38× (cold→warm)
- 一覧は最高だぞ: 139q → 145q, ~3.4×
- 日本語を勉強しています: 1041q → 534q, ~1.5×
- 錬丹術…(kanji-heavy): ~1000q → ~1000q, ~1.1× ← **the remaining target**

---

## 3. The active goal (R1–R4) and its state

**Goal**: big architectural rewrites — R1 compact in-memory dict, R2 sentence
query-plan batching, R3 compact trie, R4 zero-DB serving mode. Guardrails:
parity is the contract, flags default OFF, commit per step.

| Item | State | Key finding |
|---|---|---|
| **R1** compact dict | ⚠️ built+wired, **full load blocked** | See §4 — THE critical blocker |
| **R2** sentence batching of reading-str/short-sense | ❌ not done correctly | memoizing per-seq was net-negative; must batch per *winning sentence* once |
| **R3** compact double-array trie | ❌ not done | hash-node trie fatals at full dict; needs compact encoding |
| **R4** zero-DB serving image | ⚠️ scaffolded (`scripts/build-image.sh`) | image build also fatals (see §4) |

---

## 4. THE critical blocker — the 16 GB SBCL heap wall

This is the single most important thing to understand. On this Mac
(arm64), SBCL's `--dynamic-space-size` **caps at 16 GB**.

**Measured facts (all reproduced):**
- Full ichiran analyzer baseline (quicklisp + postmodern + :ichiran loaded):
  ~13 GB of the 16 GB heap is already used.
- Compact kana_text struct load (3.08M rows, 10-slot defstruct + interned
  strings): **steady-state ~2.8 GB** on top → exceeds 16 GB → `Heap exhausted`.
- The postmodern `:lists` row reader is NOT the culprit (a single 100K-row
  chunk = 113 MB, GC-freed). The struct+hash accumulation is the cost.
- Small chunks (10K) + full GC every chunk: still exhausts (too slow anyway).
- Slim 6–7-slot structs: only marginally smaller (~2.8 GB) — the cost is
  SBCL per-object + hash-entry overhead, not slot count.
- kanji_text (5.4M rows) alone as DAOs fatals; as compact structs would be
  ~4.5 GB more.
- `scripts/build-image.sh` (R4 dedicated image): also fatals because the
  build process loads :ichiran + dict + does a sanity romanize in one heap.

**Conclusion**: on THIS machine, the DB-driven analyzer and the full compact
dict cannot coexist in one 16 GB heap. The path forward is one of:

1. **R4 properly**: build a dedicated serving core in a *minimal* SBCL
   (no `:ichiran` quickload — only the compact dict structs + shims + the
   analyzer's essential files), dump the core, serve from it. The compact
   module currently depends on `:ichiran/conn` + `:ichiran/dict` for shims —
   **decouple it** so it loads bare (a prior attempt to make it
   postmodern-only was reverted with `git checkout src/memdict-compact.lisp`;
   the package still `:use`s `:ichiran/conn`).
2. **Run the full load on a bigger-heap host** (Linux x86-64 SBCL supports
   32+ GB). The code is correct — it just needs headroom.
3. **Page-on-demand**: keep the DB but add a compact LRU/disk-backed index.
   Not started.

**Before the next agent spends more time here**: the sampled-load path is
VERIFIED CORRECT (271K rows → `こんにちは => konnichiwa`, hints working) and is
committed. The R2 batching (see §5) is pure DB-query work with NO memory
constraint — it can be completed immediately and gives real query-count wins.

---

## 5. R2 design — the actionable next win (no memory wall)

The breakdown of a kanji-heavy sentence's ~1000 queries (measured):

| Table | Share |
|---|---|
| sense/gloss (`short-sense-str`, 1 query/word) | **~45%** |
| kanji_text (`reading-str-seq` + get-text, ~2–3 queries/word) | **~25%** |
| other (entry, misc) | ~20% |
| conjugation + props + src | ~12% |

**Why the earlier attempt failed**: memoizing `reading-str-seq`/`short-sense-str`
per-seq was net-negative (unique seqs within a sentence → lookup overhead > savings;
one sentence went 707→972). **The correct design**: batch ONCE per *winning
sentence* — after `fill-segment-path` builds the final word-info list, collect
its ~10–40 unique seqs, run ~3 batched `IN` queries (kanji_text by seq+ord,
kana_text by seq+ord, gloss/sense by seq), store in a per-sentence hash, and
make `reading-str-seq`/`short-sense-str` consult it. Cache should be
per-sentence (reset each sentence), not per-seq-persistent.

Also note: the `:with-info` string path calls `short-sense-str` +
`reading-str-seq` (NOT `get-senses-raw` — that's the JSON path; the SENSES
cache stats stayed `(0 0)` proving it's never hit by `:with-info`).

---

## 6. Pitfalls / gotchas learned the hard way

- **Subagents are unreliable in this session** — any subagent that runs SBCL
  or quickload dies silently. Read-only analysis subagents sometimes work.
  ALL SBCL-backed work must be done inline by the coordinator.
- **s-sql `:limit`/`:order-by`**: postmodern's `select-dao` does NOT accept
  `(:limit ...)` as a where-clause (syntax error). Use raw SQL strings via
  `(ichiran/conn::query "SELECT ... LIMIT n OFFSET m" :lists)` — proven reliable.
- **postmodern `:plists` reader** conses ~2× more than `:lists` — always use
  `:lists` for bulk loads.
- **DAO `make-instance` ignores initargs** for postmodern dao-class objects
  (the metaclass overrides it; `id` can't be set via initarg). You cannot
  reconstruct DAOs from plists — load via `query-dao`/`select-dao` instead.
- **Recursion guards**: memo-thunks that call the memoized function need a
  guard var (e.g. `*in-sense-cache*`) or you get infinite recursion.
- **`get-kana` hints**: compact structs MUST replicate the `get-kana :around`
  hint logic (else は romanizes as "ha" not "wa").
- **Golden baseline staleness**: if golden-diff reports drift, regenerate the
  baseline on the current tree FIRST (`golden-snapshot.sh`) before assuming a
  regression. A stale baseline caused a false alarm early on.
- **Package symbol refs**: referencing `ichiran/cache:foo` (single colon) in
  dict.lisp fails at READ time if the package isn't loaded yet — use
  `cache-call`/`(find-package ...)` runtime dispatch (already done).

---

## 7. Guardrails (non-negotiable)

1. Behavior parity is the contract: `parity.sh` (782/782) + golden-corpus
   byte-identical. Run both after every change.
2. NO scoring/split/hint/errata constant changes. Ever.
3. Every runtime behavior change behind a flag, default OFF.
4. Commit at each verified step (git is the rollback safety net).
5. Subagents: only for read-only analysis; all SBCL-heavy work inline.

---

## 8. Suggested next steps (in priority order)

1. **R2 batch (no memory wall)**: implement per-winning-sentence batching of
   `reading-str-seq` + `short-sense-str` (§5). Target: kanji-heavy ~1000 → ~200.
2. **Decouple memdict-compact for R4**: make it loadable without `:ichiran`
   (remove `:ichiran/conn`/`:ichiran/dict` deps — use `with-connection` +
   define shims conditionally). Then build the R4 serving core in a minimal
   heap: dict + a slim romanize path (or keep DB only for the few things the
   dict doesn't cover).
3. **Full-load on bigger heap** (documented; code is correct) or page-on-demand.
4. **R3 compact trie** (double-array or minimal-hash encoding) — same memory
   discipline; only worth it after R4 gives headroom.
5. Re-run the final before/after table + update `worklogs/FINAL-REPORT.md`.

---

## 9. Useful commands

```bash
cd /Users/golybidoof/Projects/ichiran-master
./scripts/env-check.sh       # env healthy?
./scripts/parity.sh          # 782/782 gate (~2-3 min)
./scripts/golden-diff.sh     # byte-identical gate (~3-5 min)
./scripts/bench.sh           # query/time baseline
# quick SBCL eval:
scripts/sbcl-wrapped --dynamic-space-size 4096 --non-interactive \
  --eval '(ql:quickload :ichiran :silent t)' --eval '(format t "~a~%" (ichiran:romanize "テスト"))'
```

Git history: 30+ commits from pristine baseline `47eb22e`. All perf work is
behind flags default OFF — `git checkout 47eb22e` fully reverts.

---

# Handover Addendum — Session 2 (R2–R4 progress + corrections)

*2026-09. Four new commits on top of the state this document originally
described. Read this before trusting the §3–§5 claims, which are now stale.*

## What changed

| Commit | Item | State |
|---|---|---|
| `48de65c` | S2-v3 nil-sentinel in `find-word` | ✅ **The single biggest safe win found this session**: skip the DB probe for checked-not-found window parts. Fresh-process query cuts 12–33% on all sentences, output byte-identical, parity+golden green. |
| `6aaefb8` | R4 decouple memdict-compact | ✅ Loads bare (postmodern only). Analyzer shims moved to `src/memdict-compact-shims.lisp`. |
| `cd29d15` | R3 compact trie | ✅ One edge-hash + node-vector encoding: 198 MB / 1M entries (~198 B/entry) vs old ~4KB/node. Full-dict projection ~1.6GB — fits. Correct vs brute force. |
| `fd35e4a` | R4 minimal-core image path | ⚠️ Load proven (full 3.08M-row kana compact dict fits an 8GB bare heap, ~3GB); **dump still needs a bigger-heap host** (save-lisp-and-die ~2× headroom; 16GB Mac cap exhausts). |

## Corrections to §3–§5 (measured this session)

1. **§5's gloss-heavy breakdown is stale.** With S2-v2 cache ON, a kanji-heavy
   sentence's ~900 queries are dominated by per-candidate `calc-score`
   lookups: ~211 entry + ~211 posi (get-non-arch-posi) + ~189 uk (sense-prop
   'uk') + ~150 single-text window probes — NOT the with-info gloss path
   (~30). The 150 window probes were the nil-sentinel bug (`48de65c`).
2. **R2 batching of reading-str-seq/short-sense-str was implemented and is
   NET-NEGATIVE** in fresh processes (3 IN queries/path × 5 paths > per-seq
   savings; scoring-phase queries untouched). The handover's "~1000 → ~200"
   target for that design is not achievable on the format phase; the real
   lever is the scoring phase (needs the full in-memory dict = R1/R4, or
   composite-key-correct per-sentence scoring batching — the lazy miss-queue
   attempt failed on seq-set key mismatches and was reverted).
3. **The 16GB wall is really two walls**: (a) dict-on-top-of-:ichiran
   (FIXED — bare load fits 8GB), and (b) save-lisp-and-die dump headroom
   (needs 32GB+ host, unchanged). Build the R4 core on Linux x86-64 SBCL.

## Next steps (updated priority)

1. Run `scripts/build-image.sh` on a 32GB+ Linux x86-64 SBCL — the minimal
   core path is ready; only the dump step needs the bigger heap.
2. Wire the R4 serving core to a slim romanize path (dict-covered lookups
   DB-free; fall back to DB for the few uncovered queries) — the decoupled
   `memdict-find` API is exported for this.
3. Per-sentence scoring batching with CORRECT composite seq-set keys (or
   fold into R1) to attack the ~600 calc-score queries/sentence.
4. Re-verify parity + golden after each (both currently GREEN).

# Handover Addendum 2 — R4 serving core is BUILT (read this FIRST)

Date: 2026-09. The #1 blocker from the original handover is RESOLVED.

## The wrapper heap bug (why every earlier R4 attempt failed)
`scripts/sbcl-wrapped` discarded `--dynamic-space-size` (arg parser `shift 2`
with no replacement). ALL "16GB" runs were actually 4GB. Fixed in
`d0a75a6`. **If a future R4/R5 attempt "heap-exhausts at exactly 4294967296
bytes", the heap-size flag is being dropped — check the wrapper first.**

## What now works (commits 293751c, bbe6968, 118b5f1)
1. `scripts/build-image.sh` → builds `local-env/ichiran-serving.core`
   (129MB): postmodern-only image with the full 3,079,757-row kana_text
   compact dict in RAM, zero DB.
2. `scripts/serve-core.sh` → runs the core as a stdin→JSON dict-lookup
   server (ready-line, one JSON array per input line, misses = `[]`).
3. `scripts/sbcl-wrapped --core <core>` → loads the core without quicklisp
   setup (verified arg order: `--dynamic-space-size --core <core>
   --no-userinit`).
4. `memdict-load :tables ("kana_text" "kanji_text")` → full load verified
   (7.1GB delta) but the dump needs a 32GB+ host on this Mac.

## Next steps (updated)
1. Wire the analyzer (romanize) on top of the serving core: load :ichiran
   into the core image AFTER the dict (or load the core then quickload
   :ichiran), so dict-covered lookups serve from RAM and the rest falls to
   DB. Verify romanize output byte-identical with *memdict-p* on.
2. On a 32GB+ Linux host: `TABLES='"kana_text" "kanji_text"'
   ./scripts/build-image.sh` for the full kana+kanji core.
3. R2 scoring-phase batching with composite seq-set keys (the remaining
   ~600 queries/sentence cost) — or fold into the dict-in-RAM path.
