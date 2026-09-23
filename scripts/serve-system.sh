#!/bin/bash
# serve-system.sh - persistent full-romanize server on the system core.
#
# The system core (local-env/ichiran-system-lite.core, built with SYSTEM=1)
# holds the analyzer + dict in RAM. This keeps ONE warm process serving
# stdin->romanize lines with no per-request startup (~2s boot once, then ms
# per sentence) and zero DB for covered paths.
#
# Usage:
#   ./scripts/serve-system.sh                       # interactive
#   echo "こんにちは" | ./scripts/serve-system.sh
#   ./scripts/serve-system.sh < corpus.txt > out.txt
#   CORE=local-env/other.core ./scripts/serve-system.sh
#
# Parallel by default: WORKERS=8 ./scripts/serve-system.sh (default one per
# core minus one). SERIAL=1 forces the single-threaded loop. Output order
# always matches input order.
#
# Protocol: the server prints {"ready":true,...} when warm; clients MUST ignore
# every line before it (SBCL prints its startup banner to stdout and --quiet
# is unusable with --core, so banner suppression is the client's job).
# Afterwards each stdin line gets exactly one stdout line (romanization or
# ERROR: ...).
set -e
cd "$(dirname "$0")/.." || exit 1
CORE="${CORE:-local-env/ichiran-system-lite.core}"

if [ ! -f "$CORE" ]; then
  echo "serve-system.sh: no core at $CORE - run SYSTEM=1 PRESET=lite scripts/build-image.sh --out $CORE first" >&2
  exit 2
fi

LOOP_LISP="$(mktemp /tmp/serve-system.XXXXXXXX)" || {
  echo "SERVE_SYSTEM_ERROR: mktemp failed"
  exit 2
}
trap 'rm -f "$LOOP_LISP"' EXIT INT TERM

cat > "$LOOP_LISP" <<'EOF'
(defpackage :ichiran/serve-system (:use :cl) (:export :main))
(in-package :ichiran/serve-system)

(defun main ()
  ;; SERIAL=1 keeps the single-threaded loop (useful for bisecting and for
  ;; machines where the worker copies of the memo tables cost too much).
  (if (uiop:getenv "SERIAL")
      (progn
        (format t "{\"ready\":true,\"workers\":1}~%")
        (finish-output)
        (loop for line = (read-line *standard-input* nil nil)
              while line
              for text = (string-trim '(#\Space #\Tab #\Newline) line)
              do (format t "~a~%" (if (zerop (length text))
                                      ""
                                      (handler-case (ichiran:romanize text)
                                        (error (e) (format nil "ERROR: ~a" e)))))
                 (finish-output)))
      ;; Parallel: one worker per core, output in input order.
      (ichiran/serve-parallel:serve-stream)))
EOF

echo "serve-system.sh: serving from $CORE ..." >&2
scripts/sbcl-wrapped --dynamic-space-size 8192 --core "$CORE" \
  --non-interactive \
  --load src/serve-parallel.lisp \
  --load "$LOOP_LISP" \
  --eval '(ichiran/serve-system:main)'
