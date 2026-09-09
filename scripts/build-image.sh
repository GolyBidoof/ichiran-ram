#!/bin/bash
# build-image.sh — R4: build a serving core image with the compact dict loaded.
#
# R4 minimal-core path: quickload :postmodern only (NO :ichiran — the
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
#   PRESET=full scripts/build-image.sh  # all 9 tables (needs 32GB+ host)
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
# PRESET overrides TABLES when set.
case "${PRESET:-}" in
  lite) TABLES='"kana_text" "sense" "gloss" "sense_prop"' ;;
  kana) TABLES='"kana_text"' ;;
  full) TABLES='"kana_text" "kanji_text" "entry" "conjugation" "conj_prop" "conj_source_reading" "sense" "gloss" "sense_prop"' ;;
esac
TABLES="${TABLES:-\"kana_text\"}"
TRIE_TABLES="${TRIE_TABLES:-}"
DB_NAME="${ICHIRAN_DB_NAME:-jmdict}"
DB_USER="${ICHIRAN_DB_USER:-jmdict}"
DB_PASS="${ICHIRAN_DB_PASSWORD:-password}"
DB_HOST="${ICHIRAN_DB_HOST:-localhost}"
if [ -n "$TRIE_TABLES" ]; then
  TRIE_LISP="(ichiran/memdict-compact:memdict-build-trie :tables (list $TRIE_TABLES))"
else
  TRIE_LISP="(format t \"no baked trie (TRIE_TABLES empty)~%\")"
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
(load "src/memdict-compact.lisp")
(load "src/trie.lisp")
(in-package :cl-user)
(format t "~%== building serving core: loading compact dict (bare)...~%")
(ichiran/memdict-compact:memdict-load :conn '("$DB_NAME" "$DB_USER" "$DB_PASS" "$DB_HOST")
                                      :chunk 100000
                                      :tables (list $TABLES))
(format t "dict loaded. stats: ~a~%" (ichiran/memdict-compact:memdict-stats))
;; Optional baked trie (TRIE_TABLES='"kana_text"' etc.): prefix index over the
;; RAM text keys so per-sentence seeding skips non-dict windows with no DB.
$TRIE_LISP
;; drop the DB connection (serving is DB-free)
(postmodern:clear-connection-pool)
(format t "CORE_BUILD_READY~%")
EOF

echo "== build-image.sh: building bare serving core (no :ichiran), tables: $TABLES =="
# save-lisp-and-die needs ~2x dict size free to freeze+relocate the heap, so
# request the max heap this Mac allows (16GB). Kana-only (3GB dict) builds
# fine here; the full 7.1GB dict dump needs a 32GB+ host.
scripts/sbcl-wrapped --dynamic-space-size 16384 --non-interactive \
  --load "$BUILD_LISP" \
  --eval '(sb-ext:save-lisp-and-die "'"$OUT"'" :executable nil :compression t)' \
  2>&1 | tail -5
echo "IMAGE_BUILD_DONE -> $OUT"
# Provenance: record exactly what went into this core so 64GB-host and
# local builds are distinguishable.
{
  echo "out=$OUT"
  echo "tables=$TABLES"
  echo "trie_tables=${TRIE_TABLES:-none}"
  echo "preset=${PRESET:-custom}"
  echo "git_sha=$GIT_SHA"
  echo "sbcl=$SBCL_VER"
  echo "date=$(date -u +%FT%TZ)"
} > "${OUT}.provenance" 2>/dev/null || true
echo "PROVENANCE -> ${OUT}.provenance"
