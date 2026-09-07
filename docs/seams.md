# Ichiran Perf — Seam Contracts (docs/seams.md)

Contract for parallel module work. Read by every module agent before coding.
Anything not specified here defaults to: *pure data in / data out, no direct DB
connections, no edits outside your owned file(s), behavior-identical unless the
change is behind an opt-in flag*.

---

## Golden rules (repeat of IMPLEMENTATION-PLAN §0)

1. Parity = `scripts/parity.sh` exit 0 (764 assertions) AND golden-corpus JSON
   byte-identical. Nothing is "done" without both.
2. Never change a scoring constant, split rule, hint rule, synergy/penalty,
   or errata entry. Ever. If a change *needs* one, stop and file it for a human.
3. No DB schema changes.
4. Every runtime behavior change ships behind a flag: `*<feature>-p*` special,
   default `nil` (off), one-line to enable. Define the flag in your seam.
5. Modules are loaded **additively**: new files added to `ichiran.asd` are
   allowed ONLY by the coordinator (C0). Module agents write `.lisp` files in
   the repo root or `src/`, but do NOT touch `ichiran.asd`.

---

## S1 — seq-keyed lookup cache  (owner: conn.lisp / cache infra)

**Why:** `calc-score` and `get-conj-data` fire 3+ queries per candidate word:
`entry` row, `sense-prop` "uk", `get-non-arch-posi`, `conjugation`,
`conj-source-reading`, `conj-prop`. Most repeat for the same `seq` across a
sentence and across sentences.

**Interface to implement (package `ichiran/cache`, file `src/cache.lisp`):**
- `(ensure-entry seq) -> entry-or-nil`  (memoize `(get-dao 'entry seq)`)
- `(ensure-conj-data seq &optional from) -> list-of-conj-data`
- `(ensure-posi seq-set) -> posi-list`   (memoize `get-non-arch-posi`)
- `(ensure-uk-seq sp-seq-set) -> seqs-with-uk`
- `(cache-reset)` — clear all memo tables (call from `add-errata` / tests)

**Thread-safety:** use the existing `defcache`/mutex idiom in `conn.lisp:96-149`
or `sb-thread:with-mutex` on a per-cache lock. Reads may race; writes must not.

**Contract:** these return the SAME objects/values the current queries return
(after errata). They never open their own connection; they call through the
existing `ichiran/conn` special-bound connection like `select-dao` does today.

**Gate G1 (owned by C0 integration):** with the flag on, per-sentence query
count (bench.sh) drops ≥3× vs baseline, parity green.

---

## S2 — sentence-level prefetch context (owner: same as S1)

**Why:** further cut: load *all* needed entry/conj/posi rows for one sentence in
2–3 batched `IN (...)` queries before scoring, then serve scoring from hashes.

**Interface:**
- `(with-prefetch-context str &body body)` — binds specials
  `*prefetch-entries*`, `*prefetch-conjs*`, `*prefetch-posi*` filled by batched
  queries keyed on every `seq` that `find-substring-words`/`find-word-full`
  will produce. `body` runs with S1 accessors reading these first.
- Specials default `nil` → falls back to S1 live lookups (or current behavior).

**Contract:** used by C0's integration in `calc-score` only. If a needed key is
missing from the prefetch tables (e.g. conj reached via `conj-of` that wasn't
enumerated), fall back to S1/DB transparently — never return wrong data.

---

## S3 — in-memory dictionary (owner: new file, e.g. src/memdict.lisp)

**Why:** the endgame: no per-sentence DB at all. Hot tables into RAM at boot.

**Interface:**
- `(memdict-load)` — slurp `entry`, `kanji_text`, `kana_text`, `conjugation`,
  `conj_prop`, `conj_source_reading`, (optionally `sense*` for glossing) into
  hashes keyed the way current queries key them. Return stats (counts, MB).
- `(memdict-find table text)` — hash hit returning list of DAO-shaped rows
  (same slots/accessors as today) or nil.
- `(memdict-enabled-p)` / `(setf memdict-enabled-p)` — flag.
- Optional `(dump-dict file)` / `(load-dict file)` — serialize/deserialize for
  fast boot without touching PG (use `fasl` dump or a simple binary; document).

**Contract:** accessors must return objects whose `seq`, `text`, `ord`,
`common`, `nokanji`, `conjugate-p` etc. read identically to today's
postmodern DAOs (same slot names), so `calc-score`'s use sites don't change
data-shape. `word-conj-data`/`get-conj-data` paths must consult memdict too.
**Invalidation:** `add-errata` and DB updates must call `(memdict-reload)` or
disable memdict; document the call site for C0.

---

## S4 — trie candidate generator (owner: new file src/trie.lisp)

**Why:** `join-substring-words*` (dict.lisp:1071) probes every (start,end)
window = O(N²); `find-substring-words` materializes all substrings. A trie over
kanji+kana surface texts + suffix stems turns that into a prefix walk.

**Interface:**
- `(build-trie entries)` — build from a list of (text . payload).
- `(trie-prefix-words trie str start max-len) -> list of (end . payload)` —
  every dictionary word beginning at `start` within `max-len`.
- Payload = whatever S3/find-word needs to construct the word (seq/table), or
  the DAO itself; decide with S3 owner.

**Contract:** pure data structure, no DB. Must be built once (boot) and
consulted by C0's replacement of the substring loop behind flag
`*trie-p*`. When `*trie-p*` is nil, current loop runs. Unit tests only — no
parity requirement standalone.

---

## S5 — daemon + corpus driver (owner: cli.lisp + new src/daemon.lisp)

**Daemon:** persistent stdin/stdout JSON loop over `romanize*`, one warm SBCL
process. Already validated by ecosystem (ichiran-rs/niinii). Flag: `--serve`
mode in cli.lisp. Framing: one JSON object per line (no embedded newlines
unescaped — use jsown). Idle: read next line. Exit on EOF.

**Driver:** `(process-corpus file fn &key threads)` — read corpus (lines or the
golden corpus), lparallel pmap over chunks, ordered output. Use
`*test-thread-count*` pattern from tests.lisp. Per-thread connection when S3
off (thread-safe conn pattern exists in conn.lisp); no connection when S3 on.

**Contract:** daemon must be byte-identical to calling `romanize*` directly
(same JSON). Driver preserves input order. Gate G3: 8-thread ≥6× single-thread
warm (measured on a real corpus file).

---

## S6 — character-scan helpers (owner: characters.lisp)

**Why:** hot regex scans (`find-sticky-positions`, `consecutive-char-groups`,
`destem`, `kanji-prefix`) cost regex-engine time per char-class run.

**Interface:**
- `(scan-char-class str class &key start end) -> list of (s . e)` — same
  results as `consecutive-char-groups`.
- `(sticky-positions str) -> list` — same as `find-sticky-positions`.
- `(destem-pos word stem char-class) -> end-pos` — same as `destem` boundary.

**Contract:** table-driven per-code-point (`get-char-class` hash) instead of
ppcre. Byte-identical results. Pure; no DB. No flag needed — but must pass full
parity (these feed segmentation). If any result differs, revert and report.

---

## Integration ownership (C0 only)

The following are owned EXCLUSIVELY by the coordinator and are NOT seams for
module agents: `dict.lisp` (calc-score, find-best-path, join-substring-words*,
find-word, find-word-full, fill-segment-path), `ichiran.asd`, `docker/*`,
`tests.lisp` assertion edits. C0 wires S1–S6 in behind flags and runs parity.

---

## File ownership map (who may write what)

| File | Agent |
|---|---|
| `conn.lisp` | A1 (cache infra only; do not break connection mgmt) |
| `src/cache.lisp`, `src/memdict.lisp`, `src/trie.lisp`, `src/daemon.lisp`, `src/driver.lisp` | new-file owners A1/A6/A5/A4/B3 respectively |
| `characters.lisp` | A3 |
| `cli.lisp` | A4 |
| `dict.lisp`, `ichiran.asd`, `scripts/`, `docker/`, `docs/`, `data/golden-corpus*` | C0 |
| everything else | read-only |

Agents: report in `worklogs/agent-<id>.md` — files touched, flag defined,
self-verify output, gate status, risks. Commit at each verified step on your
branch `perf/<phase>/agent-<id>` off `perf/<phase>`.
