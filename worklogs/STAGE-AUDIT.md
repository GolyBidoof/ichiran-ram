# Stage audit: where one romanize call actually spends its time

Measured with `scripts/audit-stages.lisp` over the 382-line golden corpus on the
RAM path, warm, after a full warm-up pass. Reproduce with:

```sh
scripts/sbcl-wrapped --dynamic-space-size 14336 --non-interactive \
  --eval '(ql:quickload (list :ichiran :ichiran/cli :ichiran/ram) :silent t)' \
  --load scripts/audit-stages.lisp \
  --eval '(ichiran/conn:with-db nil (ichiran/serve-parallel:load-dictionary) (main))'
```

## The analysis path

| stage | ms/line | share | allocation |
| --- | --- | --- | --- |
| join-substring-words | 2.132 | 54% | 1561 kB/line |
| find-best-path | 0.590 | 15% | 881 kB/line |
| fill-segment-path | 0.068 | 2% | 25 kB/line |
| **romanize (plain text)** | **3.991** | | 1568 kB/line |
| romanize* (analysis) | 3.955 | | 1585 kB/line |

`join-substring-words` is where the time and the allocation are: candidate
generation, the suffix machinery and the segfilters. `find-best-path` is the
lattice search and is comparatively cheap. `fill-segment-path` is nearly free.

## The serving path, which is the one that matters

`romanize` returns plain text. What a JSON daemon actually runs is
`(jsown:to-json (ichiran:romanize* text :limit 5))`, and that is a very
different number:

| stage | ms/line | share of serving |
| --- | --- | --- |
| romanize* (the Japanese analysis) | 3.955 | **8.9%** |
| everything JSON | ~40-54 | **~91%** |

Split of the JSON half, measured per WORD-INFO on a single sentence:

| stage | per word-info |
| --- | --- |
| word-info-gloss-json (building the tree) | 3.04 ms |
| jsown:to-json (turning it into text) | 1.43 ms |

That is about 4.5 ms per word-info, and a sentence carries roughly ten of them,
which lands on the ~44-54 ms/line seen end to end. Neither call is cached: the
second `word-info-gloss-json` on the same object costs the same 2.94 ms as the
first.

## What this means

The optimization work in this session attacked startup and the plain-text path.
Both are now small next to the JSON layer, which nobody has touched:

- startup is 1.25s on a baked core, and the dictionary is 2.9s on the snapshot
  path, against 44 ms per line of serving;
- the analysis is 3.955 ms/line, which is 8.9% of what a JSON server does.

A correction that follows from this: the 11-15x figures in
`worklogs/PERF-RESULTS.md` are for `romanize`, the plain-text path. They are
real, but a JSON-serving deployment spends about nine tenths of its time
somewhere those benchmarks never measured, and that cost is largely independent
of whether the dictionary came from RAM or PostgreSQL. The RAM advantage on the
full serving path is therefore much smaller than 13x, and has not been measured.

## Remaining database queries on the RAM path

The RAM path is not fully database free. `dict-grammar.lisp` registers
"unique-only" predicates for suffixes that run raw SQL against `entry` and
`conjugation`, and these bypass the in-RAM tables:

- line 510, the `:sa` suffix: `SELECT seq FROM entry WHERE seq IN (...) AND root_p`
- line 548: `SELECT ... FROM conjugation ...`

They are reached from `match-unique` inside `find-word-suffix`, so they fire for
ordinary input: `おかえりなさい` reaches the `:sa` one. This is also why the
sense-snapshot bug earlier in the project produced correct output at eight times
the cost: database fallbacks that return the right answers are invisible to an
output-comparing gate. Porting these two predicates to the in-RAM entry and
conjugation tables is what would make the claim true.

## Ranked suggestions

1. **Attack the JSON layer.** It is ~91% of serving time. Two parts, both
   smaller than they sound:
   - the gloss structure for a dictionary word is static and does not depend on
     the sentence. Building it per occurrence, per request, is the largest
     single cost in the program. It can be precomputed per sense at dictionary
     build time and spliced.
   - building a jsown alist tree and then walking it to produce text is two
     passes and a per-node allocation. A single-pass encoder writing straight
     to the output stream removes the tree and the generic dispatch.
2. **Port the two remaining suffix predicates** to the RAM tables, so the
   database-free claim is actually true.
3. **`join-substring-words` is 54% of the analysis** and allocates 1.5 MB per
   line. This is the candidate-generation and segfilter work the hotpath audit
   already flagged as 43% of allocation. An FST over the reading space is the
   real fix; it was shelved earlier and remains the largest algorithmic option.
4. Startup is no longer worth much: 1.25s on a core, and the remaining pieces
   are under a second each.
