# Ichiran RAM

**The entire Japanese dictionary in RAM: about 40 times faster, and no database
running.**

[![Speed](https://img.shields.io/badge/speed-about%2040x-brightgreen)](#the-numbers)
[![Output](https://img.shields.io/badge/output-byte--identical-brightgreen)](#verification)
[![Tests](https://img.shields.io/badge/tests-820%20assertions%2C%200%20failed-brightgreen)](#verification)
[![Database](https://img.shields.io/badge/database-not%20required-blue)](#the-numbers)

Ichiran is the Japanese tokenizer and morphological analyzer behind
[ichi.moe](http://ichi.moe). Hand it unbroken Japanese and it decides where the
words are, then gives you the reading, the furigana, the romaji and the JMdict
gloss for every piece. It has one expensive habit: every word it looks at becomes
questions for PostgreSQL, asked one after another while you wait. A sentence
costs thousands of queries, a subtitle file costs millions, and that is what
makes ichiran feel slow.

This fork moves the dictionary into memory. The same JMdict tables load into
8.1GB of RAM once, and the database stops mattering. Bake it and you get a single
469MB file that answers in about a second with nothing else running. Output is
byte-identical to the database path, and three gates check that on every commit.

**The fast path is one command.** If ichiran already runs on your machine:

```sh
./scripts/ram-setup.sh
```

That writes the snapshots and bakes the core. From then on every command you
already use answers from RAM, with no flags, no configuration and no database.
Starting from nothing? The three steps below take you there.

## Get it running

Two steps: get ichiran working, then turn on the fast path.

### 1. Install ichiran

**Docker, nothing to install.** Downloads a prepared JMdictDB dump, so you never
build the dictionary yourself.

```sh
git clone https://github.com/GolyBidoof/ichiran-ram.git
cd ichiran-ram
docker compose build          # a few minutes the first time
docker compose up             # restores a 4.7GB database, then idles
```

The first `up` is the slow one. When it prints "All set, awaiting commands":

```sh
docker exec -it ichiran-main-1 ichiran-cli -i "一覧は最高だぞ"
docker exec -it ichiran-main-1 test-suite        # the test suite
docker exec -it ichiran-main-1 ichiran-sbcl      # a Lisp REPL
```

**Local SBCL and PostgreSQL.** Install SBCL, [quicklisp](https://www.quicklisp.org/beta/)
and PostgreSQL 16, then:

```sh
ln -s "$PWD" "$HOME/quicklisp/local-projects/ichiran"
cp settings.lisp.template settings.lisp   # fill in your database connection
```

Create the database from the [upstream dump](https://github.com/tshatrov/ichiran/releases)
(quick) or with `(ichiran/maintenance:full-init)` (hours), then run
`(ichiran/dict:init-suffixes t)` and `(ichiran/test:run-all-tests)`. The scripts
in `scripts/` go through `scripts/sbcl-wrapped`, which keeps all SBCL and
quicklisp state inside the checkout, finds SBCL on your `PATH` (or take
`SBCL=/path/to/sbcl`), and looks for quicklisp in `local-env/quicklisp` first.

### 2. Turn on the fast path

This is the point of the fork. One command, and everything after it serves from
RAM:

```sh
./scripts/ram-setup.sh
```

Wait for it to finish. It checks SBCL, quicklisp and your database, writes the
dictionary snapshots (1.6GB), bakes a serving core (469MB), and proves the result
works by romanizing a sentence with deliberately wrong database credentials, so a
silent fallback to PostgreSQL fails the setup instead of passing quietly. Expect
a few minutes. Running it again reuses what is there and takes seconds, and
`FORCE=1` rebuilds from scratch.

On a 16GB machine the full dictionary needs about 16GB of memory, so the setup
refuses and tells you to use `PRESET=lite`. Inside the docker container, run it
from the repo directory there and it finds the `pg` service by itself; give
Docker Desktop at least 8GB first.

### 3. Use it, from RAM

```sh
./scripts/ichiran-cli -i "一覧は最高だぞ"       # the same CLI, now from the core
./scripts/serve-system.sh                     # one text per line, parallel, no DB
```

Nothing else changes. No flags, no environment variables, no arguments. The CLI
prints which backend it chose on stderr, `ICHIRAN_BACKEND=db` or `=ram` forces
either one, and `docker exec -it ichiran-main-1 ichiran-cli -i "text"` works the
same as before. If you would rather not bake a core, `./scripts/build-snapshot.sh`
plus `./scripts/serve-snapshot.sh` gives the same per-line speed and boots in
about 8.5 seconds instead of about 1.3.

The servers read one text per line on stdin and write one result per line on
stdout, in the same order:

```sh
echo "一覧は最高だぞ" | ./scripts/serve-system.sh
./scripts/serve-system.sh < mytext.txt > romaji.txt
WORKERS=4 ./scripts/serve-system.sh      # default is one worker per core
SERIAL=1 ./scripts/serve-system.sh       # single thread, for debugging
```

The server prints a line containing `{"ready":true}` when it is warm. Ignore
everything before it: SBCL prints its banner to stdout and it cannot be suppressed
when a core image is used.

## What you get

**A corpus that used to cost a coffee break now costs a blink.** 18,939 lines of
Japanese take about 17 minutes on the database path and 2.3 seconds across 10
worker threads, with every analyzed line answered.

**Nothing left to keep alive.** No PostgreSQL, no connection strings, no
migrations, no vacuum, no port to open. One 469MB file, read once, answering for
as long as the process lives. Drop the core into a container and nothing else
needs to run beside it.

**The whole dictionary, offline.** All of JMdict fits in 8.1GB of heap, which a
16GB laptop carries comfortably. Useful on trains, on planes, and on the machine
that has no database server and never will.

**Your existing tools, just faster.** A text per line in, a romanization per line
out, in order, dictionary already warm. Subtitle pipelines, OCR output, Anki card
mining, corpus work, and the preprocessing pass before Japanese goes into a
language model. All of it used to be paced by dictionary round trips.

## The numbers

| | Database path | RAM snapshot | Baked core |
| --- | --- | --- | --- |
| One line, warm (382-line corpus) | 51.7 ms | **1.27 ms** | **1.27 ms** |
| One line, 10 worker threads (18,939 lines) | not measured | **0.121 ms** | 0.122 ms |
| SQL queries per line | 17.12 | **0.28** | **none on the serving path** |
| Whole corpus run, startup included | 88.5 s | 9.0 s | **3.3 s** |
| Ready to answer, before any input | about 69 s | about 8.5 s | **about 1.3 s** |
| Dictionary on disk | 4.7 GB database | 1.6 GB snapshot | **469 MB core** |
| Memory held while serving | the database's own | 8.1 GB | 8.1 GB |
| Output | baseline | byte-identical | byte-identical |

Four samples of real Japanese, none of them ours. They are described rather than
named, because they are copyrighted and deliberately absent from this repository.
Each row is a whole sample in one process, so the totals are what you would
actually wait for.

| Sample | Lines | Characters | Database path | RAM snapshot | Baked core |
| --- | --- | --- | --- | --- | --- |
| visual-novel prologue | 82 | 1,915 | 6.7 s (81.4 ms) | **0.16 s** (1.98 ms) | 0.16 s (1.97 ms) |
| manga-magazine sample | 7,278 | 55,912 | about 2.3 min | 3.0 s (0.41 ms) | **2.7 s** (0.38 ms) |
| novel-prologue sample | 1,324 | 34,147 | about 2 min | **3.0 s** (2.29 ms) | 3.2 s (2.44 ms) |
| magazine sample | 18,939 | 335,008 | about 17 min | 25.3 s (1.33 ms) | **24.6 s** (1.30 ms) |

The database totals for the last three are scaled by characters from measured
slices, because nobody wants to wait seventeen minutes to publish a table. Ten
worker threads take the magazine sample to 2.3 seconds of analysis, 12.8x, and
the parallel server returns all 18,939 lines in 5.8 seconds end to end including
startup and writing the JSON. Nothing analyzed came back empty.

We also ran unmodified upstream ichiran against the same database on the same
text, because a comparison you cannot check is just marketing. **49.77 against
49.76 ms** per line on the golden corpus, **87.67 against 81.38** on the
visual-novel prologue, **16.68 against 19.66** on a manga slice, **54.84 against
52.59** on a magazine slice. Dead even, in both directions. The database path is
not where the speed comes from, the RAM layer is, and you are welcome to
disbelieve all of this until you rerun it. Every measurement, including the ideas
that were rejected, is in [docs/PERFORMANCE-HISTORY.md](docs/PERFORMANCE-HISTORY.md).

## Using it

The CLI is upstream's, unchanged, plus one new flag:

| Command | What it does |
| --- | --- |
| `ichiran-cli "text"` | romanization plus word info |
| `ichiran-cli -i "text"` | the same, spelled out |
| `ichiran-cli -f -l 5 "text"` | full split as JSON, 5 alternatives |
| `ichiran-cli -e '(+ 1 2)'` | evaluate a Lisp expression |
| `ichiran-cli --serve` | new here: persistent JSON daemon on stdin |
| `./scripts/ichiran-cli ...` | the same CLI, routed to the core once built |
| `./scripts/ram-cli.sh ...` | the same, with the core required rather than preferred |

**Lisp API.** Unchanged. `ichiran:romanize`, `ichiran:romanize*`,
`ichiran:init-all-caches`, `ichiran/dict:init-suffixes` and the rest keep their
names, arguments and return values. To opt in from your own process:

```lisp
(ql:quickload :ichiran/ram)
(ichiran/conn:with-db nil
  (ichiran/memdict-compact:memdict-load-int :snapshot "local-env/ichiran-int.snap")
  (ichiran/memdict-compact:memdict-load-sense-snapshot
    "local-env/ichiran-sense.snap" :int-snapshot "local-env/ichiran-int.snap"))
(setf ichiran/dict::*memdict-p* t)        ; route hot lookups to RAM
(ichiran:romanize "こんにちは")
```

## Upgrading from ichiran

**Short answer: change nothing.** The commands, the flags and the API are the
same, and every fast path sits behind a flag that defaults to off, so a stock
checkout still talks to PostgreSQL and still matches the recorded baseline.

| What you run today | After | Change |
| --- | --- | --- |
| `docker compose build`, `docker compose up` | identical | none |
| `ichiran-cli -i "text"` | identical | none |
| `(ichiran:romanize "text" :with-info t)` | identical | none |
| `(ichiran/dict:init-suffixes t)`, `(ichiran/test:run-all-tests)` | identical | none |
| `(ql:quickload :ichiran)` | identical | none |
| `./scripts/ram-setup.sh` | new | one command: snapshots plus a serving core |
| `ichiran-cli --serve` | new | added by this fork |
| `(ql:quickload :ichiran/ram)` | new | added by this fork |

The three flags, all default off: `ichiran/dict::*memdict-p*` routes hot lookups
to RAM, `*use-cache-p*` enables per-worker memo caches, and `*trie-p*` enables the
optional prefix trie (measured neutral to slower, so leave it). To roll back,
stop loading `:ichiran/ram`, delete `local-env/` and unset the flags. The
database, the schema and the upstream sources keep working as they always did.

If you call ichiran in a loop, the biggest win is often not the dictionary but the
process: boot one server and feed it lines instead of starting a fresh Lisp for
every sentence. Commands whose only job is building the PostgreSQL dictionary
(`full-init`, `load-jmdict`, `add-errata`) answer with what to do instead,
because here the snapshot is the dictionary.

## Verification

Every "same answers" claim here is checked three ways, and all three have to pass
before anything ships, because a fast wrong answer is worth nothing.

| Gate | Command | Passes when |
| --- | --- | --- |
| Unit and behavior tests | `./scripts/parity.sh` | prints `PARITY_OK` (820 assertions, 0 failures) |
| Database output baseline | `./scripts/golden-diff.sh` | prints `GOLDEN_DIFF_OK` |
| RAM output vs database baseline | `./scripts/ram-parity.sh` | prints `RAM_PARITY_OK` |

`ram-parity.sh` is the important one: it runs the whole golden corpus through the
RAM path and compares it byte for byte with a baseline produced by the database
path, because the other gates cannot see the RAM code at all. Each RAM load also
prints `MEMDICT-VERIFY-OK <table> ram=N db=N` to check its row counts; that gate
exists because a paging bug once loaded 1.55M of 2.5M rows in silence and the
analyzer answered anyway, with wrong answers.

One honest caveat: the database path is not fully deterministic on a single
knife-edge sentence where two segmentations score almost identically. That is an
upstream property, not a RAM property, and it is why the gates compare against a
fixed baseline file rather than running the database twice.

## Requirements

| | Minimum | Comfortable |
| --- | --- | --- |
| Database path only | 4GB RAM | 8GB |
| RAM snapshot | 10GB RAM | 16GB |
| Baked full core | 16GB RAM | 24GB |
| Disk, dictionary | 4.7GB | 5GB |
| Disk, snapshot | 1.6GB | |
| Disk, core | 469MB | |

Serving from RAM holds about 8.1GB of dictionary in the heap, so 16GB is the
practical floor for the full dictionary, and `save-lisp-and-die` needs roughly
twice the dictionary size while writing a core. The trade is easy to state: the
database path costs you a PostgreSQL server and a long wait on every batch, the
RAM path costs you 8.1GB. Build times are a few minutes for the snapshot and a
few minutes for a core, and neither repeats unless the dictionary or the table
layout changes.

## Troubleshooting

**`no core at local-env/...`** Build one first, or use `serve-snapshot.sh`, which
needs only the snapshot.

**Heap exhausted while loading or dumping.** Raise `--dynamic-space-size` through
`scripts/sbcl-wrapped`, before any `--eval`, since SBCL requires runtime options
first.

**`VERIFY-FAIL` during a load.** The load is corrupt. Call
`(ichiran/memdict-compact:memdict-reset)` and load again in a fresh process;
partial state from an earlier load in the same image does not clear itself.

**The server's first line is not JSON.** That is the SBCL banner. Wait for
`{"ready":true}`.

**Very slow first request, then fast.** Expected. The gloss caches fill on first
use; a baked core does that at boot.

**One sentence romanizes differently from the database.** Re-run it, and if it
reproduces, report it with the sentence and both outputs. The caveat is under
[Verification](#verification).

## Going deeper

| Document | What is in it |
| --- | --- |
| [docs/WHY-FORK.md](docs/WHY-FORK.md) | What this fork is for, and what it deliberately does not touch |
| [docs/RAM-DICTIONARY.md](docs/RAM-DICTIONARY.md) | The full guide: table gating, load order, memory per table, presets |
| [docs/PERFORMANCE-HISTORY.md](docs/PERFORMANCE-HISTORY.md) | Every improvement, why it helped, how much, and what was rejected |
| [docs/CODE-AUDIT.md](docs/CODE-AUDIT.md) | Where the code was restructured, and the verification behind it |
| [docs/seams.md](docs/seams.md) | The interface contract between upstream code and the RAM layer |
| [worklogs/PERF-RESULTS.md](worklogs/PERF-RESULTS.md) | Raw benchmark runs, including the two ideas that were thrown away |
| [CHANGELOG.md](CHANGELOG.md) | Changes by release |

The harnesses are in `scripts/` and take their input path from `CORPUS`:
`bench-all.sh` (all three backends, best of three), `bench-lines.lisp` (per-line
latency, worker skew, cache warming, collector cost), `audit-stages.lisp` (where a
romanize call spends its time) and `warm.sh` (keeps one process warm, so a
measurement costs seconds instead of a load).

```sh
CORPUS=/path/to/your/text.txt ./scripts/bench-all.sh
```

## Credits and license

Ichiran is by Timofei Shatrov, MIT licensed, and this fork keeps that license.
The in-RAM dictionary, the serving cores, the parallel server, and the
verification gates were built by GolyBidoof with DeepSeek V4 Flash.

Dictionary data comes from [JMdictDB](http://edrdg.org/~smg/) and is subject to
its own license. See [LICENSE](LICENSE).
