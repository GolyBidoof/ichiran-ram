;;;; src/daemon.lisp — S5: persistent JSON server for ichiran romanize*.
;;;;
;;;; Why: per-invocation SBCL startup dominates batch throughput (community
;;;; measured 3.9 sentences/s per-line-CLI vs ~40+ with a warm daemon). This
;;;; module reads sentences on stdin and writes JSON on stdout from ONE warm
;;;; process (caches + DB connection stay live).
;;;;
;;;; Framing contract: exactly one JSON object per input line, terminated by
;;;; a single newline, flushed after every line so consumers can stream.
;;;; Serialization is byte-identical to the CLI's (jsown:to-json over
;;;; romanize*), which requires ichiran/cli loaded for its word-info method.

(defpackage #:ichiran/daemon
  (:use #:cl)
  (:export #:serve-line #:serve-loop))

(in-package #:ichiran/daemon)

(defun serve-line (text &key (limit 5))
  "Romanize* TEXT and return its JSON string. On error, return a JSON
   {\"error\": ...} object — never signal."
  (handler-case
      (jsown:to-json (ichiran:romanize* text :limit limit))
    (error (e)
      (jsown:to-json (jsown:new-js ("error" (princ-to-string e)))))))

(defun serve-loop (&key (in *standard-input*) (out *standard-output*))
  "Read lines from IN until EOF; for each non-empty line write
   (serve-line line) + newline to OUT; flush after each line."
  (loop for line = (read-line in nil nil)
        while line
        for text = (string-trim '(#\Space #\Tab #\Newline #\Return) line)
        unless (zerop (length text))
          do (princ (serve-line text) out)
             (terpri out)
             (finish-output out))
  (finish-output out)
  t)
