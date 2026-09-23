#!/bin/bash
# build-snapshot.sh — write a binary snapshot of the integer dictionary layer.
#
# Why: loading the integer layer from PostgreSQL costs ~72s on the full
# dictionary. The layer is flat typed columns plus interned string pools, so it
# can be dumped as raw bytes and read back with bulk reads: measured 8.9s to
# load the same tables, byte-identical answers. Rebuild the snapshot when the
# dictionary, the DB, or the column layout changes.
#
# Usage:
#   scripts/build-snapshot.sh [--out local-env/ichiran-int.snap]
set -e
cd "$(dirname "$0")/.." || exit 1
OUT="${OUT:-local-env/ichiran-int.snap}"
if [ "$1" = "--out" ] && [ -n "$2" ]; then OUT="$2"; fi

SNAP_LISP="$(mktemp /tmp/build-snapshot.XXXXXXXX)" || exit 2
trap 'rm -f "$SNAP_LISP"' EXIT INT TERM
cat > "$SNAP_LISP" <<EOF
(ql:quickload :ichiran :silent t)
(load "src/memdict-compact.lisp")
(load "src/memdict-int.lisp")
(load "src/int-snapshot.lisp")
(ichiran/conn:with-db nil
  (ichiran/memdict-compact:memdict-load-int :save-snapshot "$OUT"))
(format t "SNAPSHOT_DONE -> $OUT~%")
EOF

echo "build-snapshot.sh: writing $OUT ..." >&2
scripts/sbcl-wrapped --dynamic-space-size 14336 --non-interactive \
  --load "$SNAP_LISP"
ls -lh "$OUT"
