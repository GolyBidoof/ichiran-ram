# Ichiran RAM

The whole JMdict dictionary in memory. Same output as upstream, no PostgreSQL,
about 40 times faster on real text.

[![Speed](https://img.shields.io/badge/speed-about%2040x-brightgreen)](#the-numbers)
[![Output](https://img.shields.io/badge/output-byte--identical-brightgreen)](#verification)
[![Tests](https://img.shields.io/badge/tests-820%20assertions%2C%200%20failed-brightgreen)](#verification)
[![Database](https://img.shields.io/badge/database-not%20required-blue)](#the-numbers)

Ichiran is the Japanese tokenizer and morphological analyzer behind
[ichi.moe](http://ichi.moe). Give it unbroken Japanese and it decides where the
words are, then returns the reading, the furigana, the romaji and the JMdict gloss
for each piece. Upstream asks PostgreSQL about every word, one query after
another, so a sentence costs thousands of queries and a subtitle file costs
millions. That is where the time goes.

This fork loads the same tables into 8.1GB of memory once, after which the
database is not involved. It is the same ichiran, the same commands and the same
output, byte for byte, checked by three gates on every commit.

```sh
git clone https://github.com/GolyBidoof/ichiran-ram.git
cd ichiran-ram
./scripts/ram-setup.sh
```

One command, and it needs no database. It fetches or builds the dictionary, bakes
a 469MB serving core, and checks the result by romanizing a sentence. From then on
every ichiran command answers from RAM, with no flags, no environment variables
and nothing else running. The rest of this file covers what that command does,
what the numbers are, and how the output is verified.

## Setup

The command above does all of this. It installs quicklisp if you do not have it,
downloads the published dictionary (1.9GB, SHA256 checked), bakes a serving core,
and smoke-tests it by romanizing a sentence. Expect a few minutes the first time; running it again reuses everything
and takes seconds, and `FORCE=1` rebuilds from scratch.

Then, from RAM, with nothing else running:

```sh
./scripts/ichiran-cli -i "一覧は最高だぞ"             # one sentence
echo "日本語のテキスト" | ./scripts/serve-system.sh   # one text per line, in parallel
./scripts/serve-system.sh < mytext.txt > romaji.txt   # the same, from a file
WORKERS=4 ./scripts/serve-system.sh                   # default is one worker per core
```

**Requirements: SBCL and curl.** About 16GB of RAM to bake the core and 8GB to
serve, 1.9GB of disk for the dictionary and 469MB more for the core. Nothing above
needs PostgreSQL. `./scripts/serve-snapshot.sh` serves straight from the snapshots
with no core at all, booting in about 8.5s instead of about 1.3s.

If the machine cannot hold the bake, take the prebuilt core:

```sh
./scripts/fetch-dictionary.sh --core
```

An SBCL core only loads on the platform it was built for, and that one is macOS
arm64 with SBCL 2.6.8. Anywhere else, fetch the portable snapshots and bake your
own; that needs no database either. Inside docker the same setup is one command,
and it finds the `pg` service by itself. Give Docker Desktop 8GB of memory first:

```sh
docker exec -it ichiran-main-1 bash -lc \
  'cd /root/quicklisp/local-projects/ichiran && ./scripts/ram-setup.sh'
```

The CLI prints which backend it chose on stderr, and `ICHIRAN_BACKEND=ram` pins it
to RAM. Inside the container `docker exec -it ichiran-main-1 ichiran-cli -i "text"`
answers from the core the same way, `test-suite` runs the test suite, and
`ichiran-sbcl` opens a Lisp REPL.

### If you want your own dictionary instead

This is the only part of the project that reads PostgreSQL. The published
dictionary is a JMdict snapshot, so building your own from a different one means
giving the build a database. Either let Docker fetch a prepared JMdictDB dump:

```sh
docker compose build          # a few minutes the first time
docker compose up             # restores a 4.7GB database once, then idles
```

The first `up` is the slow one, and it is done when it prints "All set, awaiting
commands". Or install PostgreSQL 16 yourself and point the build at it:

```sh
ln -s "$PWD" "$HOME/quicklisp/local-projects/ichiran"
cp settings.lisp.template settings.lisp   # the connection the build reads
```

Create the database from the [upstream dump](https://github.com/tshatrov/ichiran/releases)
(quick) or with `(ichiran/maintenance:full-init)` (hours), then run
`(ichiran/dict:init-suffixes t)`, which builds the suffix cache and must not be
skipped: the bake reads it. Then `./scripts/ram-setup.sh` writes the snapshots and
the core from that database, and it is not needed again afterwards.

Every script goes through `scripts/sbcl-wrapped`, which keeps SBCL and quicklisp
state inside the checkout, finds SBCL on your `PATH` (or take `SBCL=/path/to/sbcl`),
and looks for quicklisp in `local-env/quicklisp` first.

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

Use `./scripts/ichiran-cli`, or put `scripts/` on your `PATH`, because a bare
`ichiran-cli` binary is upstream's and goes straight to PostgreSQL. In the
container, `ichiran-cli` is already routed through the dispatcher for you.

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

**Short answer: change nothing in your code.** The commands, the flags and the
API are the same. Add `./scripts/ram-setup.sh` and those same commands start
answering from RAM. Every fast path sits behind a flag that defaults to off, so a
stock checkout still talks to PostgreSQL and still matches the recorded baseline,
which is what makes moving over safe rather than a leap of faith.

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

| Gate | Command | Needs a database | Passes when |
| --- | --- | --- | --- |
| RAM output vs database baseline | `./scripts/ram-parity.sh` | no | prints `RAM_PARITY_OK` |
| Unit and behavior tests | `./scripts/parity.sh` | yes | prints `PARITY_OK` (820 assertions, 0 failures) |
| Database output baseline | `./scripts/golden-diff.sh` | yes | prints `GOLDEN_DIFF_OK` |

`ram-parity.sh` is the primary gate and the only one a RAM-only install can run.
It pushes the whole golden corpus through the RAM path and compares it byte for
byte with a baseline produced by the database path. The other two drive the
analyzer against PostgreSQL by design, so with no database reachable they print
`PARITY_SKIPPED` or `GOLDEN_DIFF_SKIPPED` and exit 0 instead of failing. Nothing
passes silently: a skip says `SKIPPED`, which is a different word from `OK`.

Each RAM load also prints `MEMDICT-VERIFY-OK <table> ram=N db=N` to check its row
counts; that gate exists because a paging bug once loaded 1.55M of 2.5M rows in
silence and the analyzer answered anyway, with wrong answers.

**No database, checked rather than asserted.** Stop PostgreSQL, serve a corpus
through the core, and compare it against the same run with the database up. The
ready line reports `"db":false` and the output is byte-identical, which is how the
independence claim above was established, over the golden corpus and a 7,278-line
sample. Pointing the core at wrong credentials does *not* demonstrate this: the
connection is baked into the image and the environment is ignored, so a
wrong-password run only proves that the core answers.

One honest caveat: the database path is not fully deterministic on a single
knife-edge sentence where two segmentations score almost identically. That is an
upstream property, not a RAM property, and it is why the gates compare against a
fixed baseline file rather than running the database twice.

## Requirements

**Software: SBCL and curl.** The setup installs quicklisp for you. PostgreSQL 16
is needed only to build the dictionary from a database of your own, and Docker
only for the download-and-restore route to one.

| | Minimum | Comfortable |
| --- | --- | --- |
| Baked full core | 16GB RAM | 24GB |
| RAM snapshot | 10GB RAM | 16GB |
| Disk, dictionary | 1.7GB | 1.9GB while downloading |
| Disk, core | 469MB | |
| Building your own dictionary | 4GB RAM | 8GB |

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
