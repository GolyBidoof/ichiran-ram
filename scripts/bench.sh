#!/bin/bash
# bench.sh — measure ichiran performance: query counts, consing, wall time.
# Baseline measurement tool for the perf work (analysis §9 gate).
# Usage: bench.sh [--warm] [--sentence "日本語の文"] ...
cd "$(dirname "$0")/.." || exit 1

cat > /tmp/ichiran-bench.lisp <<'EOF'
(defpackage :ichiran-bench (:use :cl) (:export :main))
(in-package :ichiran-bench)

(defparameter *samples*
  '("一覧は最高だぞ"
    "こんにちは"
    "日本語を勉強しています"
    "学校で勉強しています"
    "錬丹術は医学方面に特化してるというからね"
    "これさえあれば俺は本物の妖怪になれるんだヘヘッ"))

(defun count-query-lines (file)
  (when (probe-file file)
    (with-open-file (s file) (loop for l = (read-line s nil nil) while l count l))))

(defun bench-one (text)
  (let* ((qlog (format nil "/tmp/ichiran-queries-~d.log" (random 1000000000)))
         (start (get-internal-real-time))
         (bytes0 (sb-ext:get-bytes-consed))
         (res (ichiran/conn:with-log (qlog)
                (multiple-value-list (ichiran:romanize text :with-info t))))
         (end (get-internal-real-time))
         (consed (- (sb-ext:get-bytes-consed) bytes0))
         (secs (/ (- end start) internal-time-units-per-second))
         (queries (count-query-lines qlog)))
    (ignore-errors (delete-file qlog))
    (format t "SAMPLE: ~a~%  romanized: ~a~%  words: ~a~%  queries: ~a~%  time: ~,3f secs  consed: ~a bytes~%"
            text (car res) (length (cadr res)) queries secs consed)))

(defun main ()
  (format t "~%== ichiran bench (warm caches assumed) ==~%~%")
  (dolist (s *samples*)
    (bench-one s)))
EOF

echo "== bench.sh: warmup + baseline =="
scripts/sbcl-wrapped --dynamic-space-size 8192 \
     --non-interactive \
     --eval '(ql:quickload :ichiran :silent t)' \
     --load /tmp/ichiran-bench.lisp \
     --eval '(ichiran-bench:main)' \
     2>&1 | grep -vE "^(This is SBCL|More information|SBCL is free|BSD-style|distribution)" | tail -45
echo "BENCH_DONE"
