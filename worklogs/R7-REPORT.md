# R7 report: integer-keyed dictionary layer

Goal: get the whole dictionary into RAM on a 16GB machine, fast enough that
serving is bounded by Lisp rather than by the Postgres socket.

## What landed

`src/memdict-int.lisp` encodes each table as parallel typed vectors plus an
interned string pool and two integer indexes (text-major, seq-major), instead
of one struct plus several hash tables per row. Registration through
`memdict-load-int` (`src/memdict-compact.lisp`) makes the integer backend serve
the same lookups the compact hash backend serves, so either can back a core.

Tables now integer-backed (measured, `main` at the time of writing):

| table | rows | RAM | compact before |
|---|---|---|---|
| `kana_text` | 3,289,512 | 1429 MB | 2680 MB |
| `kanji_text` | 5,435,707 | 2345 MB | 4330 MB |
| `entry` | 2,512,557 | 506 MB | - |
| `conjugation` | 2,343,276 | 44 MB | - |
| `conj_prop` | 2,358,731 | 59 MB | - |
| `conj_source_reading` | 8,386,607 | 2851 MB | - |
| **total** | | **7234 MB** | |

Row counts are asserted against `SELECT count(*)`; loads use `ORDER BY` a unique
key so unordered `LIMIT/OFFSET` paging cannot silently drop rows.

## Two correctness bugs found and fixed

Both were silent: output stayed plausible, so only RAM-vs-DB comparison caught
them.

1. `int-conj-props-by-id` returned five fields where its callers destructured
   six, so `conj-type` received the `pos` string. Every suffix rule that
   filters on conjugation type then found nothing, which dropped te-iru
   compounds: `書いています` split into `kaite imasu` where the DB path gives
   `kaiteimasu`. Fixed by echoing `conj-id` in the result.
2. The `compact-kanji` `get-kana` shim bypassed `best-kana-conj` and used a
   weaker "first kana reading" fallback. `best_kana` is NULL for many
   conjugated rows, so conjugated kanji kept their kanji text as the reading
   (`食べた` rendered `食beta` instead of `tabeta`). The shim now mirrors the
   `kanji-text` method exactly, backed by a new RAM mirror of
   `query-parents-kanji` / `query-parents-kana`.

## Parity

Primary-output (`ichiran:romanize`, the reading a user sees) over the full
364-line golden corpus, RAM vs DB:

| configuration | mismatches |
|---|---|
| before the two fixes | 37 / 364 (10.16%) |
| after | 7 / 364 (1.92%) |

All 7 remaining are alternative-ordering ties: the same set of readings in a
different order (`zen/mae` vs `mae/zen`, `mise/ten` vs `ten/mise`). They are
not missing readings. Reproducing them would mean imitating PostgreSQL's
unordered row choice, which is itself unstable; the deterministic RAM order is
kept deliberately.

`scripts/parity.sh` reports `PARITY_OK` (0 failed) and `scripts/golden-diff.sh`
reports `GOLDEN_DIFF_OK` (byte-identical to baseline) with the flags off.

The golden drift seen on the `錬丹術` line during this work was verified to be
pre-existing in-process nondeterminism: that sentence produces two different
outputs within a single process (two runs of one hash, then a different hash on
the third), unchanged by these changes and unaffected by reverting them.

## Where the remaining time went

Counting queries through `cl-postgres:*query-callback*` over 25 corpus lines:

| configuration | queries | per line |
|---|---|---|
| integer layer only | 5973 | 238.9 |
| integer layer + compact sense layer | 428 | 17.1 |

The integer layer alone saved little because `sense_prop` still answered 76% of
the remaining queries (the `uk` "usually kana" probe and the posi query). Those
two query shapes are per-word, so they dominate volume: more tables in RAM is
not enough, the right tables have to be in RAM.

## Combined configuration and result

Integer layer for `kana_text`, `kanji_text`, `entry`, `conjugation`,
`conj_prop`, `conj_source_reading`; compact hash layer for `sense`, `gloss`,
`sense_prop` (not yet integer-backed). Reproducible via
`PRESET=full-ram scripts/build-image.sh`.

| metric | DB path | full RAM |
|---|---|---|
| 364-line corpus wall time | 18.85 s | 2.52 s |
| per line | 51.8 ms | 6.9 ms |
| speedup | | **7.48x** |
| heap | | 8.1 GB |
| load time | | 82 s |

The same machine's 16GB heap holds the dictionary and the analyzer with room
left over, so full-dictionary RAM serving no longer needs a larger host.

## Next targets

Residual DB traffic in the full-RAM configuration, by query shape:

- `SELECT * FROM kanji_text WHERE id = ?` (primary-key `get-dao` inside the
  conjugation parent walk) and the `kana_text` union in `get-kana-forms*`.
- `conj_source_reading` text lookups inside `best-kana-conj` /
  `best-kanji-conj`; already in RAM, just not wired at that call site.
- `find-word-with-pos` and `find-word-conj-of`, which query the text tables
  joined to `sense_prop` / `conjugation`.

Integer-backing `sense`, `gloss` and `sense_prop` is the other open item; it
would remove the compact layer entirely and cut the 8.1GB further.
