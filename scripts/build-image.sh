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
#   TABLES='"kanji_text"' scripts/build-image.sh   # kana-only (default)
#   TABLES='"kana_text" "kanji_text"' scripts/build-image.sh  # full (needs 32GB+)
set -e
cd "$(dirname "$0")/.."
OUT="${2:-local-env/ichiran-serving.core}"
TABLES="${TABLES:-\"kana_text\"}"
mkdir -p local-env

cat > /tmp/build-serving.lisp <<EOF
(ql:quickload :postmodern :silent t)
(load "src/memdict-compact.lisp")
(in-package :cl-user)
(format t "~%== building serving core: loading compact dict (bare)...~%")
(ichiran/memdict-compact:memdict-load :conn '("jmdict" "jmdict" "password" "localhost")
                                      :chunk 100000
                                      :tables (list $TABLES))
(format t "dict loaded. stats: ~a~%" (ichiran/memdict-compact:memdict-stats))
;; drop the DB connection (serving is DB-free)
(postmodern:clear-connection-pool)
(format t "CORE_BUILD_READY~%")
EOF

echo "== build-image.sh: building bare serving core (no :ichiran), tables: $TABLES =="
# save-lisp-and-die needs ~2x dict size free to freeze+relocate the heap, so
# request the max heap this Mac allows (16GB). Kana-only (3GB dict) builds
# fine here; the full 7.1GB dict dump needs a 32GB+ host.
scripts/sbcl-wrapped --dynamic-space-size 16384 --non-interactive \
  --load /tmp/build-serving.lisp \
  --eval '(sb-ext:save-lisp-and-die "'"$OUT"'" :executable nil :compression t)' \
  2>&1 | tail -5
echo "IMAGE_BUILD_DONE -> $OUT"
