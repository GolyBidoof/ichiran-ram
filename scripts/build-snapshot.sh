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
# The sense layer goes in its own file: it is small, it changes independently
# of the integer layer, and keeping it separate means a dictionary rebuild does
# not force a sense rebuild.
SENSE_OUT="${SENSE_OUT:-local-env/ichiran-sense.snap}"

SNAP_LISP="$(mktemp /tmp/build-snapshot.XXXXXXXX)" || exit 2
trap 'rm -f "$SNAP_LISP"' EXIT INT TERM
cat > "$SNAP_LISP" <<EOF
(ql:quickload :ichiran :silent t)
(load "src/memdict-compact.lisp")
(load "src/memdict-int.lisp")
(load "src/int-snapshot.lisp")
(load "src/sense-snapshot.lisp")
(ichiran/conn:with-db nil
  (ichiran/memdict-compact:memdict-load-int :save-snapshot "$OUT")
  ;; sense, gloss and sense_prop: the last tables that still came from SQL on
  ;; every start. About 0.9s, and they were what made the RAM path need a live
  ;; database at all.
  (ichiran/memdict-compact:memdict-load
   :chunk 200000 :tables (list "sense" "gloss" "sense_prop"))
  (ichiran/memdict-compact:memdict-save-sense-snapshot "$SENSE_OUT"))
(format t "SNAPSHOT_DONE -> $OUT~%")
(format t "SENSE_SNAPSHOT_DONE -> $SENSE_OUT~%")
EOF

echo "build-snapshot.sh: writing $OUT ..." >&2
scripts/sbcl-wrapped --dynamic-space-size 14336 --non-interactive \
  --load "$SNAP_LISP"
ls -lh "$OUT" "$SENSE_OUT"
