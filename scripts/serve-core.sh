#!/bin/bash
# serve-core.sh — R4: run the zero-DB serving core as a persistent stdin->JSON
# lookup server.
#
# The core (local-env/ichiran-serving.core, built by build-image.sh) holds the
# FULL compact dictionary (3,079,757 kana rows) in memory with NO database
# connection. Each line of stdin is a text; each line of stdout is a JSON
# array of matching compact-kana rows (or [] if none). This is the R4
# zero-DB serving image.
#
# Usage:
#   ./scripts/serve-core.sh                    # interactive (one line per request)
#   echo "こんにちは" | ./scripts/serve-core.sh
#   ./scripts/serve-core.sh < corpus.txt > out.jsonl
set -e
cd "$(dirname "$0")/.."
CORE="${CORE:-local-env/ichiran-serving.core}"

if [ ! -f "$CORE" ]; then
  echo "serve-core.sh: no core at $CORE — run scripts/build-image.sh first" >&2
  exit 2
fi

cat > /tmp/serve-core-loop.lisp <<'EOF'
(defpackage :ichiran/serve-core (:use :cl) (:export :main))
(in-package :ichiran/serve-core)

(defun row-json (row)
  "Serialize a compact-kana row as a small JSON object."
  (format nil "{\"text\":~s,\"seq\":~a,\"ord\":~a}"
          (ichiran/memdict-compact:compact-kana-text row)
          (ichiran/memdict-compact:compact-kana-seq row)
          (ichiran/memdict-compact:compact-kana-ord row)))

(defun main ()
  (format t "{\"ready\":true,\"kana\":~a}~%"
          (hash-table-count ichiran/memdict-compact::*kana-by-text*))
  (finish-output)
  (loop for line = (read-line *standard-input* nil nil)
        while line
        for text = (string-trim '(#\Space #\Tab #\Newline) line)
        do (let ((rows (when (plusp (length text))
                         (ichiran/memdict-compact:memdict-find 'kana-text text))))
             (if rows
                 (format t "[~{~a~^,~}]~%" (mapcar #'row-json rows))
                 (format t "[]~%"))
             (finish-output))))
EOF

echo "serve-core.sh: loading core $CORE (dict in RAM, zero DB)..."
scripts/sbcl-wrapped --dynamic-space-size 8192 --core "$CORE" \
  --non-interactive \
  --load /tmp/serve-core-loop.lisp \
  --eval '(ichiran/serve-core:main)'
