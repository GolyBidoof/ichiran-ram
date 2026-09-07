;;;; src/driver.lisp — S5: parallel corpus driver (lparallel).
;;;;
;;;; Scales batch throughput across cores. Each worker processes sentences
;;;; through ichiran's romanize*/dict-segment. Postgres connections are
;;;; per-thread when the DB is live; when the S1 cache is enabled and warm,
;;;; workers hit the cache instead of contending on the DB.
;;;;
;;;; Pattern mirrors tests.lisp's parallel harness (lparallel kernel +
;;;; futures) — see tests.lisp:670-677.

(defpackage #:ichiran/driver
  (:use #:cl)
  (:export #:process-corpus #:process-lines))

(in-package #:ichiran/driver)

(defun process-lines (lines &key (threads (max 1 (1- (count-processors)))) (limit 5))
  "Process LINES (list of strings) in parallel with THREADS workers, each
   calling (ichiran:romanize* line :limit limit). Returns a list of results
   in the same order as LINES (each result is romanize*'s value, or
   (:error . message) on failure)."
  (let* ((n (length lines))
         (kernel (lparallel:make-kernel threads :name "ichiran-driver"))
         (results (make-array n :initial-element nil))
         (futures (make-array n)))
    (unwind-protect
         (let ((lparallel:*kernel* kernel))
           ;; launch one future per line (lparallel queues them; workers pull)
           (dotimes (i n)
             (let ((line (elt lines i)))
               (setf (aref futures i)
                     (lparallel:future
                       (handler-case
                           (ichiran:romanize* line :limit limit)
                         (error (e) (cons :error (princ-to-string e))))))))
           ;; collect in order
           (dotimes (i n)
             (setf (aref results i) (lparallel:force (aref futures i))))
           (coerce results 'list))
      (lparallel:end-kernel))))

(defun process-corpus (path &key (threads (max 1 (1- (count-processors)))) (limit 5))
  "Read PATH (one sentence per line), process with process-lines, return the
   list of results (one per line). Blank lines yield nil."
  (with-open-file (in path :external-format :utf-8)
    (let ((lines (loop for l = (read-line in nil nil)
                       while l
                       collect (string-trim '(#\Space #\Tab #\Newline #\Return) l))))
      (process-lines lines :threads threads :limit limit))))
