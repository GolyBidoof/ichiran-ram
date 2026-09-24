#!/bin/bash
# build-image.sh - R4: build a serving core image with the compact dict loaded.
#
# R4 minimal-core path: quickload :postmodern only (NO :ichiran - the
# decoupled memdict-compact depends only on postmodern), load the full compact
# dict ONCE into the clean heap, dump a core image. Serving from the core is
# DB-free for the dict-covered path (see serve-core.sh).
#
# Memory (verified on this Mac):
#   kana_text 3,079,757 rows  -> ~3.0 GB, kana-only core BUILDS (16GB heap ok)
#   kanji_text 5,331,635 rows -> +~4.1 GB (7.1 GB total), load OK but the
#     save-lisp-and-die dump exceeds 16GB on this machine -> kana-only is the
#     default; pass TABLES to build the full core on a bigger-heap host
#     (Linux x86-64 SBCL, 32GB+).
#
# Usage:
#   scripts/build-image.sh [--out local-env/ichiran-serving.core]
#   TABLES='"kana_text"' scripts/build-image.sh   # kana-only (default)
#   TABLES='"kana_text" "kanji_text"' scripts/build-image.sh  # full (needs 32GB+)
#   PRESET=lite scripts/build-image.sh  # kana+senses trio (~3.3GB dict, builds on 16GB)
#   PRESET=full scripts/build-image.sh  # all 9 tables compact (needs 32GB+ host)
#   PRESET=full-ram scripts/build-image.sh  # whole dict in ~8GB (integer layer
#                                           # + compact sense layer)
#   TRIE_TABLES='"kana_text"' scripts/build-image.sh  # + baked prefix trie
# DB connection (env overrides, defaults shown):
#   ICHIRAN_DB_NAME (default jmdict), ICHIRAN_DB_USER (default jmdict),
#   ICHIRAN_DB_PASSWORD (default password), ICHIRAN_DB_HOST (default localhost)
set -e
set -o pipefail  # the sbcl | tail pipeline must fail loudly, not print DONE
cd "$(dirname "$0")/.."
# Output path: `build-image.sh --out PATH`, bare `build-image.sh PATH`, or default.
OUT="local-env/ichiran-serving.core"
if [ "$1" = "--out" ] && [ -n "$2" ]; then OUT="$2"
elif [ -n "$1" ] && [ "${1#-}" = "$1" ]; then OUT="$1"; fi
# INT_TABLES are served by the memory-tight integer backend
# (src/memdict-int.lisp); TABLES are served by the compact hash loader.
# Splitting them this way is what makes the whole dictionary fit in ~8GB.
# PRESET overrides both when set.
case "${PRESET:-}" in
  lite) TABLES='"kana_text" "sense" "gloss" "sense_prop"' ;;
  kana) TABLES='"kana_text"' ;;
  full) TABLES='"kana_text" "kanji_text" "entry" "conjugation" "conj_prop" "conj_source_reading" "sense" "gloss" "sense_prop"' ;;
  full-ram)
    INT_TABLES='"kana_text" "kanji_text" "entry" "conjugation" "conj_prop" "conj_source_reading"'
    TABLES='"sense" "gloss" "sense_prop"' ;;
esac
TABLES="${TABLES:-\"kana_text\"}"
INT_TABLES="${INT_TABLES:-}"
TRIE_TABLES="${TRIE_TABLES:-}"
# SYSTEM=1: bake the full analyzer (:ichiran + shims, *memdict-p* on) into the
# image too - a single file that romanizes with no quickload and no DB for
# covered paths. Needs more heap (analyzer baseline + dict + dump headroom).
SYSTEM="${SYSTEM:-}"
DB_NAME="${ICHIRAN_DB_NAME:-jmdict}"
DB_USER="${ICHIRAN_DB_USER:-jmdict}"
DB_PASS="${ICHIRAN_DB_PASSWORD:-password}"
DB_HOST="${ICHIRAN_DB_HOST:-localhost}"
if [ -n "$TRIE_TABLES" ]; then
  TRIE_LISP="(ichiran/memdict-compact:memdict-build-trie :tables (list $TRIE_TABLES))"
else
  TRIE_LISP="(format t \"no baked trie (TRIE_TABLES empty)~%\")"
fi
if [ -n "$SYSTEM" ]; then
  SYSTEM_LISP='(ql:quickload :ichiran :silent t)'
  # serve-parallel has to be loaded here: it defines *dict-baked*, and the core
  # sets it so the warm server knows not to re-read the dictionary it already
  # contains.
  # The gloss JSON caches have to be sized here, because this script loads the
  # dictionary directly rather than through LOAD-DICTIONARY. Leaving it out
  # produced a core that served uncached, which the runtime masked by
  # initialising on first use but at the cost of first-request latency.
  # WARM-CACHES is not just a warm-up: it is what makes a baked core
  # database-free. The :is-arch cache is built by SQL, CALC-SCORE consults
  # it for every candidate through IS-ARCH, and nothing else ever
  # populates it. Without this a baked core needed a live PostgreSQL for
  # every score computation, and because DICT-SEGMENT is compiled with
  # (speed 3) the connecting caller was inlined away and the socket error
  # appeared to come from DICT-SEGMENT itself. Warming here also bakes the
  # suffix cache, so a core stops building that at runtime too. Both are
  # computed while the database is available, which at build time it is.
  # A trie is built below but nothing enabled it, so a core built with
  # TRIE_TABLES set carried a prefix index that trie-enabled-p always
  # rejected. Enable it only when a trie is actually being built.

# A bake with no database at all. The integer layer and the sense layer come from
# the snapshots instead of SQL, and the three derived sets that the snapshot
# format does not carry come from the bake extras. Only the full-ram preset is
# wired this way: the integer snapshot holds all six integer tables and ignores
# :tables, and the sense snapshot holds exactly sense, gloss and sense_prop.
# Anything else keeps reading PostgreSQL, because a partial load needs a source
# the snapshots do not have.
INT_SNAP="${ICHIRAN_INT_SNAP:-local-env/ichiran-int.snap}"
SENSE_SNAP="${ICHIRAN_SENSE_SNAP:-local-env/ichiran-sense.snap}"
EXTRAS_SNAP="${ICHIRAN_BAKE_SNAP:-local-env/ichiran-bake.snap}"
DBLESS_BAKE=0
if [ -n "$INT_TABLES" ] && [ -f "$INT_SNAP" ] && [ -f "$SENSE_SNAP" ] && [ -f "$EXTRAS_SNAP" ]; then
  DBLESS_BAKE=1
fi

if [ "$DBLESS_BAKE" = 1 ]; then
  echo "build-image.sh: no database needed (snapshots + bake extras present)" >&2
  INT_SOURCE_LISP=":snapshot \"$INT_SNAP\""
  SENSE_LOAD_LISP="(ichiran/memdict-compact:memdict-load-sense-snapshot \"$SENSE_SNAP\" :int-snapshot \"$INT_SNAP\")"
  # Sets the no-database state first, then installs the derived sets, so the warm
  # pass and the counters cache below both take their RAM paths.
  DBLESS_PRE_LISP="(setf ichiran/conn::*no-database* t) (ichiran/serve-parallel:load-bake-extras \"$EXTRAS_SNAP\")"
  RESTRICTED_LISP=""
else
  INT_SOURCE_LISP=":conn '(\"$DB_NAME\" \"$DB_USER\" \"$DB_PASS\" \"$DB_HOST\")"
  SENSE_LOAD_LISP="(ichiran/memdict-compact:memdict-load :conn '(\"$DB_NAME\" \"$DB_USER\" \"$DB_PASS\" \"$DB_HOST\") :chunk 100000 :tables (list $TABLES))"
  DBLESS_PRE_LISP=""
fi

  # RESTRICTED_READINGS is fetched from PostgreSQL at build time and baked,
  # so a core can serve restricted senses with no connection. The spec is
  # assembled here because SYSTEM_TAIL is single-quoted and cannot
  # interpolate the DB_* shell variables itself.
  if [ "$DBLESS_BAKE" != 1 ]; then
    RESTRICTED_LISP=" (ichiran/serve-parallel::load-restricted-readings :conn '(\"$DB_NAME\" \"$DB_USER\" \"$DB_PASS\" \"$DB_HOST\"))"
  fi
  TRIE_ENABLE=""
  if [ -n "$TRIE_TABLES" ]; then
    TRIE_ENABLE=' (setf ichiran/dict::*trie-p* t)'
  fi
  SYSTEM_TAIL='(load "src/memdict-compact-shims.lisp") (load "src/serve-parallel.lisp") (load "src/bake-extras.lisp") '"$DBLESS_PRE_LISP"' (setf ichiran/dict::*memdict-p* t) (setf ichiran/serve-parallel::*dict-baked* t) (ichiran/dict::gloss-json-cache-init) (ichiran/serve-parallel:warm-caches) (ignore-errors (ichiran/conn::ensure :counters))'"$TRIE_ENABLE""$RESTRICTED_LISP"
else
  SYSTEM_LISP='(format t "bare core (no analyzer baked in)~%")'
  SYSTEM_TAIL='(format t "no shims (bare core)~%")'
fi
SBCL_VER="$(scripts/sbcl-wrapped --version 2>/dev/null | head -1 || echo unknown)"
GIT_SHA="$(git rev-parse --short HEAD 2>/dev/null || echo unknown)"
mkdir -p local-env

BUILD_LISP="$(mktemp /tmp/build-serving.XXXXXXXX)" || {
  echo "BUILD_IMAGE_ERROR: mktemp failed"
  exit 2
}
trap 'rm -f "$BUILD_LISP"' EXIT INT TERM


cat > "$BUILD_LISP" <<EOF
(ql:quickload :postmodern :silent t)
$SYSTEM_LISP
(load "src/memdict-compact.lisp")
(load "src/memdict-int.lisp")
(load "src/trie.lisp")
;; The snapshot readers, after the compact layers whose packages they use. A
;; database-free bake reads the integer and sense layers through these.
(load "src/int-snapshot.lisp")
(load "src/sense-snapshot.lisp")
(in-package :cl-user)
(format t "~%== building serving core: loading integer dict layer (bare)...~%")
(when (plusp (length (list $INT_TABLES)))
  (multiple-value-bind (bytes sizes)
      (ichiran/memdict-compact:memdict-load-int
       $INT_SOURCE_LISP
       :chunk 200000
       :tables (list $INT_TABLES))
    (declare (ignore sizes))
    (format t "integer layer: ~,1f MB~%" (/ bytes 1048576.0))))
(format t "~%== loading compact dict layer (bare)...~%")
$SENSE_LOAD_LISP
(format t "dict loaded. stats: ~a~%" (ichiran/memdict-compact:memdict-stats))
;; Optional baked trie (TRIE_TABLES='"kana_text"' etc.): prefix index over the
;; RAM text keys so per-sentence seeding skips non-dict windows with no DB.
$TRIE_LISP
$SYSTEM_TAIL
;; drop the DB connection (serving is DB-free)
(postmodern:clear-connection-pool)
(format t "CORE_BUILD_READY~%")
EOF

echo "== build-image.sh: building bare serving core (no :ichiran), tables: $TABLES =="
# save-lisp-and-die needs ~2x dict size free to freeze+relocate the heap, so
# request the max heap this Mac allows (16GB). Kana-only (3GB dict) builds
# fine here; the full 7.1GB dict dump needs a 32GB+ host.
# Keep the whole log. Piping straight to tail hid the actual error on a failed
# build, which is exactly when the message matters.
mkdir -p local-env/scratch
BUILD_LOG="local-env/scratch/build-image.log"
set +e
scripts/sbcl-wrapped --dynamic-space-size 16384 --non-interactive \
  --load "$BUILD_LISP" \
  --eval '(sb-ext:save-lisp-and-die "'"$OUT"'" :executable nil :compression t)' \
  > "$BUILD_LOG" 2>&1
BUILD_RC=$?
set -e
tail -5 "$BUILD_LOG"
if [ "$BUILD_RC" -ne 0 ]; then
  echo "IMAGE_BUILD_FAILED rc=$BUILD_RC (full log: $BUILD_LOG)"
  exit "$BUILD_RC"
fi
echo "IMAGE_BUILD_DONE -> $OUT"
# Provenance: record exactly what went into this core so 64GB-host and
# local builds are distinguishable.
{
  echo "out=$OUT"
  echo "tables=$TABLES"
  echo "int_tables=${INT_TABLES:-none}"
  echo "trie_tables=${TRIE_TABLES:-none}"
  echo "preset=${PRESET:-custom}"
  echo "git_sha=$GIT_SHA"
  echo "sbcl=$SBCL_VER"
  echo "date=$(date -u +%FT%TZ)"
} > "${OUT}.provenance" 2>/dev/null || true
echo "PROVENANCE -> ${OUT}.provenance"
