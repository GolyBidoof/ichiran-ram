# Ichiran RAM

**The entire Japanese dictionary in RAM: about 40 times faster, and no database
running.**

[![Output](https://img.shields.io/badge/output-byte--identical-brightgreen)](#verification)
[![Tests](https://img.shields.io/badge/tests-820%20assertions%2C%200%20failed-brightgreen)](#verification)
[![Per line](https://img.shields.io/badge/per%20line-51.7ms%20to%201.27ms-brightgreen)](#the-numbers)
[![Queries](https://img.shields.io/badge/SQL%20queries%20per%20line-17.12%20to%200.28-brightgreen)](#the-numbers)
[![Database](https://img.shields.io/badge/database-not%20required-blue)](#option-c-turn-on-the-fast-path)
[![License](https://img.shields.io/badge/license-MIT-blue)](LICENSE)

Ichiran is the Japanese tokenizer and morphological analyzer behind
[ichi.moe](http://ichi.moe). Hand it unbroken Japanese and it decides where the
words are, then gives you the reading, the furigana, the romaji and the JMdict
gloss for every piece. Segmentation is the hard part, and ichiran is good at it.

It has one expensive habit. Every word it looks at becomes questions for
PostgreSQL, asked one after another while you wait: this reading, that
conjugation, these senses, those glosses. A sentence costs thousands of queries.
A subtitle file costs millions. That is what makes ichiran feel slow, and it says
nothing about the analysis. It is about where the dictionary lives.

This fork moves the dictionary. The same JMdict tables load into 8.1GB of RAM
once, the analyzer reads them from memory, and the database stops mattering. Bake
it and you get a single 469MB file that answers in about a second with no
PostgreSQL, no connection string, no server and no network. The output is
byte-identical to the database path, and three gates check that on every commit.

Upstream project: [tshatrov/ichiran](https://github.com/tshatrov/ichiran) by
Timofei Shatrov. This fork is maintained by
[GolyBidoof](https://github.com/GolyBidoof). Both are MIT licensed.

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

Same machine, `romanize` per line, best of three runs. The middle column is the
snapshot, the third is the same dictionary baked into one file. See
[Verification](#verification) for how the equality is checked, and
[docs/PERFORMANCE-HISTORY.md](docs/PERFORMANCE-HISTORY.md) for every measurement
along with the ideas that were tried and rejected.

### On real text

Four samples of real Japanese, none of them ours. They are described rather than
named, because they are copyrighted and deliberately absent from this repository.
Each row is a whole sample in one process, so the totals are what you would
actually sit and wait for.

| Sample | Lines | Characters | Database path | RAM snapshot | Baked core |
| --- | --- | --- | --- | --- | --- |
| visual-novel prologue | 82 | 1,915 | 6.7 s (81.4 ms) | **0.16 s** (1.98 ms) | 0.16 s (1.97 ms) |
| manga-magazine sample | 7,278 | 55,912 | about 2.3 min | 3.0 s (0.41 ms) | **2.7 s** (0.38 ms) |
| novel-prologue sample | 1,324 | 34,147 | about 2 min | **3.0 s** (2.29 ms) | 3.2 s (2.44 ms) |
| magazine sample | 18,939 | 335,008 | about 17 min | 25.3 s (1.33 ms) | **24.6 s** (1.30 ms) |

The database totals for the last three are scaled by characters from measured
slices, because nobody wants to wait seventeen minutes to publish a table. The
slices were 2,000, 400 and 2,905 lines at 19.0, 95.3 and 55.1 ms per line.

Ten worker threads take the magazine sample to 2.3 seconds of analysis, 0.121 ms
per line, 12.8x. End to end, the parallel server returns all 18,939 lines in 5.8
seconds including startup and writing the JSON. Nothing analyzed came back empty;
the 476 blank lines in that output are the 473 blank lines in the input.

We also ran unmodified upstream ichiran against the same database on the same
text, because a comparison you cannot check is just marketing. **49.77 against
49.76 ms** per line on the golden corpus, **87.67 against 81.38** on the
visual-novel prologue, **16.68 against 19.66** on a manga slice, **54.84 against
52.59** on a magazine slice. Dead even, in both directions. The database path is
not where the speed comes from. The RAM layer is, and you are welcome to
disbelieve this table until you rerun it.

Per-line cost tracks line length more than corpus size: the manga sample averages
7.7 characters per line against 17.7 for the magazine, which is most of the gap
between 0.38 and 1.30 ms per line on the core.

## What you get

**A corpus that used to cost a coffee break now costs a blink.** Those 18,939
lines take about 17 minutes on the database path. Through the parallel RAM server
they take 2.3 seconds, and every analyzed line came back with an answer.

**Nothing left to keep alive.** No PostgreSQL, no connection strings, no
migrations, no vacuum, no port to open. One 469MB file, read once, answering for
as long as the process lives. Drop the core into a container and nothing else
needs to run beside it.

**A way to check that the database is really gone.** The setup script finishes by
pointing the core at a database with a deliberately wrong password. If the
romanization still comes back, the core is genuinely self-contained. That test
runs at the end of every build, and it is why the numbers here can be trusted
without taking anyone's word for it.

**The whole dictionary, offline.** All of JMdict fits in 8.1GB of heap, which a
16GB laptop carries comfortably. Useful on trains, on planes, and on the machine
that has no database server and never will.

**Your existing tools, just faster.** A text per line in, a romanization per line
out, in order, dictionary already warm. Subtitle pipelines, OCR output, Anki card
mining, corpus work, and the preprocessing pass before Japanese goes into a
language model. All of it used to be paced by dictionary round trips.

**And no migration.** If you already run ichiran, the command does not change.
Same binary name, same flags, same Lisp API, same output. Run the setup and the
plain command starts answering from RAM. Every fast path sits behind a flag that
defaults to off, so a stock checkout still talks to PostgreSQL and still matches
the recorded baseline.

## Contents

- [The numbers](#the-numbers)
- [What you get](#what-you-get)
- [Quick start](#quick-start)
  - [Option A: Docker, nothing to install](#option-a-docker-nothing-to-install)
  - [Option B: local SBCL and PostgreSQL](#option-b-local-sbcl-and-postgresql)
  - [Option C: turn on the fast path](#option-c-turn-on-the-fast-path)
- [Using it](#using-it)
- [How this differs from upstream ichiran](#how-this-differs-from-upstream-ichiran)
- [Migrating from ichiran](#migrating-from-ichiran)
- [Verification](#verification)
- [Requirements and what it costs](#requirements-and-what-it-costs)
- [Troubleshooting](#troubleshooting)
- [Benchmarks](#benchmarks)
- [Documentation](#documentation)
- [Credits and license](#credits-and-license)

## Quick start

### Option A: Docker, nothing to install

The fastest way to a working install. It downloads a prepared JMdictDB dump, so
you do not need to build the dictionary yourself.

```sh
git clone https://github.com/GolyBidoof/ichiran-ram.git
cd ichiran-ram
docker compose build          # a few minutes the first time
docker compose up             # imports the database, then idles, ready for commands
```

The first `up` is the slow one: it restores a 4.7GB database. Watch it grow with
`du -h -d0 docker/pgdata` in another terminal. When it says "All set, awaiting
commands", you are ready:

```sh
docker exec -it ichiran-main-1 ichiran-cli -i "一覧は最高だぞ"   # CLI
docker exec -it ichiran-main-1 test-suite                        # test suite
docker exec -it ichiran-main-1 ichiran-sbcl                      # a Lisp REPL
```

Give Docker Desktop at least 8GB of memory before attempting
[Option C](#option-c-turn-on-the-fast-path) inside the container.

### Option B: local SBCL and PostgreSQL

Use this if you want ichiran inside your own Lisp, or if you want the fast path
on the same machine as the database.

1. Install **SBCL**, **[quicklisp](https://www.quicklisp.org/beta/)**, and
   **PostgreSQL 16**.
2. Put this checkout where ASDF can find it, for example:

   ```sh
   ln -s "$PWD" "$HOME/quicklisp/local-projects/ichiran"
   ```

3. Create `settings.lisp` from `settings.lisp.template` and fill in your
   database connection, or skip the file and use the environment variables
   `ICHIRAN_DB_NAME`, `ICHIRAN_DB_USER`, `ICHIRAN_DB_PASSWORD`, and
   `ICHIRAN_DB_HOST` (defaults: `jmdict`, `jmdict`, `password`, `localhost`).
4. Create the database, either from the [upstream dump](https://github.com/tshatrov/ichiran/releases)
   or from scratch:

   ```lisp
   (ql:quickload :ichiran)
   (ichiran/maintenance:full-init)          ; hours, or load a dump instead
   (ichiran/dict:init-suffixes t)           ; build the suffix cache, do not skip
   (ichiran/test:run-all-tests)             ; check the install
   ```

5. Run it:

   ```lisp
   (ichiran:romanize "一覧は最高だぞ" :with-info t)
   ```

The scripts in `scripts/` go through `scripts/sbcl-wrapped`, which keeps all
SBCL and quicklisp state inside the checkout (so nothing lands in `$HOME`). It
finds SBCL on your `PATH`, or you can point it at one with
`SBCL=/path/to/sbcl`. It looks for quicklisp in `local-env/quicklisp` first and
falls back to `~/quicklisp`.

### Option C: turn on the fast path

This is the reason the fork exists. One command builds everything, and it needs
a working database once, because that is where the dictionary comes from.

```sh
./scripts/ram-setup.sh
```

Wait for it to finish. It checks SBCL, quicklisp and your database, writes the
dictionary snapshots (`local-env/ichiran-int.snap`, 1.6GB, plus the senses),
bakes a serving core (`local-env/ichiran-serving.core`, 469MB), and then proves
the result works by romanizing a sentence with deliberately wrong database
credentials, so a silent fallback to PostgreSQL would fail the setup rather than
pass quietly. Expect a few minutes. Running it again reuses what is already
there and takes seconds, and `FORCE=1` rebuilds from scratch.

Afterwards the same commands you always used keep working, and quietly change
where the dictionary comes from. No flags, no environment variables, no
arguments:

```sh
./scripts/ichiran-cli -i "一覧は最高だぞ"       # the CLI, now from the core
./scripts/serve-system.sh                     # one text per line, parallel, no DB
```

The CLI prints which backend it chose on stderr, so you can always tell. Before
the setup it says PostgreSQL, after it says the core, and `ICHIRAN_BACKEND=db`
or `ICHIRAN_BACKEND=ram` forces either one.

Inside the docker container, run the setup from the repo directory there:

```sh
docker exec -it ichiran-main-1 bash
cd /root/quicklisp/local-projects/ichiran
./scripts/ram-setup.sh
```

It finds the `pg` service on its own when `localhost` is not reachable, so no
extra arguments are needed. After that,
`docker exec -it ichiran-main-1 ichiran-cli -i "text"` runs from the core.

If you would rather not bake a core at all, one earlier step gives you most of
the win: `./scripts/build-snapshot.sh` writes the snapshots, and
`./scripts/serve-snapshot.sh` serves from them. That boots in about 8.5 seconds
instead of about 1.3, and has the same per-line speed.

The servers read one text per line on stdin and write one result per line on
stdout, in the same order:

```sh
echo "一覧は最高だぞ" | ./scripts/serve-system.sh
./scripts/serve-system.sh < mytext.txt > romaji.txt
SERIAL=1 ./scripts/serve-system.sh     # single thread, for debugging
WORKERS=4 ./scripts/serve-system.sh    # default is one worker per core
./scripts/serve-snapshot.sh            # the snapshot path, same protocol
```

The server prints a line containing `{"ready":true}` when it is warm. Ignore
everything before that line: SBCL prints its banner to stdout, and it cannot be
suppressed when a core image is used. After the ready line, one input line gives
exactly one output line.

## Using it

**Command line.** Identical to upstream, plus one new flag.

```sh
ichiran-cli "一覧は最高だぞ"              # romanization plus word info
ichiran-cli -i "一覧は最高だぞ"           # the same, spelled out
ichiran-cli -f -l 5 "一覧は最高だぞ"      # full split as JSON, 5 alternatives
ichiran-cli -e '(+ 1 2)'                 # evaluate a Lisp expression
ichiran-cli --serve                      # persistent JSON daemon, see below
```

`--serve` is new in this fork. It reads sentences on stdin and writes one line
of JSON per sentence to stdout, keeping the dictionary load in one long-lived
process:

```sh
ichiran-cli --serve < sentences.txt > results.jsonl
```

**One command, two backends.** `scripts/ichiran-cli` is a dispatcher that takes
upstream's exact options. It uses PostgreSQL while no RAM dictionary exists, and
the baked core once one does, and prints its choice on stderr:

```sh
./scripts/ichiran-cli -i "一覧は最高だぞ"         # romanization plus word info
./scripts/ichiran-cli -f -l 5 "一覧は最高だぞ"    # full split as JSON
ICHIRAN_BACKEND=db  ./scripts/ichiran-cli "text"  # force the database
ICHIRAN_BACKEND=ram ./scripts/ichiran-cli "text"  # force the core
```

`scripts/ram-cli.sh` is the same interface with the core required, for when you
want that guarantee rather than a fallback. Commands that exist to build the
PostgreSQL dictionary (`full-init`, `load-jmdict`, `add-errata` and friends)
answer with what to do instead, because here the snapshot is the dictionary:

```sh
./scripts/ichiran-cli -e '(ichiran/maintenance:full-init)'
# ichiran-cli: that command builds the PostgreSQL dictionary, which is not needed here.
#   Set up RAM serving instead:   ./scripts/ram-setup.sh
#   Already did? Then you do not need this command at all. Serve text with:
#       ./scripts/serve-system.sh              # feed it lines, get results back
#       ./scripts/ram-cli.sh -i "text"         # or use this same CLI on the core
```

**Lisp API.** Unchanged. `ichiran:romanize`, `ichiran:romanize*`,
`ichiran:init-all-caches`, `ichiran/dict:init-suffixes`, and the rest keep their
names, arguments, and return values. See [cli.lisp](cli.lisp) and
[romanize.lisp](romanize.lisp).

**In your own process, opt in to RAM.** Load the extra system, load the layers,
then flip the flag:

```lisp
(ql:quickload :ichiran/ram)

(ichiran/conn:with-db nil
  (ichiran/memdict-compact:memdict-load-int :snapshot "local-env/ichiran-int.snap")
  (ichiran/memdict-compact:memdict-load-sense-snapshot
    "local-env/ichiran-sense.snap" :int-snapshot "local-env/ichiran-int.snap"))

(setf ichiran/dict::*memdict-p* t)        ; route hot lookups to RAM
(ichiran:romanize "こんにちは")
```

## How this differs from upstream ichiran

Everything upstream can do, it still does. The differences are additions.

| | Upstream ichiran | This fork |
| --- | --- | --- |
| Dictionary source | PostgreSQL on every lookup | PostgreSQL, or RAM, or a baked core |
| CLI commands | `ichiran-cli`, `-i`, `-f`, `-l`, `-e` | same, plus `--serve` |
| Lisp API | `romanize`, `romanize*`, ... | same, unchanged |
| ASDF systems | `:ichiran`, `:ichiran/cli` | same, plus `:ichiran/ram` |
| Default behavior | database path | **the same database path** |
| Dependencies | quicklisp libraries | same, no new ones |
| Database schema | JMdictDB | unchanged, nothing added |
| Segmentation, scoring, hints, errata | upstream logic | unchanged logic, `dict.lisp` edited only to route lookups |
| Serving without a database | not possible | snapshot, or a baked core |
| Parallel serving | not provided | `WORKERS=N`, output stays in input order |
| Verification gates | test suite | test suite plus three parity gates |

The flags, all default off:

- `ichiran/dict::*memdict-p*` routes hot dictionary lookups to RAM.
- `ichiran/dict::*use-cache-p*` enables the per-worker memo caches.
- `ichiran/dict::*trie-p*` enables the optional prefix trie (off, and it was
  measured to be neutral to slower; see the history document).

If you never set those, you are running ichiran on the database path, exactly as
before.

## Migrating from ichiran

**Short answer: change nothing.** The commands and the API are the same. Move to
the fast path one step at a time, and stop wherever you like.

| What you run today | What you run after | Change |
| --- | --- | --- |
| `docker compose build`, `docker compose up` | identical | none |
| `ichiran-cli -i "text"` | identical | none |
| `(ichiran:romanize "text" :with-info t)` | identical | none |
| `(ichiran:romanize* "text" :limit 5)` | identical | none |
| `(ichiran/dict:init-suffixes t)` | identical | none |
| `(ichiran/test:run-all-tests)` | identical | none |
| `(ql:quickload :ichiran)` | identical | none |
| `ichiran-cli --serve` | new | added by this fork |
| `(ql:quickload :ichiran/ram)` | new | added by this fork |
| `./scripts/ichiran-cli -i "text"` | new path, same command | dispatcher: database before setup, core after it |
| `./scripts/ram-setup.sh` | new | one command: snapshots plus a serving core |
| `./scripts/ram-cli.sh -i "text"` | new | the CLI on the baked dictionary, no database |

Suggested order:

1. **Install as usual.** Point your existing setup at this checkout. Your tests
   and your output should be unchanged, because they are.
2. **Check the baseline.** `./scripts/parity.sh` should print `PARITY_OK`.
3. **Build and serve from RAM.** `./scripts/ram-setup.sh` writes the snapshots
   and a serving core into `local-env/`, which git ignores, and then proves the
   result works. It reads your database, once. Afterwards
   `./scripts/serve-system.sh` needs no arguments and no database.
4. **Compare, if you want the proof.** `./scripts/ram-parity.sh` runs the whole
   golden corpus through the RAM path and compares it byte for byte with the
   database baseline.

To roll back, stop loading `:ichiran/ram`, delete the files in `local-env/`, and
unset the flags. The database, the schema, and the upstream source files keep
working the way they always did.

If you have scripts that call ichiran in a loop, the biggest single win is
usually not the RAM dictionary but the process: boot one server and feed it
lines, instead of starting a fresh Lisp for every sentence.

## Verification

Every "same answers" claim in this file is checked three ways, and all three have
to pass before anything ships. This is the part of the project that gets the most
attention, because a fast wrong answer is worth nothing.

| Gate | Command | Passes when |
| --- | --- | --- |
| Unit and behavior tests | `./scripts/parity.sh` | prints `PARITY_OK` (820 assertions, 0 failures) |
| Database output baseline | `./scripts/golden-diff.sh` | prints `GOLDEN_DIFF_OK` |
| RAM output vs database baseline | `./scripts/ram-parity.sh` | prints `RAM_PARITY_OK` |

`ram-parity.sh` is the important one. It runs the whole golden corpus through
the RAM path and compares it byte for byte with
`data/golden-corpus-baseline.json`, which was produced by the database path. It
exists because the other gates cannot see the RAM code at all.

Each RAM load also checks itself and prints `MEMDICT-VERIFY-OK <table> ram=N
db=N`, comparing its row count against the database. A `VERIFY-FAIL` means the
load is corrupt. That gate exists because a paging bug once loaded 1.55M of 2.5M
rows in silence, and the analyzer answered anyway, with wrong answers.

One honest caveat: the database path is not fully deterministic on a single
knife-edge sentence, where two segmentations score almost identically. That is
an upstream property, not a RAM property, and it is why the gates compare
against a fixed baseline file instead of running the database twice.

## Requirements and what it costs

| | Minimum | Comfortable |
| --- | --- | --- |
| Database path only | 4GB RAM | 8GB |
| RAM snapshot | 10GB RAM | 16GB |
| Baked full core | 16GB RAM | 24GB |
| Disk, dictionary | 4.7GB | 5GB |
| Disk, snapshot | 1.6GB | |
| Disk, core | 469MB | |

Serving from RAM holds about 8.1GB of dictionary in the heap, so 16GB is the
practical floor for the full dictionary. `save-lisp-and-die` needs roughly twice
the dictionary size while writing a core, which is why baking wants headroom.

The trade is easy to state. The database path costs you a PostgreSQL server and a
long wait on every batch. The RAM path costs you 8.1GB of memory, and a 16GB
laptop pays that bill once and then stops noticing.

Build times on the reference machine (Apple Silicon): a few minutes for the
snapshot and a few minutes for a core, and neither needs to be repeated unless
the dictionary or the table layout changes.

The throughput benchmarks in the history document were taken on large samples of
third-party Japanese text. Those files are not distributed with this repository
and appear in no commit. Every harness takes a path from `CORPUS` and defaults to
`data/golden-corpus.txt`, which this project authors itself:

```sh
CORPUS=/path/to/your/text.txt ./scripts/bench-all.sh
```

## Troubleshooting

**`no core at local-env/...`** Build one first, or use `serve-snapshot.sh`, which
needs only the snapshot.

**Heap exhausted while loading or dumping.** Raise `--dynamic-space-size`. Pass
it through `scripts/sbcl-wrapped` rather than appending raw SBCL flags, and put it
before any `--eval` (SBCL requires runtime options first).

**`VERIFY-FAIL` during a load.** The load is corrupt. Call
`(ichiran/memdict-compact:memdict-reset)` and load again in a fresh process;
partial state from an earlier load in the same image does not clear itself.

**The server's first line is not JSON.** That is the SBCL banner. Wait for
`{"ready":true}` and ignore everything before it.

**Very slow first request, then fast.** Expected. The gloss caches fill on first
use. `scripts/warm-server.lisp` shows how to warm them at boot, which is what a
baked core does for you.

**One sentence romanizes differently from the database.** Re-run it. If it
reproduces, please report it with the sentence and both outputs; see the caveat
under [Verification](#verification).

## Benchmarks

The harnesses are in `scripts/`, they take their input path from `CORPUS`, and
the numbers they produced are written up in
[docs/PERFORMANCE-HISTORY.md](docs/PERFORMANCE-HISTORY.md) with the raw runs in
[worklogs/PERF-RESULTS.md](worklogs/PERF-RESULTS.md).

| Script | What it measures |
| --- | --- |
| `bench-all.sh` | wall time and per-line time, best of three, for database, RAM and core |
| `bench-vn.lisp` | one corpus through the database or the RAM layer, with query counts |
| `bench-lines.lisp` | per-line latency, worker skew, cache warming and collector cost |
| `bench-core.lisp` | the same measurement against a baked core |
| `audit-stages.lisp` | where a romanize call spends its time, stage by stage |
| `audit-calls.lisp` | per-function call counts over a real corpus |
| `warm.sh` | keeps one process warm, so a measurement costs seconds instead of a load |

```sh
CORPUS=/path/to/text.txt ./scripts/bench-all.sh
./scripts/warm.sh start
./scripts/warm.sh send '(time (ichiran:romanize "一覧は最高だぞ"))'
```

Two things worth knowing before comparing numbers. Cross-process timings on one
machine vary by five to six percent, so the harnesses interleave configurations
and report best and median rather than a single run. And a measurement that
changes fewer bytes allocated or fewer scanners compiled is more trustworthy than
one that changes a stopwatch reading.

## Documentation

| Document | What is in it |
| --- | --- |
| [docs/WHY-FORK.md](docs/WHY-FORK.md) | What this fork is for, and what it deliberately does not touch |
| [docs/RAM-DICTIONARY.md](docs/RAM-DICTIONARY.md) | The full guide: table gating, load order, memory per table, presets |
| [docs/PERFORMANCE-HISTORY.md](docs/PERFORMANCE-HISTORY.md) | Every improvement, why it helped, how much, and what was rejected |
| [docs/CODE-AUDIT.md](docs/CODE-AUDIT.md) | Where the code was restructured, and the verification behind it |
| [docs/seams.md](docs/seams.md) | The interface contract between upstream code and the RAM layer |
| [CHANGELOG.md](CHANGELOG.md) | Changes by release |
| [worklogs/](worklogs/) | Development session notes, including the benchmarks |

## Credits and license

Ichiran is by Timofei Shatrov, MIT licensed, and this fork keeps that license.
The in-RAM dictionary, the serving cores, the parallel server, and the
verification gates were built by GolyBidoof with DeepSeek V4 Flash.

Dictionary data comes from [JMdictDB](http://edrdg.org/~smg/) and is subject to
its own license. See [LICENSE](LICENSE).
