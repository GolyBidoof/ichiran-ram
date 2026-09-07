# Ichiran Performance Implementation Plan — Agent-Fleet Ready

*How to implement the improvements from `PERFORMANCE-ANALYSIS.md`, and how a
fleet of agents can carry the work (e.g., overnight batches). Reads after the
analysis doc; assumes its phases 0–5 and impact estimates (§9).*

---

## 0. Guardrails (definition of done — non-negotiable)

1. **Behavior parity is the contract.** The 748-assertion suite
   (`(ichiran/test:run-all-tests)`, `tests.lisp`) must pass before/after every
   change, plus a **golden corpus**: a fixed set of ~200 sentences (short,
   long-run-on, particles, counter, kana-only, rare readings, hints) whose full
   `romanize*` JSON is snapshotted once and diffed on every change. If a diff
   appears, the change is reverted or explicitly signed off with a reason.
2. **No scoring-constant, split-rule, hint-rule, or errata edits without a
   human.** 500+ errata, ~200 splits, 450+ hints encode linguistic decisions;
   agents must never "fix" a number to make a test pass.
3. **No DB schema changes** (the `.pgdump` is the source of truth; changes only
   via upstream-style errata tooling).
4. Every perf change ships behind a **feature flag or A/B seam** until its gate
   passes, so a bad night can be disabled in one line.
5. Metrics gate (from analysis §9): target after all phases ≈ 10–30× on short
   warm sentences, 50–200× on long run-ons, 100–400× corpus vs per-line CLI.
   Each phase has an intermediate gate (table in §6).

---

## 1. Prerequisites & environment (do this BEFORE any agent edits code)

**Hard requirement: agents cannot compile or run Ichiran without a live env.**
This snapshot has no SBCL, no settings.lisp, no `.pgdump`. Every claim below
assumes one of:

- **(Recommended) A runnable Docker env** on the machine hosting the fleet:
  `docker compose up` (Postgres + ichiran core image), then a warm-core dump.
- Or a manual SBCL + PostgreSQL install with the DB restored and
  `(init-all-caches)` / `(init-suffixes t)` run.

**Coordinator (serial, small, one agent — call it C0) prepares:**
1. `git init` + initial commit in this repo — **needed for fleet rollback**;
   there is no git metadata today. Without git, parallel agents cannot be
   isolated or reverted.
2. `scripts/env-check.sh` — asserts `docker`/`sbcl` reachable, DB reachable,
   core image builds, `(ichiran/test:run-all-tests)` green on a clean tree.
3. `scripts/parity.sh` — runs the 748 tests + golden-corpus diff; exit 0 = ok.
4. `data/golden-corpus.txt` + `data/golden-corpus-baseline.json` — generated on
   the clean tree (this is the "measure first" artifact of phase 0).
5. `docs/seams.md` — the interface spec from §2 below, so every agent builds to
   the same contract.
6. Baseline numbers into `worklogs/baseline.md` via the query counter
   (see A2) — counts of queries per sentence at several lengths, `(time ...)`,
   CPU%.

C0 is ~2–4 agent-hours and **must finish before any writer starts**.

---

## 2. Seams-first architecture (how parallel work stays mergeable)

The engine is a monolith: `dict.lisp:777-983` (`calc-score`) + `1190-1233`
(`find-best-path`) sit under everything, and every agent editing them directly
would collide. Rule: **agents build modules to a seam; one integration pass
wires seams into the monolith.** Seam = a function signature + where it plugs
in + a behavior contract, defined once in `docs/seams.md` by C0.

| Seam | Interface (agents implement) | Plugs into (integration) | Provider agent |
|---|---|---|---|
| **S1 seq-keyed lookup** | `(cache:get-entry seq)`, `(cache:get-conj seq from-or-ids)`, `(cache:get-posi seqs)` returning plain data, `NIL`/`:null`-safe, thread-safe, invalidatable | `calc-score`'s `get-dao`/`select-dao` calls (`dict.lisp:803,822-827`), `get-conj-data` (`342-369`) | A1 (conn.lisp) |
| **S2 sentence prefetch ctx** | `(prefetch:with-prefetch str thunk)` — 2–3 `IN (...)` queries per sentence; fills hashes readable via S1-style accessors | Bound as specials around scoring like the existing `*suffix-map-temp*` convention (`dict.lisp:1048-1050`) | A1/A6 |
| **S3 in-memory dictionary** | `(memdict:load)`, `(memdict:find-text table str)` etc. — loads hot tables once, ~few hundred MB, demotes Postgres in the hot path | `find-word`/`find-substring-words` (`dict.lisp:489-518`) | A6 |
| **S4 trie candidates** | `(trie:build dict)`, `(trie:find-prefixes str start)` — dictionary-prefix walk replacing O(N²) probes | `join-substring-words*` (`dict.lisp:1071-1112`) | A5 |
| **S5 corpus driver + daemon** | `(driver:process-corpus file fn &key threads)` (lparallel, ordered output); `(daemon:serve)` — one persistent stdin/stdout JSON loop | `cli.lisp`, new `ichiran/cli` mode | A4 |
| **S6 char-scan helpers** | table-based `(chars:scan-class str start)` replacing hot regexes | `characters.lisp` hot functions | A3 |

Contract notes: modules are **pure at their boundary** (return data, never
open their own DB connection unless specified), unit-testable standalone, and
never `require` internals of `dict.lisp`. Integration = one serial commit that
makes `calc-score`/`join-substring-words*` consult S1→S4 under a flag
(e.g. `(defvar *memdict-p* nil)`, `(defvar *prefetch-p* nil)`).

---

## 3. Milestones and agent task briefs

Each task below is a ready-to-hand **agent brief**. Writers work on files they
exclusively own (§4); readers may fan out wider.

### M0 — Foundations (serial, C0)
Tasks: env-check script, git init+commit, golden corpus snapshot, parity.sh,
seams.md, baseline.md. **Gate:** parity.sh green on clean tree; baseline
numbers recorded. *(Effort ≈ 2–4 agent-hours; must be done first.)*

### Fan-out A — Parallel module builds (file-disjoint; 4–6 writers + readers)

| Agent | Owns (exclusive) | Brief | Self-verify |
|---|---|---|---|
| **A1** | `conn.lisp` | S1+S2 infra: thread-safe `defcache`-style memo tables for entry/conj/posi + prefetch context macro; reuse mutex patterns at `conn.lisp:96-149`; no behavior change to existing caches | sbcl: load conn; unit calls with a temp DB; full suite can't run standalone → report |
| **A2** | `worklogs/` (new), reads everything | Bench & instrument: query counter (via `with-log`/`cl-postgres:*query-log*`, `conn.lisp:89-93`), `(time ...)` runner over corpus, `sb-sprof` on a long run-on; emit baseline.md + perf JSON | run on docker env |
| **A3** | `characters.lisp` | S6: replace hot regex scans (`find-sticky-positions`, `consecutive-char-groups`, `destem`, `kanji-prefix`) with per-code-point table walks; keep public behavior identical | corpus + kanji tests subset |
| **A4** | `cli.lisp`, new `daemon.lisp` | S5-daemon: persistent stdin/stdout JSON loop over `romanize*` (one warm process), `--serve` mode | feed 100 lines, check framing + order |
| **A5** | new `trie.lisp` | S4: trie over kanji+kana surface texts + suffix stems; interface per seams.md; unit tests with sample dict | trie unit tests |
| **A6** | new `memdict.lisp`, new `dump-dict.lisp` | S3: loader that slurps hot tables into hashes (or reads a pre-generated dump), accessors; note dynamic-space needs | load on docker env; size + hit-rate report |

**Readers (parallel, read-only — safe to run 8–10 at once):** inventory every
query site under `calc-score`'s reach with estimated frequency (A2 feeds these
by grep/walk); categorize `dict-split.lisp`'s ~200 splits + `dict-grammar.lisp`
hints/synergies into "cheap regex/string" vs "DB-touching" buckets (feeds later
data-ification); verify no scoring semantics are hidden in the regexes A3
touches.

**Integration I1 (serial, C0/core agent after A1–A2):** wire S1/S2 into
`calc-score` behind `*prefetch-p*`; run parity + gate (§6 G1). **Gate:**
`*prefetch-p*` on ⇒ ≥3× fewer queries/sentence, parity green.

### Fan-out B — Round 2 (after I1 lands)
- **B1 (A5-Agent):** S4 swap into `join-substring-words*` behind a flag.
- **B2 (A6-Agent):** S3 swap: `find-word`/suffix path via memdict behind
  `*memdict-p*`; measure long run-ons.
- **B3 (new agent):** `driver.lisp` S5-pool — lparallel kernel, per-thread
  connection when S3 off, ordered results, progress; unit-tested pattern from
  `tests.lisp:670-677`.
- **B4 (A3-Agent):** allocation/compile-policy pass: fix
  `(optimize (speed 3) (debug 3))` at `dict.lisp:778`, add declarations on the
  hot scalar path, trim `format`-string churn in `get-senses-*` (with-info).
  **Highest-drift risk → gate first.**
- **Readers:** re-run baseline instruments against each flag to produce the
  before/after table.

### Integration I2 + tune (serial, C0)
Merge B1–B4 behind flags, run full parity on every flag combination, pick
defaults, update docker build scripts (init-all-force) to compile the flags in,
re-dump core image, re-run §6 gates, update PERFORMANCE-ANALYSIS §9 with real
numbers.

---

## 4. Fleet operating model

**Roles**
- **Coordinator (parent agent / C0):** owns the serial core
  (`dict.lisp` hot functions, `ichiran.asd`, integration commits, parity runs),
  merges branches, adjudicates failures. *Only role allowed to edit
  `calc-score`/`find-best-path` or add files to `ichiran.asd`.*
- **Module agents (A1–A6/B1–B4):** writers; own their files exclusively.
- **Reader agents:** analysis/inventory only; never write code.
- **Verifier agent (per round):** runs parity.sh + gates on the merge and
  reports a pass/fail + metric table.

**Ownership table** (exclusive writer → no two writers touch the same file in
one round; this is the entire conflict-avoidance strategy):
coordinator: `dict.lisp`, `ichiran.asd`, `scripts/`, `docker/`, `tests.lisp`(only
adding, never editing assertions), `docs/`; A1: `conn.lisp`; A3: `characters.lisp`;
A4: `cli.lisp` + `daemon.lisp`; A5: `trie.lisp`; A6: `memdict.lisp`+`dump-dict.lisp`;
B3: `driver.lisp`; all others: read-only.

**Git discipline (non-negotiable for a fleet):**
1. C0 creates `perf/<phase>/` base branch from the initial commit.
2. Every writer works on `perf/<phase>/agent-N` from that base.
3. End of round: C0 merges each branch **one at a time**, runs parity.sh after
   each merge, reverts the guilty branch on failure, logs the failure.
4. Every agent commits at each self-verification point, with the gate output in
   the commit message. No long-lived uncommitted work.

**Brief template (every writer receives this):**
```
OBJECTIVE: <one sentence>
FILES (exclusive): <list>  — do not modify anything else
SEAM(S): <S1...> per docs/seams.md
INVARIANTS: behavior parity; no scoring/split/hint/errata constants; no DB
            schema changes; thread-safe caches
SELF-VERIFY: <exact command(s) on the docker env>
GATE: <metric + parity requirement>
REPORT: <files changed, gate output, measurements, risks, hours>
FORBIDDEN: touching other agents' files, editing tests to pass, silent
           constant changes, running integration (dict.lisp) edits
```

**Checkpointing for overnight runs:** every agent writes `worklogs/agent-N.md`
(state, gate outputs, blockers) at its end; coordinator's morning summary =
concatenation of these + the merge log. A night is resumable from any round
because the repo is committed at each step and `worklogs/` records state.

**Why writer-count is capped at ~6:** the integration surface is one monolith
file plus a handful of seams; more concurrent writers than file owners is pure
contention. Readers can be ~10 because read-only analysis never conflicts.
Attempting "20 agents all editing calc-score" would produce merge hell, not
speed — the honest ceiling of this codebase.

**Overnight runner (where a workflow tool fits):** a workflow with phases
(Baseline-check → fan-out A/B writers → per-agent verify → coordinator merge →
parity → report) is exactly the shape this plan implements; each phase maps to
the tables above, and the coordinator keeps total-agent count within the caps.
See §8 for where this must physically run.

---

## 5. Two concrete night plans

**Night 1 (foundations + round A):** pre-flight env-check → C0 baseline +
parity + golden corpus (~2–4 h) → fan-out A (A1–A6 writers, 6 readers) →
verifier merges A1→A4 (each: merge, parity) → leave A5/A6 branches for
integration tomorrow if late. **Expected artifacts:** baseline.md with real
numbers, working daemon mode (immediate deployment win), cache/prefetch infra
(A1), trie + memdict modules built and unit-tested, query-site inventory.
**Morning:** metrics table + merge log; decide I1.

**Night 2 (integration + round B):** I1 (S1/S2 into calc-score, gate G1) →
fan-out B (B1–B4) → merge+parity per branch → I2 prep. **Expected artifacts:**
`*prefetch-p*` measured (≥3× fewer queries), trie + memdict wired behind flags
and measured on long run-ons, driver pool measured at 8 threads, compile-policy
commit in. **Morning:** full before/after metric table.

**Night 3 (tune + ship):** flags to defaults, docker build scripts updated,
core image re-dumped, full parity on all flag combos, docs updated. **Morning:**
§6 gate table + "revert one line" instructions for every flag.

---

## 6. Metric gates (each phase must hit these to proceed)

| Gate | After | Target | Verify |
|---|---|---|---|
| G0 | M0 | parity green; baseline recorded | scripts/parity.sh |
| G1 | I1 (S1/S2) | ≥3× fewer DB queries/sentence; short-parse real time ≤ 50 % of baseline | A2 instrument |
| G2 | I2-B1/B2 (trie+memdict) | long run-on (60+ char, no punct) parse ≤ 20 % of baseline | bench runner |
| G3 | I2-B3 (driver) | 8-thread corpus ≥ 6× single-thread warm | driver bench |
| G4 | I2-B4 (compile/alloc) | bytes-consed/parse ≤ 30 % of baseline | `(time ...)` |
| G5 | Final | all of G1–G4 + full parity + golden-corpus byte-identical | full suite |

Real targets to write into the gate script come from baseline.md (G0) — never
assume the analysis-doc estimates; measure first.

---

## 7. Risks & mitigations

| Risk | Mitigation |
|---|---|
| Agents drift scoring/errata constants "to make tests pass" | Guardrail 2 + code-review-style diff scan by coordinator at each merge; golden corpus catches drift |
| Cache invalidation bugs (errata/add-errata mutate DB; stale memdict) | S1/S3 expose `invalidate`/`reload`; `add-errata` path calls it; document in seams.md |
| No runnable env in this workspace | §8 — fleet must run where docker compose up works; otherwise agents may only do static/read-only work |
| Memdict memory blowup / GC stalls | `--dynamic-space-size` guidance; load once at boot (daemon); measure RSS; per-table opt-in |
| Flag combinations explode parity space | I2 runs full parity per flag combo; only 4 flags ⇒ 16 combos, scripted |
| Threaded workers + shared caches | conn.lisp mutex patterns + per-thread connections when DB still hot (S3 off); driver unit-tested first |
| Writers editing same file | §4 ownership table + git branches; cap writers at file-owner count |
| "Overnight" writes code that doesn't compile against a changed seam | seams.md frozen per round; C0 reviews seam drift at merge |

---

## 8. Where the fleet must run (honest deployment note)

**This workspace cannot host the write-fleet:** no SBCL, no settings.lisp, no
Postgres dump — every agent would be editing blind. Run the fleet on a host
where `docker compose up` (or an equivalent manual stack) succeeds, then agents
have `scripts/parity.sh` and the bench as ground truth. In this session we can
still usefully fan out **read-only** agents (baseline inventory, query-site
manifest, split/hint rule categorization, seams.md drafting) — that is Night 1's
reader layer and costs nothing to run without a DB.

---

## 9. What cannot be parallelized (and why that's fine)

- **`calc-score` / `find-best-path` / `join-substring-words*` integration** —
  one writer (coordinator). These are the heart of the monolith and every other
  change plugs into them; parallel edits = guaranteed conflicts.
- **ichiran.asd edits and docker build scripts** — coordinator only.
- **Parity/golden-corpus runs** — serial by construction (must see each merge
  alone to blame failures).
- **The guardrail reviews** — a human or the coordinator decides drift calls.
Parallelism lives in the *modules, the analysis, and the verification*, which
is where the hours actually are; the serial core is a few focused commits per
round, not a bottleneck once modules are done.

---

*Companion: `PERFORMANCE-ANALYSIS.md` (analysis, estimates §9) — read first.
Ready-to-run items pending the environment: scripts/env-check.sh,
scripts/parity.sh, docs/seams.md, worklogs/ (all C0 deliverables).*
