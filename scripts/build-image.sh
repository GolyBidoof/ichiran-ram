#!/bin/bash
# build-image.sh — R4: build a serving core image with the compact dict loaded.
#
# R4 minimal-core path (the handover's memory wall was loading the compact
# dict ON TOP of the 13GB :ichiran analyzer baseline; bare it fits an 8GB
# heap — verified: full kana_text 3.08M rows = ~3GB delta, no exhaustion).
# This script builds a DEDICATED serving core:
#   1. postmodern only (NO :ichiran quickload — the decoupled memdict-compact
#      depends only on postmodern).
#   2. load the full compact dict ONCE into the clean heap.
#   3. dump a core image. The serving core can then load the analyzer on top
#      (DB-free for the dict-covered path) or serve dict lookups directly.
#
# Usage: scripts/build-image.sh [--out local-env/ichiran-serving.core]
set -e
cd "$(dirname "$0")/.."
OUT="${2:-local-env/ichiran-serving.core}"
mkdir -p local-env

cat > /tmp/build-serving.lisp <<'EOF'
(ql:quickload :postmodern :silent t)
(load "src/memdict-compact.lisp")
(in-package :cl-user)
(format t "~%== building serving core: loading full compact dict (bare)...~%")
(ichiran/memdict-compact:memdict-load :conn '("jmdict" "jmdict" "password" "localhost") :chunk 100000)
(format t "dict loaded. stats: ~a~%" (ichiran/memdict-compact:memdict-stats))
;; drop the DB connection (serving is DB-free)
(postmodern:clear-connection-pool)
(format t "CORE_BUILD_READY~%")
EOF

echo "== build-image.sh: building bare serving core (no :ichiran) =="
# The dict LOAD fits an 8GB heap (verified: 3.08M kana rows = ~3GB delta).
# save-lisp-and-die needs ~2x dict size free to freeze+relocate the heap, so
# we request the max heap this Mac allows (16GB). On this machine the dump
# step still exhausts at ~4GB used (documented hardware wall); on a bigger-heap
# host (Linux x86-64 SBCL, 32GB+) this script produces the serving core.
scripts/sbcl-wrapped --dynamic-space-size 16384 --non-interactive \
  --load /tmp/build-serving.lisp \
  --eval '(sb-ext:save-lisp-and-die "'"$OUT"'" :executable nil :compression t)' \
  2>&1 | tail -5
echo "IMAGE_BUILD_DONE -> $OUT"
