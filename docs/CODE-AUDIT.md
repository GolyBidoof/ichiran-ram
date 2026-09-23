# Code audit before release

Why this exists: the performance work landed in a hurry, and most of it is new
code rather than upstream code. This is a measurement of that code's shape, the
changes that followed from the measurement, and the things deliberately left
alone with the reason for leaving them.

The audit covers the fork's own sources: `src/memdict-compact.lisp`,
`src/memdict-int.lisp`, `src/int-snapshot.lisp`, `src/sense-snapshot.lisp`,
`src/serve-parallel.lisp`, `src/memdict-compact-shims.lisp` and `src/trie.lisp`,
plus the small edits made to upstream `dict.lisp` and `characters.lisp`. Upstream
code is otherwise untouched on purpose: this is a fork, and gratuitous changes to
upstream files make future rebases expensive.

## Method

Function spans were extracted mechanically (paren-balanced scan over each file)
rather than judged by eye, so the numbers below are reproducible:

- 253 functions across those files, median 6 lines, 12 longer than 40 lines.
- Every one of those 12 is a loader, that is, build-time code that runs once
  when the snapshot or the serving core is built, not code on the serving path.
- 4 separate copies of the same string-interning helper.
- 2 hand-written copies of the same (key, rank) order computation.
- 4 inline freeze lambdas in the same loader.
- 1 `TODO` in the whole tree, in upstream `dict.lisp`.
- No tracked scratch files, logs, cores or backups.

The distribution matters: a codebase with a median function length of 6 lines
does not have a general decomposition problem, so the response was not a
wholesale rewrite. The concentration of long functions in build-time loaders,
and the duplicated helpers inside them, is the actual finding.

## Changes in this pass

All of the following is pure relocation and naming; no serving behaviour
changed.

| Change | Effect |
| --- | --- |
| `int-pool-string` | Replaces 4 identical copies (int-load-text, entry, conj-prop, csr) |
| `freeze-u32-vector`, `freeze-i32-vector`, `freeze-u8-vector`, `freeze-generic-vector` | The 4 inline lambdas, now named and reusable |
| `int-index-order` | One implementation of the text-major and seq-major index, which were the same computation written twice |
| `int-text-physical-ranks` | The ctid rank query, out of `int-load-text`, with its rationale in the docstring |
| `int-load-text` | 175 lines to 107 |

`src/memdict-int.lisp` grew from 951 to 969 lines. That is the honest trade: the
file is slightly longer because shared helpers have real docstrings, while the
duplication is gone and the longest function lost 68 lines. Line count was never
the problem, duplication was.

## Comments: what was removed, and what was kept

Comments that restate the code were deleted, and the code was renamed until it
said the same thing: `int-pool-string`, `freeze-u32-vector`, `int-index-order`,
`text-order-by-string<`, `int-text-physical-ranks`, and locals named
`row-count`, `distinct-texts`, `text-id` and `row` instead of `n`, `nt`, `ti`
and `pl`. Internal milestone tags (`R5`, `R6b`, `R7`, `R8/Tier 0`) were stripped
from the comments and headers, since they reference a plan document rather than
the code and mean nothing to a reader arriving later.

Comment lines fell from 67 to 47 in `src/memdict-int.lisp`, and from 126 to 119
in `src/memdict-compact.lisp`.

What was kept are comments that record a measured constraint which the code
cannot express by itself, and each one is a regression that already happened
once:

- Row order. The database selects with no `ORDER BY`, so Postgres returns ctid
  order, and the analyzer's stable sort makes that order visible. Ranking by id
  changed 72 of 364 golden lines.
- Three-state `neg`/`fml` flags. Collapsing SQL `NULL` into true changed 190 of
  364 golden lines.
- `ORDER BY` on a unique key during a chunked load. Without it the pages overlap
  and rows vanish: `entry` stopped at 1.55M of 2.5M rows, silently.
- Copy-on-return. Returning aliased rows let a compound seq-list leak into an
  `IN` query across sentences.
- Why the snapshot loader skips verification, and why the first-character index
  is built at registration rather than at lookup.

Deleting those would trade a shorter file for the exact class of regression the
parity rule forbids, so they stay. Anyone who wants them gone anyway should know
that the knowledge then lives only in `worklogs/` and in these commit messages.

Still carrying their original comment density, and the next candidates for the
same treatment: `src/serve-parallel.lisp` (20% of lines), `src/memdict-compact-shims.lisp`
(20%), `src/int-snapshot.lisp` (13%), `src/sense-snapshot.lisp` (12%) and
`src/trie.lisp` (24%, and a deletion candidate in its own right).

## Verification

Serving-path changes are covered by `scripts/ram-parity.sh`, which compares the
RAM path against the database baseline over the golden corpus. Build-time code is
not covered by that gate, because the parity harness reads the snapshot rather
than rebuilding it, so the loaders needed their own check.

`scripts/build-snapshot.sh` was run with the refactored loaders into a temporary
path, then compared against the artifact built by the previous revision:

- integer snapshot: 1,723,911,603 bytes, identical size, and only the build
  stamp differs (4 bytes on the first run, 5 on a later one, depending on how
  many of the stamp's digits changed).
- sense snapshot: 26,923,563 bytes, identical size, the **same bytes**.
- Those bytes are the 10-digit universal-time build stamp in the header
  (`*build-stamp*` in `src/int-snapshot.lisp`), at offsets 24 to 28. The sense
  snapshot is built by unmodified code and differs in exactly the same place,
  which confirms the field rather than assuming it.
- Everything else in both files, including all table payloads, is byte-identical.

`RAM_PARITY_OK` also passes after the change, and the compile notes were compared
against the pre-refactor file: 4 notes before, the same 4 after, all of them
benign forward references within the file.

One bug was caught by this and only by this: `ranks` is a plain array, not a
fill-pointer vector, so a first version of `freeze-u32-vector` that used
`(fill-pointer v)` failed at build time. `length` returns the fill pointer when
there is one and the array length otherwise, which is the semantics the original
inline lambdas had.

## Left alone, with reasons

These are recommendations rather than oversights.

1. **`src/memdict-compact.lisp` is 1366 lines.** It carries four concerns: the
   compact structs and index hash tables, the loader, the R5 RAM lookups that
   mirror the analyzer's SQL, and the R6 residual-query helpers. The seams exist
   and are marked, and a split into data model, loader and query layers is the
   obvious next step. It is not done here because the fork's file list appears in
   six places (`build-image.sh`, `build-snapshot.sh`, `serve-snapshot.sh`,
   `ram-parity.sh`, `bench-config.lisp`, `tests.lisp`), so a split means touching
   all six, and that deserves to be a change of its own rather than a footnote to
   this one.
2. **The load-order list itself is duplicated across those six scripts.** The
   lists legitimately differ by context (a snapshot build is not a serving core),
   so one shared manifest is not a drop-in. The realistic fix is a documented
   canonical order plus a single loader list for the full serving stack.
3. **`src/trie.lisp` and its hooks.** The baked prefix trie was implemented,
   measured and rejected: it builds correctly (8,411,392 texts, 13,303,350
   nodes) but is neutral to slower, because candidate windows are nearly all
   valid prefixes. It is off by default behind `TRIE_TABLES` and costs nothing at
   runtime. It is a reasonable deletion candidate before a release if the
   experiment is not going to be revisited; that is a product call, so it is
   flagged rather than done.
4. **The remaining loaders** (`memdict-load` at 127 lines, `int-load-conj-prop`
   at 66, `sense-layer-install` at 65, and the rest). They are linear build-time
   procedures with unusually good comments explaining why each ordering matters.
   They read fine; the two worst offenders were addressed. Splitting them further
   would add indirection without removing duplication.
5. **Upstream `dict.lisp` and `characters.lisp`.** The edits there are kept
   minimal and commented, so the fork stays rebasable. The two performance fixes
   in `characters.lisp` (compiling the character-class patterns once) and
   `src/memdict-compact.lisp` (not downcasing a table name per lookup) are the
   only changes to upstream behaviour-bearing files, and both were verified
   against the database baseline.

## Release checklist

- `scripts/ram-parity.sh` exits 0 with no database running.
- `scripts/golden-diff.sh` reports no drift against the golden baseline.
- `(ichiran/test:run-all-tests)` passes.
- `scripts/build-snapshot.sh` output matches the previous artifact except the
  build stamp.
- `scripts/bench-all.sh` shows no regression on the three small corpora.
