# Changelog

## Unreleased

- **The README was cut from 532 lines to 322 and reordered around doing the
  thing.** "Get it running" is now the first section, three numbered steps:
  install ichiran (Docker or local SBCL), run `./scripts/ram-setup.sh`, then use
  the same commands as always. The manual contents list is gone, since GitHub
  renders its own; the benchmark prose was cut to the numbers and the caveat that
  the comparison against upstream is deliberately checkable; and the harness
  inventory, the document index and the raw run logs were folded into one "Going
  deeper" section. Nothing was deleted that a reader needs, and no number moved.
- **The README opening was rewritten in a plainer voice.** It now names ichiran as
  the analyzer behind ichi.moe, explains the cost as one habit rather than as an
  architecture, and makes the case in claims with the receipts next to them: the
  whole dictionary in 8.1GB, a 469MB file answering in about a second, 18,939
  lines in 2.3 seconds instead of about 17 minutes, nothing to run beside it. The
  section formerly called "what this unlocks" is now "what you get" and reads as
  consequences rather than bullet points, and it points at the setup script's own
  deliberate wrong-password test as the reason to believe the core needs no
  database. Verification gained a line about why a fast wrong answer is worth
  nothing, and the requirements section states the trade plainly.
- **Throughput on the third-party samples is now in the README**, with totals as
  well as per-line cost, the samples described rather than named, and the
  database totals for the long ones scaled by characters from measured slices.
- **The database path was measured against unmodified upstream ichiran** on
  identical text (`ea95833`, cloned from GitHub, same PostgreSQL, same harness):
  49.77 against 49.76 ms per line on the golden corpus, 87.67 against 81.38 on a
  visual-novel prologue, 16.68 against 19.66 on a manga slice, and 54.84 against
  52.59 on a magazine slice. The two paths are equivalent in both directions, so
  the README no longer presents the database column as the source of the speed,
  and docs/PERFORMANCE-HISTORY.md records the whole comparison.
- Corrected the magazine database figure to about 17 minutes, from the 55.12 ms
  per line measured over a 2,905-line slice, replacing an earlier extrapolation
  from a 300-line slice whose lines were atypically short.
- **README and repository metadata reworked for discovery.** The top of the
  README now leads with what the fork is and what it changes: about 40x per line,
  0.28 SQL queries per line instead of 17.12, no database at runtime, 8.1GB of
  heap for the whole dictionary, a 469MB core ready in about a second, and the
  byte-identical guarantee stated where it is first read. It gains badges, a
  section on what the speed is worth, and the numbers table extended with the query and
  memory axes. The GitHub description was rewritten and the repository had no
  topics at all; it now carries twenty. `docs/WHY-FORK.md` was rewritten to match
  the current numbers and to say who the fork is for.
- **The plain `ichiran-cli` command is now a dispatcher**, so the same command
  with the same options works before and after setup: PostgreSQL while no RAM
  dictionary exists, the baked core once one does. It reports the backend on
  stderr, `ICHIRAN_BACKEND=db` or `=ram` forces either, and database-building
  commands (`full-init`, `load-jmdict`, `add-errata`, `load-best-readings`)
  answer with what to do instead rather than doing work the fork does not need.
  In the container, `docker/ichiran-scripts/ichiran-cli` routes the installed
  command through the same dispatcher.
- `.dockerignore` now excludes `local-env/`, `*.core`, `*.snap` and the built
  `ichiran-cli`. Before this, the whole of `local-env/` went into the image
  build context as `COPY ./`, so snapshots, cores, quicklisp and any corpora kept
  out of version control would have shipped inside a built or pushed image.
- `ram-setup.sh` finds the docker database host by itself, trying the `pg`
  service when `localhost` is not reachable, and exports the resolved connection
  to the build steps.
- **`scripts/ram-setup.sh`: one command from a database to a zero-database
  server.** It checks SBCL, quicklisp and the database, writes the snapshots,
  bakes a serving core, and then romanizes a sentence from the core with
  deliberately wrong database credentials so a silent fallback to PostgreSQL
  fails the setup instead of passing quietly. Re-running reuses existing
  artifacts; `FORCE=1` rebuilds, `PRESET=lite` builds the smaller dictionary,
  and `SKIP_SNAPSHOT=1` / `SKIP_CORE=1` / `SKIP_DB_CHECK=1` skip stages.
- **`scripts/ram-cli.sh`: the ichiran CLI on the baked core.** Same options as
  `ichiran-cli` (`-i`, `-f`, `-l`, `-e`), no dictionary load, no database. It
  loads `:ichiran/cli` on top of the core and passes the arguments through a
  file, so shell quoting never has to survive a trip through Lisp.
- `scripts/serve-system.sh` now finds the core by itself, preferring
  `local-env/ichiran-serving.core` (the one `ram-setup.sh` builds) and falling
  back to `local-env/ichiran-system-lite.core`, so it needs no `CORE=` after a
  setup run.
- **The benchmark corpora are no longer in this repository**, in the working
  tree or in any commit. They were third-party text and could not be
  distributed, so all references are anonymized: line counts, character counts
  and timings are kept, the titles are not. Every harness now takes its input
  from `CORPUS` and defaults to `data/golden-corpus.txt`, which this project
  authors itself. See docs/PERFORMANCE-HISTORY.md.
- **README rewritten** as a user guide: quick start for Docker and for a local
  install, the fast path in three steps, a command-for-command migration table
  from upstream ichiran, and the three verification gates.
- `scripts/sbcl-wrapped` no longer hardcodes Homebrew's SBCL path. It honors
  `SBCL=`, then `/opt/homebrew/bin/sbcl`, then SBCL on `PATH`, and it falls back
  to `~/quicklisp/setup.lisp` when `local-env/quicklisp` is absent, so a fresh
  clone runs on Linux too. `scripts/bench-all.sh` accepts `CORPUS` as well as
  `CORPORA`.
- `scripts/serve-snapshot.sh`: full-dictionary serving on a 16GB machine
  without a baked core. `serve-system.sh` needs a saved core and baking the
  full dictionary into one needs a 32GB+ host, so nothing on this machine
  could serve the complete RAM dictionary; this boots it from the snapshot
  instead (7.6s measured for the integer layer, versus ~70s from PostgreSQL)
  and then serves stdin to stdout with the parallel worker pool. The compact
  sense layer still comes from PostgreSQL at startup (~1s), so a database is
  required to boot even though the serving path itself issues no queries.
  The parallel path announces readiness exactly once, via `serve-stream`.
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
- Note on regex scanning: cl-ppcre caches STRING patterns but not the list
  patterns the character-class helpers were handing it, so `count-char-class`
  recompiled its scanner on every call, 497 times per line. Compiling those
  patterns once (`*char-count-scanners*`) cut scanner builds from 1,491,524 to
  6,000 over 3,000 lines, for 11.9% best and 5.5% median speedup. An earlier
  attempt to memoize `simplify-ngrams` scanners did not help and was dropped:
  the cost there is matching, not compiling. GC is 0.2% of wall time despite
  561MB consed per corpus run, so allocation reduction is not a wall-clock lever
  here. See worklogs/PERF-PLAN.md and docs/PERFORMANCE-HISTORY.md.

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
- Table gating: partial loads are correct - `memdict-call` serves from RAM
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
