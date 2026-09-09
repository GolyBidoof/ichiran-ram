# Changelog

## Unreleased

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
