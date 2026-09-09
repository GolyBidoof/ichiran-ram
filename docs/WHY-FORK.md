# Why This Fork Exists (docs/WHY-FORK.md)

Upstream [ichiran](https://github.com/tshatrov/ichiran) answers every
dictionary lookup from PostgreSQL at analyze time — thousands of queries per
sentence, which dominates latency over any non-local DB link. This fork adds
an **in-RAM serving path**: hot dictionary tables load once into compact
indexed structs, and the analyzer's hot lookups are routed to RAM behind
flags that default OFF.

What is distinct here:

- **In-RAM dictionary** (`src/memdict-compact.lisp`, `src/trie.lisp`):
  per-access-pattern indexes (by text, by seq, by sense-id, …), copy-on-return
  so analyzer mutations never pollute the indexes, DB row order mirrored so
  scoring tiebreaks usually agree.
- **Serving cores**: `scripts/build-image.sh` dumps preloaded images
  (`lite` = kana+senses for a laptop, `full` = all 9 tables for a big host);
  `scripts/serve-core.sh` answers stdin→JSON lookups with zero DB.
  Load with `(ql:quickload :ichiran/ram)` (see `#:ichiran/ram` in `ichiran.asd`).
- **Measured wins**: −58% queries on the 8-sentence corpus, −51% queries /
  −48% wall time on a full page (localhost); over a remote DB the
  query-count win matters more. Details in `docs/RAM-DICTIONARY.md`.
- **Flags-off parity philosophy**: with all flags off, code paths are
  byte-identical to upstream. Every behavior change ships behind a
  `*…-p*` special defaulting to `nil`, and `scripts/parity.sh` plus
  `scripts/golden-diff.sh` must both stay green.

Scope boundaries (what this fork does NOT do):

- No scoring, split, hint, synergy/penalty, or errata changes.
- No DB schema changes.

Note: `worklogs/` holds dev session notes (design, benchmarks, handover).
It is excluded from any release tarball.
