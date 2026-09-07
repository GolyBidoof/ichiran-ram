#!/bin/bash
# build-image.sh — R4: build a serving core image with the compact dict loaded.
#
# The full compact dict (2.9GB kana + kanji) + analyzer consing exceeds a
# 16GB heap when the DB-load machinery is also present. This script builds a
# DEDICATED serving image: load :ichiran + memdict-compact, load the full
# dict ONCE, then dump a core image. Serving from that image has a clean
# heap: dict (~3GB) + analyzer with headroom, no DB connection machinery.
#
# Usage: scripts/build-image.sh [--out local-env/ichiran-serving.core]
set -e
cd "$(dirname "$0")/.."
OUT="${2:-local-env/ichiran-serving.core}"
mkdir -p local-env

cat > /tmp/build-serving.lisp <<'EOF'
(ql:quickload :ichiran :silent t)
(load "src/memdict-compact.lisp")
(load "src/memdict-compact-shims.lisp")
(in-package :cl-user)
(format t "~%== building serving image: loading compact dict...~%")
(ichiran/memdict-compact:memdict-load)
(format t "dict loaded. enabling memdict-p...~%")
(setf ichiran/dict::*memdict-p* t)
(format t "sanity: ~a~%" (ichiran:romanize "こんにちは"))
;; clear DB connection (serving is DB-free)
(postmodern:clear-connection-pool)
(format t "IMAGE_BUILD_READY~%")
EOF

echo "== build-image.sh: building serving core =="
scripts/sbcl-wrapped --dynamic-space-size 16384 --non-interactive \
  --load /tmp/build-serving.lisp \
  --eval '(sb-ext:save-lisp-and-die "'"$OUT"'" :executable nil :compression t)' \
  2>&1 | tail -5
echo "IMAGE_BUILD_DONE -> $OUT"
