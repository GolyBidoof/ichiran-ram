#!/bin/bash
# serve-snapshot.sh - full-RAM serving without a baked core.
#
# Why this exists: serve-system.sh needs a saved core, and baking the FULL
# dictionary into one needs a 32GB+ host (see build-image.sh). The snapshot
# gives the same in-RAM tables on a 16GB machine by reading them from disk
# (measured 7.5-9s for the integer layer, versus ~70s from PostgreSQL), so a
# full-dictionary, parallel server can be started on ordinary hardware.
#
# Trade-off to know about: the integer layer comes from the snapshot, but the
# compact sense layer (sense/gloss/sense_prop, ~1s) still comes from
# PostgreSQL, because it is a plist-shaped layer rather than flat columns. A
# database is therefore still required at startup, though no query is issued
# on the serving path afterwards.
#
# Usage:
#   ./scripts/serve-snapshot.sh                        # interactive
#   echo "こんにちは" | ./scripts/serve-snapshot.sh
#   ./scripts/serve-snapshot.sh < corpus.txt > out.txt
#   SNAPSHOT=path/to.snap ./scripts/serve-snapshot.sh
#   SERIAL=1 ./scripts/serve-snapshot.sh               # single-threaded loop
#
# Protocol: prints {"ready":true,...} once warm; clients MUST ignore any line
# before it (SBCL writes a banner to stdout and --quiet is unusable here).
# After that, each stdin line yields exactly one stdout line.
set -e
cd "$(dirname "$0")/.." || exit 1
SNAPSHOT="${SNAPSHOT:-local-env/ichiran-int.snap}"

if [ ! -f "$SNAPSHOT" ]; then
  echo "serve-snapshot.sh: no snapshot at $SNAPSHOT" >&2
  echo "  build one with: scripts/build-snapshot.sh --out $SNAPSHOT" >&2
  exit 2
fi

BOOT_LISP="$(mktemp /tmp/serve-snapshot.XXXXXXXX)" || {
  echo "SERVE_SNAPSHOT_ERROR: mktemp failed"
  exit 2
}
trap 'rm -f "$BOOT_LISP"' EXIT INT TERM

# The snapshot path is read from the environment at run time so the file can
# be built here as a heredoc.
cat > "$BOOT_LISP" <<'EOF'
(in-package :cl-user)

(defun boot-and-serve ()
  (let* ((snap (uiop:getenv "SNAPSHOT"))
         (extras (or (uiop:getenv "ICHIRAN_BAKE_SNAP")
                     "local-env/ichiran-bake.snap"))
         ;; The three sets that are not in the snapshot format are in the extras
         ;; file. With it here this boot needs no database at all, so it does not
         ;; open a socket even to find out whether one exists.
         (dbless (and (probe-file extras) (fboundp 'ichiran/serve-parallel:load-bake-extras))))
    (let ((ichiran/conn::*no-database* dbless))
      (ichiran/conn:with-db nil
        (ichiran/memdict-compact:memdict-load-int :snapshot snap)
        (if (probe-file "local-env/ichiran-sense.snap")
            (ichiran/memdict-compact:memdict-load-sense-snapshot
             "local-env/ichiran-sense.snap" :int-snapshot snap)
            (ichiran/memdict-compact:memdict-load
             :chunk 200000 :tables '("sense" "gloss" "sense_prop")))
        (when dbless
          (ichiran/serve-parallel:load-bake-extras extras))
        (setf ichiran/dict::*memdict-p* t)
        (ichiran/serve-parallel:warm-caches)
        (setf ichiran/serve-parallel::*db-available*
              (ichiran/serve-parallel:probe-db))))
    ;; The load went fully RAM, so the counters cache and the memo tables take
    ;; their RAM paths for the rest of the process rather than probing per lookup.
    (when (and dbless (not ichiran/serve-parallel::*db-available*))
      (setf ichiran/conn::*no-database* t))
    ;; Only the serial path announces readiness here. serve-stream prints its
    ;; own ready line on the parallel path, and two of them would desynchronize
    ;; a client that treats the first as the signal to start sending.
    (if (uiop:getenv "SERIAL")
        (progn
          (format t "{\"ready\":true,\"snapshot\":\"~a\",\"workers\":1}~%" snap)
          (finish-output))
        (format *error-output* "serve-snapshot.sh: ~a ready (workers ~a)~%"
                snap (ichiran/serve-parallel:worker-count)))
    (if (uiop:getenv "SERIAL")
        (loop for line = (read-line *standard-input* nil nil)
              while line
              for text = (string-trim '(#\Space #\Tab #\Newline) line)
              do (format t "~a~%"
                         (if (zerop (length text))
                             ""
                             (handler-case (ichiran:romanize text)
                               (error (e) (format nil "ERROR: ~a" e)))))
                 (finish-output))
        (ichiran/serve-parallel:serve-stream))))

(boot-and-serve)
EOF

echo "serve-snapshot.sh: serving from $SNAPSHOT ..." >&2
SNAPSHOT="$SNAPSHOT" scripts/sbcl-wrapped --dynamic-space-size 8192 \
  --non-interactive \
  --eval '(ql:quickload :ichiran :silent t)' \
  --load src/memdict-compact.lisp \
  --load src/memdict-int.lisp \
  --load src/memdict-compact-shims.lisp \
  --load src/int-snapshot.lisp \
  --load src/sense-snapshot.lisp \
  --load src/serve-parallel.lisp \
  --load src/bake-extras.lisp \
  --load "$BOOT_LISP"
