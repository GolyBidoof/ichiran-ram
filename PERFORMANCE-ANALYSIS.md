# Ichiran Performance Analysis

*How to make the classic PostgreSQL-backed Ichiran tokenizer fast — with honest verdicts on
MPS/CUDA, multi-core/threading, and "faster interpretation", grounded in this codebase
(dict.lisp / dict-split.lisp / dict-grammar.lisp / conn.lisp) and in upstream issue data.*

Analysis date: 2026-09. Repo under analysis: this snapshot of `tshatrov/ichiran` (no git
metadata present; upstream master at the time of writing had **not** merged any performance
work — recent commits are linguistic fixes only).

---

## TL;DR

| Technique | Verdict | Realistic win (batch) | Effort | Where it lands |
|---|---|---|---|---|
| 1. Remove DB from the hot path (in-memory dict / batched + prepared queries) | **The big one** | **10–100×** | Medium–High | `dict.lisp:489-518, 777-983`, `dict-grammar.lisp:695` |
| 2. Algorithmic: trie/DAWG prefix search instead of O(N²) substring probes | Strong 2nd | 2–5× CPU *after* #1 | High | `dict.lisp:501-518, 1071-1112` |
| 3. SBCL compile policy + allocation/GC diet (56–77 MB consed *per short parse*) | Cheap, real | 1.5–3× | Low | `dict.lisp:777` decls, whole-file policies |
| 4. Multi-core: in-process thread pool over sentences (lparallel — already a dep) | Good, proven | ~cores (≈8–10× at 8 cores) | Low–Med | new driver module; `tests.lisp:670` shows the pattern |
| 5. CUDA / MPS / GPU of any kind | **Not applicable** to this algorithm | ~0 | — | see §5 |
| 6. Hybrid: hand off to a fast lattice tokenizer (Sudachi.rs/MeCab-class), keep Ichiran only for glosses | Best absolute throughput | 100–1000× | Med (integration) | external tooling |

Order of attack: **#1 → #3 → #4** for latency/throughput now; **#2** when you own the fork
long-term; treat #5 as a trap; consider #6 only if your goal is "millions of sentences", not
"interactive sentences".

---

## 1. What a single parse actually does (and what it costs)

The public path is `romanize`/`dict-segment` → `join-substring-words` → `find-best-path` →
`fill-segment-path`, all inside one PostgreSQL connection (`dict.lisp:1450-1456`). Per word:
`find-word-full` → `calc-score` (`gen-score`), and the scoring function is the runaway.

**Measured anchors (maintainer & users, upstream issues):**

- `(time (romanize "一覧は最高だぞ"))` ≈ **0.12–0.41 s real time**, **56–77 MB consed per
  parse**, and **15–73 % CPU** (the low end is the tell: wall-clock waiting on I/O, not
  computing).  ([#62](https://github.com/tshatrov/ichiran/issues/62))
- One user analyzed 1M sentences via per-line CLI in ~3 days ≈ 3.9 lines/s; another reported
  **~41 lines/s with an 8-thread in-process pool**; `with-info` gloss lookups ≈ 4× slower than
  bare segmentation. ([#17](https://github.com/tshatrov/ichiran/issues/17))
- Maintainer: "the main algorithm is quadratic wrt the length of the sentence" for
  unsegmented runs, "designed for interactive usage," and "Ichiran is thread-safe so the
  fastest approach would be native multithreading in Lisp." ([#17](https://github.com/tshatrov/ichiran/issues/17))
- Users independently reproducing "10 s for one long sentence" had it vanish on a **fresh
  clone** — i.e. a stale build/cache artifact, not the algorithm. Clean-rebuild hygiene is a
  real (if boring) fix. ([#62](https://github.com/tshatrov/ichiran/issues/62))

**Where the time goes, in code order:**

1. **DB round-trips per candidate word — the dominant cost.** Every candidate word that
   survives into a segment is scored by `calc-score` (`dict.lisp:777-983`), and scoring is
   not CPU work, it is ~3+ SQL queries minimum, more with conjugations:
   - `(get-dao 'entry seq)` — row fetch per candidate (`dict.lisp:803`)
   - `select-dao 'sense-prop ... "uk"` — per candidate (`dict.lisp:822-824`)
   - `get-non-arch-posi` — **a full query per candidate** (`dict.lisp:826-827`, `762-773`)
   - `word-conj-data` → `get-conj-data` → `select-dao 'conjugation` **plus** a
     `conj-source-reading` query and a `conj-prop` select **per conjugation row**
     (`dict.lisp:342-369`)
   - a conditional `query` for kanji `prefer-kana` ordering (`dict.lisp:884-887`)
   - then split/suffix branches (`get-split`, `get-segsplit`) recurse into more `calc-score`
     and more `find-word-*` → more queries.
   A 40–60 character unsegmented Japanese run can produce **hundreds of scored candidates**,
   i.e. **hundreds to thousands of SQL round-trips per sentence** at ~0.05–1 ms each over a
   socket. That is your seconds. It also explains low CPU% (process parked on the socket) and
   why the parse time blows up super-linearly with length.
2. **O(N²) substring enumeration.** `join-substring-words*` (`dict.lisp:1071-1111`) probes
   every `(start, end)` window (capped at `*max-word-length*` 50, minus sticky points) and
   `find-substring-words` (`dict.lisp:501-518`) materializes **all** distinct substrings into
   a hash table and one big `IN` query per table. That part is already batched well; the N²
   cost is the probe *count* and the downstream `find-word-full`/suffix fan-out per window.
3. **Allocation/GC.** 56–77 MB consed for a 7-character sentence is the real budget: CLOS
   instances per word (`word-info`, `segment`, proxies, compounds), list-building in every
   scoring branch, `format`/`concatenate` strings, `intersection`/`remove-duplicates` on
   plists all over `calc-score`. SBCL's `time` prints "N lambdas converted" (302–606 in the
   maintainer run) — some code paths execute through the on-the-fly compiler; precompiled
   fasls and a `(speed 3)` build remove that tax. Note the conflicting
   `(optimize (speed 3) (debug 3) (safety 1))` on `calc-score` (`dict.lisp:778`): debug 3
   tells SBCL to keep full debugging info and inhibit most optimizations — an easy win to fix.
4. **Rule fan-out.** `find-best-path` (`dict.lisp:1190-1233`) itself is a sane top-5 beam over
   the lattice — fine. But `expand-segment-list`/`get-seg-splits`/`get-seg-initial`
   (`dict.lisp:1171-1188`) run every seg-split rule, and pair-wise **~21 synergies, 5
   penalties, ~20 seg-filters** (`dict-grammar.lisp` rule lists) run per adjacent pair of
   segment-lists; every synergy/penalty does more `intersection`s over POS/seq plists per
   segment. After #1–#3 this becomes the next CPU hotspot — the rule lists are pure lists and
   could be compiled into a decision table, but that is polish, not the headline.

The suffix machinery (`get-suffix-map`, `find-word-suffix`, `dict-grammar.lisp:671-707`) runs
per sentence and per candidate; the `*suffix-cache*` hash lookups are cheap, but each
**matched suffix class re-enters `find-word-with-conj-type/prop` → `find-word-full`**, i.e.
more dictionary probes and more conjugation queries, recursively.

---

## 2. Front #1 — kill the DB from the hot path (the real fix)

This workload is **latency-bound on PostgreSQL round-trips**, not compute-bound. GPU and even
threads are multipliers on the wrong axis until this is fixed.

**Recommended design (behavior-preserving):**

- **A. Memoize per `seq`.** `get-conj-data`, `calc-score`'s POS/`uk`/entry lookups are keyed
  by a handful of integers. A `defcache` (the framework already exists in `conn.lisp:96-149`)
  or a plain hash keyed by `(seq conj-texts...)` turns thousands of queries into one-time
  loads. This is a *pure* win with zero behavior change and the cheapest first step: add
  `defcache` entries and swap `select-dao`/`get-dao` call sites in `calc-score` and
  `get-conj-data`.
- **B. Batch per sentence.** `join-substring-words` already knows the full set of distinct
  surface texts and the full set of matched `seq`s before scoring. Hoist the per-word
  `sense-prop` (POS / "uk"), `entry`, and `conj-*` reads out of `calc-score` into 2–3
  sentence-level `IN (...)` queries (`find-substring-words`, `dict.lisp:516-517`, is the
  template), then serve `calc-score` from local hashes. Converts N×queries → O(1) per parse.
- **C. In-memory dictionary (the endgame, and what the community keeps asking for).** At
  process start, slurp the hot tables (`entry`, `kanji_text`, `kana_text`, `conjugation`,
  `conj_prop`, `conj_source_reading`, and for glossing `sense`/`sense_prop`/`gloss`) into
  SBCL hash tables — on the order of a few hundred MB for JMdict-sized data, well within a
  server/desktop budget, trivial for a docker image with `--dynamic-space-size`. Then
  `find-word` is a hash hit (`dict.lisp:489-499` already has a `*substring-hash*` fast path to
  generalize), scoring is pure CPU, and **per-sentence latency drops to the millisecond
  range**. PostgreSQL stays as the *source of truth* for errata/dictionary updates and for
  one-shot lookups like gloss text; the analyzer never touches it per parse. This mirrors the
  architecture of every fast Japanese analyzer (MeCab/Sudachi ship mmap'd dictionaries) and of
  ichi.moe's long-lived server process.
  - Fallback that keeps the DB: **prepared statements everywhere** (`postmodern` supports
    prepared queries; `defprepared` is already used at `dict.lisp:404-428`) and keep one
    warm connection per thread; make sure the Postgres `text` indexes (`dict.lisp:104,146`)
    are actually used (`EXPLAIN ANALYZE`).

**Expected result:** the measured 0.1–0.4 s/short-sentence with 15–73 % CPU becomes
single-digit ms and near-100 % CPU — a 10–100× swing, all behavior identical.

---

## 3. Front #2 — algorithmic: stop enumerating N² substrings

Once the DB is out of the loop the CPU cost of probing every `(start,end)` window
(`dict.lisp:1071-1112`) reappears. The standard fix (and what MeCab-class analyzers do;
[community suggestion in #17](https://github.com/tshatrov/ichiran/issues/17)):

- Build a **prefix trie / double-array trie / FST over dictionary surface texts** (both
  kana and kanji readings, plus the suffix stems). At each position you walk the trie and only
  extend while characters still match a dictionary prefix — O(dictionary-prefix matches ×
  depth) instead of O(N²) string probes. Lattice generation becomes linear-ish, and the
  existing Viterbi/beam (`find-best-path`, `dict.lisp:1190`) is already the right shape.
- Replace the **regex scans** used for character classification and run detection
  (`characters.lisp`: `find-sticky-positions`, `consecutive-char-groups`, `kanji-prefix`,
  `destem`, plus `test-word`) with direct per-code-point table lookups; `get-char-class`
  (`characters.lisp:165+`) already has the table. Regex engines (CL-PPCRE) are convenient but
  10–100× slower than a `gethash` per char on the hot loops.
- `match-diff` (`characters.lisp:326-357`) is exponential-ish and runs per reading mismatch —
  memoize or bound it.

**Expected result:** 2–5× on top of front #1 for long unsegmented strings, and removal of the
quadratic wall on long sentences.

---

## 4. Front #3 — SBCL "faster interpretation", allocation, and build hygiene

Cheap, safe, immediate (and answers the "faster interpretation methods" part of the brief):

- **Compile policy.** `calc-score` declares `(speed 3) (debug 3)` (`dict.lisp:778`): debug 3
  disables the very optimizations speed 3 requests. Build the shipped image with a global
  `(declaim (optimize (speed 3) (safety 1) (debug 1) (space 1)))` (the docker
  `init-sbcl`/`init-cli` scripts `ql:quickload` at build time, so the `.core` is compiled —
  but the conflicting per-function policy still applies). Rebuild fasls and the core image
  from scratch after upgrades (see the "#62 fresh clone fixed it" effect).
- **Type declarations on the hot scalar path.** `calc-score` and `find-best-path` are mostly
  fixnum/string work; declare types so SBCL emits fixnum arithmetic, and mark
  `length-multiplier-coeff`-style helpers `inline` (partly done at `dict.lisp:692-700`).
- **Allocation diet.** 56–77 MB per 7-char parse is dominated by per-candidate CLOS
  instances and plist churn. The code already reuses displaced array *slices*
  (`subseq-slice`, `dict.lisp:1013-1018`) — extend that habit: reuse `segment`/`word-info`
  objects where safe, avoid `format`-based string building in scoring (it happens inside
  `get-senses-*` per word when `:with-info t`, which users measured ≈4× slower), and keep
  `remove-duplicates`/`intersection` calls off long cons chains.
- **GC/runtime.** Give SBCL headroom (`--dynamic-space-size 16384+`) and consider
  `(sb-ext:gc :gen 7)`-style tuning in a server loop; generation GC settings matter when each
  parse conses tens of MB.
- **Measure first, then profile.** `(time ...)` per sentence; **`sb-sprof`** for CPU;
  **`cl-postgres:*query-log*`** (there is already a `with-log` helper in `conn.lisp:89-93`)
  to count queries per parse — the single most diagnostic number you can print.

---

## 5. Front #4 — multi-core / multi-threading

Facts from the code and the community:

- Ichiran is **thread-safe by design**: caches are guarded (`conn.lisp:96-149`,
  `dict-grammar.lisp:163-170`), and the test suite has a parallel harness
  (`tests.lisp:670-677`, `*test-thread-count*`, lparallel futures). `lparallel` is already a
  system dependency (`ichiran.asd:20`).
- The maintainer confirms the intended scale-out is "native multithreading in Lisp"
  ([#17](https://github.com/tshatrov/ichiran/issues/17)); a user's 8-thread in-process pool
  measured ~100 % core utilization and ~10× the per-line CLI-subprocess throughput.
- **How:** shard a corpus by sentence/chunk into an `lparallel` queue; each worker needs its
  **own Postgres connection** (connections are not shareable across threads; `postmodern`'s
  pool handles this — see `with-connection` usage) or, after front #1, no connection at all.
  Keep the `limit 5` top-N per sentence; keep output ordered by collecting results in input
  order (the `run-parallel-tests`/`process-chunk` pattern in the #17 thread is a usable
  template).
- **Caveats:** threads multiply *throughput*, not *single-sentence latency*; do not parallel
  *within* one sentence — the lattice/scoring path is sequential and shared caches would
  serialize you. After front #1 the workers stop fighting over Postgres, which is the usual
  ceiling. For a *server* shape (ichi.moe-style), prefer one long-lived SBCL process serving
  concurrent requests over spawning CLIs: each `ichiran-cli` process is hundreds of MB and
  re-pays cache warm-up (builders already pre-warm caches into the `.core`, `cli.lisp:106-108`).
- **Do not** parallelize by running many CLI processes as your primary strategy — memory-wasteful
  and slow to start; it is what #17 users did out of necessity and it still left them at
  single-digit lines/s.

**Expected result:** ~N_cores × batch throughput once each worker is cheap (fronts #1/#3),
≈8–10× at 8 cores on top of everything above.

---

## 6. Front #5 — GPU acceleration (CUDA / MPS): verdict

**Not applicable to this algorithm, and no amount of acceleration changes that.** Honest
reasons:

- The pipeline is **sparse, data-dependent, and I/O-bound**: dictionary prefix matching,
  hash lookups on short strings, integer-plist scoring, a small top-5 beam over a sentence
  lattice, and (today) PostgreSQL round-trips. There is no dense tensor math anywhere; the
  parallelism a GPU exploits simply does not exist here. A GPU would sit idle while the CPU
  does a few hundred hash probes, and the CPU→GPU transfer of a 7-character string would cost
  more than the whole parse.
- **Where a GPU could legitimately appear** is only if you *replace* the scoring/search with a
  learned model (e.g. sequence tagging or a neural re-ranker over candidate segmentations,
  trained on Ichiran's own output to preserve its quality). Then, and only then, MLX
  (Apple Silicon / MPS), CoreML, or CUDA-via-PyTorch becomes the right tool for the *neural*
  part. That is a from-scratch project (data generation, training, serving, latency), with
  real risk of regressing the segmentation quality that is Ichiran's entire value — worth it
  only for "realtime at massive scale" requirements that CPUs genuinely cannot meet, which is
  not the regime this codebase targets.
- **The pragmatic "faster interpretation method"** for truly large corpora is *not* GPU but a
  different engine: lattice tokenizers like **Sudachi.rs / MeCab / Vaporetto / kuromoji** run
  at 10⁵–10⁶ words/s/core from mmap'd dictionaries. If your goal is glossing, run one of
  those for pure segmentation speed and call Ichiran (in-memory, front #1) only to enrich the
  words that matter — or keep Ichiran for interactive/quality-critical text. Ichiran's niche
  is accuracy + rich JMdict metadata, which is why it is "famously slow" and why that slowness
  is architectural, not fixable by a faster clock or a GPU.

---

## 7. Prioritized roadmap

All phases keep **output parity as the contract** — the 748-assertion suite
(`tests.lisp`) plus a golden corpus of tricky sentences run before/after every change
(`(ichiran/test:run-all-tests)`).

| Phase | Work | Files | Est. gain | Risk |
|---|---|---|---|---|
| 0 (days) | Instrument: per-sentence query counter via `with-log`/`*query-log*`, `(time ...)` baseline, `sb-sprof` on a long sentence; verify clean rebuild of the docker image | — | (diagnosis) | none |
| 1 (1–2 wk) | Memoize `seq`-keyed lookups (`entry`, conj-data, POS/`uk` props) with `defcache`; fix `calc-score` compile policy; rebuild fasls | `conn.lisp`, `dict.lisp:342-369,777-983`, build scripts | 3–10× | low |
| 2 (2–4 wk) | Sentence-level batching: hoist per-word queries to 2–3 `IN (...)` queries; prepared statements on the rest | `dict.lisp:489-518,1071-1112` | 10–100× total | medium (parity harness) |
| 3 (2–4 wk) | In-memory dictionary load at startup + hash-based `find-word`/scoring; Postgres demoted to source-of-truth + gloss lookups | `dict.lisp`, `dict-grammar.lisp`, new loader | ms/parse | medium-high (memory, boot time; easiest to keep as an opt-in mode) |
| 4 (1–2 wk) | Thread-pool driver over sentence corpus (lparallel), per-thread connections or lock-free after phase 3 | new module (pattern: `tests.lisp:670`) | ~cores × | low-medium |
| 5 (optional, ongoing) | Trie/DAWG prefix search replacing N² substring enumeration; per-code-point scans instead of regex; bound `match-diff` | `characters.lisp`, `dict.lisp:501-518,1071-1112` | 2–5× on long inputs | medium |
| — | GPU (CUDA/MPS) | — | ~0 for this algorithm | — |

**Bottom line:** Ichiran is slow because each word costs PostgreSQL round-trips inside a
loop with quadratic substring probing and tens of MB of allocation per sentence — not because
it is missing a GPU. Fix the data access first (front #1), then allocation/compile policy
(#3), then scale out over cores (#4); treat CUDA/MPS as out of scope unless you plan to
replace the scorer with a learned model, and if you need raw corpus throughput, pair Ichiran
with a Sudachi/MeCab-class tokenizer instead of pushing the Lisp pipeline harder.

## 8. Blind-spot sweep — what the wider ecosystem shows (checked Sep 2026)

Follow-up research across GitHub forks/branches, the issue tracker, and web
searches (web_search tool was broken; used DuckDuckGo/Bing/GitHub-API fetches
and the research-web search MCP). Findings that expand the plan above:

**A. No performance fork exists to cherry-pick from.** Surveyed all ~30 recent
forks (GitHub forks list, newest first) and all upstream branches
(`dec23/jan21/jan26/may21/jul20/ichiran-cli/master`): every divergent commit is a
linguistic fix, errata, or Docker/SBCL-build hygiene (e.g. #58 "Fix SBCL
Dockerfile", the "#62 haunted repo" whose 600 % slowdown vanished on a **fresh
clone + rebuild**). Nobody has shipped an in-memory or otherwise fast Ichiran.
Implication: this work is greenfield — there is nothing to import, and upstream
merge pressure is unlikely; expect to maintain a fork. It also means **stale
builds are a real, boring source of "slow"** — put a clean-rebuild + cache-warm
step in any performance CI (adds to phase 0).

**B. Production adopters converge on a persistent daemon, not per-line CLI.**
The Rust bindings ([ichiran-rs](https://github.com/Heliozoa/ichiran-rs)) and the
Rust glossator [niinii](https://github.com/Netdex/niinii) both bundle a wrapper
that spawns **one** `ichiran-cli` and speaks JSON over stdin/stdout for the
process's lifetime (niinii ships `ichiran/src/server.rs`, `pgdaemon.rs`,
`bench_parse.rs`); `go-ichiran` wraps the dockerized CLI. This confirms §4's
"one warm SBCL process" recommendation as what real adopters already do — and
explains the #17 numbers: per-invocation CLI startup is the dominant cost at
~4 lines/s single-process, while an 8-thread in-process pool reached ~41 lines/s
and the maintainer's own warm-core eval was 0.12–0.41 s for a short parse.

**C. Himotoki — an independent Python/SQLite port of Ichiran's algorithm.**
[himotoki](https://github.com/msr2903/himotoki) ([PyPI](https://pypi.org/project/himotoki/))
re-implements Ichiran in Python on a **portable single-file SQLite backend**
(~3 GB, generated once), with Viterbi-style DP segmentation, the suffix-compound
table (te-iru / te-shimau / tai / sou …), deconjugation chains, and the
synergy/penalty scoring ported from Ichiran; 433 tests and a 510-sentence LLM
accuracy eval (100 %). Significance for this analysis:
1. It is **independent proof that the whole engine ports cleanly off
   PostgreSQL** — the DB is an implementation choice, not part of the algorithm.
   Its embedded-backend + `warm_up()` design is a working blueprint for phase 3
   (pre-generate a serialized dictionary, load it at boot, keep Postgres as
   source of truth).
2. Its suffix/synergy/penalty tables are a **second source of truth** you can
   diff against when porting rules to an in-memory/trie form, and its 510-sentence
   eval harness is a reusable parity-corpus idea for your own regression gate.
3. Python + SQLite is *not* a speed target vs. tuned SBCL — treat it as a
   design precedent and a quality/portability reference, not a competitor.
   (Worth noting for maintainability: it also shows how much rule logic Ichiran
   hardcodes — 200+ splits, 450+ hints, 49 suffix defs, 21 synergies — which is
   the real "horribly code-maintainability-oriented" surface that a rewrite
   would want to make data-driven.)

**D. The "faster interpretation" frontier for this algorithm family.**
Yoshinaga's "Back to Patterns: Efficient Japanese Morphological Analysis with
Feature-Sequence Trie" ([ACL 2023](https://aclanthology.org/2023.acl-short.2/),
[arXiv:2305.19045](https://arxiv.org/abs/2305.19045)) explicitly sets out to
make the *fastest* pattern-based analyzers accurate, via a feature-sequence
**trie** — the exact data-structure move proposed in §3 for replacing Ichiran's
O(N²) substring enumeration. The approach ships as
[Vaporetto](https://github.com/daac-tools/vaporetto) (MIT-licensed Rust): a
credible off-the-shelf component for the "fast segmenter + Ichiran glosses"
hybrid in §6, and a literature anchor for why trie/FST lattice generation is
the right algorithmic direction rather than GPU-style brute force.

**E. GPU still nowhere on the map.** Nothing in the ecosystem (forks, ports,
bindings, daemon wrappers) attempts or needs GPU acceleration; the compute is
sparse dictionary/lattice work with zero dense kernels. The only places GPUs
appear near this stack are unrelated (TTS/ASR/LLM tooling in niinii). Verdict in
§5/§6 stands: ignore CUDA/MPS for Ichiran itself.

## 9. Expected impact — honest estimates by change and by workload

Estimates are anchored to (a) the maintainer's published `time` outputs, (b)
the two user measurements in issues #17/#62, (c) the per-parse query/consing
profile visible in this code, NOT to a benchmark I could run here (no SBCL +
DB in this snapshot). Treat every number as order-of-magnitude until phase 0
(query counter) firms it up. Two regimes matter, plus absolute baselines:

- **Interactive/short warm parse baseline**: ~0.12–0.41 s real per 7-char
  sentence, 56–77 MB consed, 15–73 % CPU (maintainer, #62). The CPU% range is
  the diagnostic: low CPU = parked on DB I/O, high CPU = consing/GC bound.
- **Batch baseline**: 3.9 sentences/s single CLI process (per-invocation
  startup-dominated); ~41 sentences/s at 8 in-process threads with DB still
  attached (users, #17).
- **Long unsegmented run**: quadratic in length → seconds per sentence.

| Change (phase) | Short warm sentence | Long unsegmented run | Corpus throughput (8-core) | Confidence |
|---|---|---|---|---|
| 0. Deployment: daemon instead of per-line CLI | ~1× | ~1× | **5–15×** | measured by users |
| 1. `seq`-memoization + compile-policy fix + clean rebuild | 1.5–3× | 3–10× | 1.5–3× | medium-high |
| 2. Sentence-level query batching | +2–5× | +5–20× | +2–5× | medium-high |
| 3. In-memory dictionary (Postgres out of hot path) | +3–10× | +10–30× | +3–10× | medium |
| 4. Thread pool over sentences (lparallel, per-thread conn or none) | ~1× (latency) | ~1× | +6–12× | measured ~10× @8 |
| 5. Trie/DAWG prefix search replacing N² probes | ~1× | +3–10× | +1.5–3× (long text) | medium |
| **Combined, realistic** | **~10–30×** | **~50–200×** | **~100–400× vs naive per-line CLI; ~20–80× vs warm single-thread in-process** | — |

Reading the table correctly:

- **The 150× end of the range is real but only in corpus mode**, where the
  baseline is the *pathological* per-line-CLI workflow (#17: 3.9 lines/s). Two
  users already got ~10× just by switching to one daemon + 8 threads. Stack
  in-memory + alloc diet on top and ~100–400× vs that baseline is defensible.
- **For interactive single sentences the honest ceiling is ~10–30×**, i.e.
  ~0.1–0.4 s → ~5–20 ms. Ichiran will still be 10–40× slower per sentence than
  MeCab/Sudachi-class engines (sub-ms): it does far more per word —
  deconjugation chains, 450+ hint rules, ~200 split rules, synergy/penalty
  scoring — in CLOS with heavy allocation. Its accuracy niche is the cost.
- **The dominant lever per axis**: latency → DB removal (1–3); throughput →
  threads (4) *after* DB removal so workers stop contending; long-input
  wall → trie (5). Clean rebuild hygiene is a free 1.5–3× when the deployed
  image has gone stale (the #62 case).
- **Quickest validation**: phase 0's per-parse query count via
  `with-log`/`*query-log*` (already in `conn.lisp:89-93`). If a 20-char
  sentence shows hundreds of round-trips at <50 % CPU, phases 1–3 will land at
  the top of the ranges above; if it shows few queries at high CPU, pivot
  budget to allocation/compile work first. That one number decides the plan.

### References
- tshatrov/ichiran — https://github.com/tshatrov/ichiran
- Issue #17 "Slow parsing speed" (community numbers, maintainer's quadratic/thread-safety notes) — https://github.com/tshatrov/ichiran/issues/17
- Issue #62 "Speed degradation by 600%?" (per-parse `time` output: 0.12–0.41 s, 56–77 MB consed; fresh-clone effect) — https://github.com/tshatrov/ichiran/issues/62
- Bindings/consumers showing the deployment reality: Heliozoa/ichiran-rs, tassa-yoniso-manasi-karoto/go-ichiran, Netdex/niinii
- himotoki — independent Python/SQLite re-implementation of Ichiran's algorithm: https://github.com/msr2903/himotoki · https://pypi.org/project/himotoki/
- "Back to Patterns: Efficient Japanese Morphological Analysis with Feature-Sequence Trie" (Yoshinaga, ACL 2023): https://aclanthology.org/2023.acl-short.2/ · https://arxiv.org/abs/2305.19045 · https://github.com/daac-tools/vaporetto
