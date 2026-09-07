#!/bin/bash
# golden-snapshot.sh — dump full romanize* JSON for every golden-corpus line.
# Produces data/golden-corpus-baseline.json (the parity contract for perf work).
# Usage: golden-snapshot.sh [--out FILE]
cd "$(dirname "$0")/.." || exit 1
OUT="${2:-data/golden-corpus-baseline.json}"
CORPUS="data/golden-corpus.txt"

cat > /tmp/ichiran-golden.lisp <<EOF
(defpackage :ichiran-golden (:use :cl) (:export :main))
(in-package :ichiran-golden)

(defun main ()
  (let ((out (merge-pathnames "$OUT" (asdf:system-relative-pathname :ichiran "."))))
    (with-open-file (corpus (asdf:system-relative-pathname :ichiran "data/golden-corpus.txt"))
      (with-open-file (res out :direction :output :if-exists :supersede)
        (loop for line = (read-line corpus nil nil)
              while line
              for text = (string-trim '(#\Space #\Tab #\Newline) line)
              unless (or (zerop (length text)) (char= (char text 0) #\#))
                do (let ((val (handler-case (ichiran:romanize* text :limit 5)
                                (error (e) (list :error (princ-to-string e))))))
                     (princ (jsown:to-json val) res)
                     (terpri res)))))
    (format t "GOLDEN_SNAPSHOT_OK -> ~a~%" out)))
EOF

echo "== golden-snapshot.sh =="
scripts/sbcl-wrapped --dynamic-space-size 8192 \
  --non-interactive \
  --eval '(ql:quickload (list :ichiran :ichiran/cli) :silent t)' \
  --load /tmp/ichiran-golden.lisp \
  --eval '(ichiran-golden:main)' \
  2>&1 | grep -vE "^(This is SBCL|More information|SBCL is free|BSD-style|distribution)" | tail -5
echo "GOLDEN_DONE"
