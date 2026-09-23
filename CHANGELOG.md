# Changelog

## Unreleased

- **Serving path now issues 0.28 queries per line** (was 17.12): every
  remaining per-candidate query has a RAM mirror, and a RAM miss is trusted
  when the table's row count matched the DB at load (`int-register-text-table`
  records it in `*complete-tables*`). Corpus 2.52s -> 1.54s, 13.43x vs the DB
  path, 4.24ms/line. New mirrors: `find-word-with-pos`, `get-dao` by primary
  key in the conjugation parent walk, `conj_source_reading` by
  `(conj_id, source_text)`, `find-word-seq`, `get-kana-form`,
  `find-word-conj-of`, `get-kana-forms*` (backed by a new by-from index on the
  integer conjugation table), the `calc-score` prefer-kana `ord 0` probe and
  the `:desu` suffix probe.
- **Thread-parallel serving** (`src/serve-parallel.lisp`, wired into
  `scripts/serve-system.sh` as the default, `WORKERS=` to size, `SERIAL=1` to
  disable): 5.57x on 8 workers (1.153s -> 0.207s), output byte-identical to
  serial at every worker count. Each worker binds private copies of the three
  memo tables written during serving (`*is-arch-cache*`, `*reading-cache*`,
  `*memdict-fn-cache*`) and opens its own DB connection, since postmodern's
  `*database*` is a global special and a shared connection would corrupt.
- **Rows are built straight from the integer columns**: `int-text-row-fields`
  returns the ten fields as multiple values and `decode-int-row-at` constructs
  the struct directly, removing a plist per lookup from a hot path. 1.54s ->
  1.28s, 14.50x vs the DB path, 3.50ms/line.
- `adjoin-word` shims for compact rows: the DAO methods specialise on
  `simple-text`, so building a suffix compound from a RAM row previously
  signalled no-primary-method now that `find-word-with-pos` returns compact
  structs.
- Note: cl-ppcre in this tree has no scanner cache, so regexes really are
  recompiled per call. Memoizing them was measured and does **not** help
  (`simplify-ngrams`: scanner builds 3436 -> 3, run got slower); the cost is
  matching, not compiling. GC is 0.2% of wall time despite 561MB consed per
  corpus run, so allocation reduction is not a wall-clock lever here. See
  worklogs/PERF-PLAN.md.

- Integer-keyed dictionary layer (`src/memdict-int.lisp`) covers `kana_text`,
  `kanji_text`, `entry`, `conjugation`, `conj_prop` and
  `conj_source_reading` as typed columns plus interned pools: 7.2GB for all
  six, roughly half the compact hash cost for the text tables. Loaded through
  `memdict-load-int`; row counts asserted against `SELECT count(*)`.
- Whole dictionary now fits a 16GB machine at 8.1GB heap. Corpus wall time
  18.85s -> 2.52s (51.8ms -> 6.9ms per line, 7.48x) with the integer layer
  plus the compact sense layer; `PRESET=full-ram scripts/build-image.sh`.
- Fixed two silent integer-backend bugs that only RAM-vs-DB comparison caught:
  `int-conj-props-by-id` returned five fields where callers destructured six
  (so conjugation-type filtering found nothing and te-iru compounds were
  dropped), and the `compact-kanji` `get-kana` shim bypassed `best-kana-conj`
  (so conjugated kanji kept their kanji text as the reading). Golden-corpus
  primary-output mismatches vs the DB path: 37/364 -> 7/364, the remainder
  being alternative-ordering ties. See worklogs/R7-REPORT.md.
- Profiled page serving under lite RAM with sb-sprof: ~81% of wall time is
  Postgres socket I/O, Lisp hotspots under 2% each. Query-killing outranks
  all CPU work; see worklogs/R6-REPORT.md.
- `SYSTEM=1` build knob (`scripts/build-image.sh`): bakes analyzer + shims
  + dict + `*memdict-p*` into one core. System-lite core (175MB) cold-starts
  to first romanize in ~2s with no quickload and no DB (was ~9 minutes).
- `scripts/serve-system.sh`: persistent stdin-to-romanize server on the
  system core (~25ms/sentence warm). Protocol: ignore lines until
  `{"ready":true}` (SBCL banner precedes it; `--quiet` is unusable with
  `--core`).

- In-RAM dictionary (`src/memdict-compact.lisp`): hot dictionary tables load
  as compact structs with per-access-pattern indexes; new `ichiran/ram`
  ASDF system (in `ichiran.asd`) so `(ql:quickload :ichiran/ram)` replaces
  the manual `--eval` load dance.
- Serving cores: `scripts/build-image.sh` presets `lite` (kana+senses,
  ~168MB compressed core) and `full` (all 9 tables); `scripts/serve-core.sh`
  serves stdin→JSON lookups with zero DB.
- Table gating: partial loads are correct — `memdict-call` serves from RAM
  only when all tables a lookup needs are in `*loaded-tables*`, else falls
  back to DB; sense and conjugation trios gate as units.
- Verify gate: every `memdict-load` ends with `MEMDICT-VERIFY-OK <table>
  ram=N db=N` row counts vs `SELECT count(*)`; loads `ORDER BY` a unique key.
- Benchmarks: −58% queries on the 8-sentence corpus (5845 → 2459);
  −51% queries on the full page (180,985 → 89,335), −48% wall time
  (19.8s → 10.3s, localhost).
- Tests: `ram-gating-test` + `ram-helpers-test` in `tests.lisp`
  (fixture-based, no DB); parity via `scripts/parity.sh`, output parity via
  `scripts/golden-diff.sh`.
- Correctness fixes: `:with-info` JSON keeps conjugations/true-text for RAM
  readings (`simple-like-p`); `sense-id` shim returns the sense id;
  `select-conjs` returns NIL for `:root` like the DB; RAM branches requiring
  shim generics fall back to DB when shims are unloaded; idempotent
  per-key ordering (repeat loads can't un-flip lists); copy-on-return so the
  analyzer can't pollute RAM indexes across sentences; `ram-regression-test`
  covers them.
- Build/bench: `ICHIRAN_DB_*` env connection config, mktemp template,
  `--out` path parsing; benchmark harness lives at
  `scripts/bench-config.lisp` and loads shims like production.
