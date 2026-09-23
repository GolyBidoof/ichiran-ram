;;; audit-calls.lisp - per-function call counts and time over a corpus.
;;;
;;; The stage audit says how long each STAGE takes; this says which FUNCTIONS
;;; are responsible, and how many times each is called, which is what you need
;;; before deciding whether the fix is to make a function faster or to call it
;;; less. Instrumentation wraps the function objects, so a function that calls
;;; itself recursively is counted at every level, and the reported time is
;;; INCLUSIVE: a parent's share contains its children's. Read the call counts as
;;; exact and the times as indicative.
;;;
;;;   CORPUS=the visual-novel prologue sample scripts/sbcl-wrapped \
;;;     --core local-env/ichiran-serving.core --non-interactive \
;;;     --load scripts/audit-stages.lisp --load scripts/audit-calls.lisp \
;;;     --eval '(audit-calls)' --eval '(sb-ext:quit)'
;;;
;;; On the core the jsown method for WORD-INFO comes from audit-stages.lisp,
;;; which is why that file is loaded first.

(in-package :cl-user)
(defvar *counts* (make-hash-table :test 'eq))
(defvar *times* (make-hash-table :test 'eq))
(defun inst (name &optional (pkg :ichiran/dict))
  (let ((sym (find-symbol (string-upcase name) pkg)))
    (when (and sym (fboundp sym))
      (let ((orig (symbol-function sym)))
        (setf (symbol-function sym)
              (lambda (&rest args)
                (incf (gethash sym *counts* 0))
                (let ((t0 (get-internal-real-time)))
                  (multiple-value-prog1 (apply orig args)
                    (incf (gethash sym *times* 0)
                          (- (get-internal-real-time) t0)))))))
      t)))
(defun audit-calls ()
  (let* ((path (or (uiop:getenv "CORPUS") "the visual-novel prologue sample"))
         (lines (lines-of path))
         (n (length lines)))
    (dolist (l lines) (ichiran:romanize l))
    (dolist (nm '("FIND-SUBSTRING-WORDS" "FIND-WORD-FULL" "FIND-WORD-SUFFIX"
                  "FIND-WORD-SEQ" "GEN-SCORE" "CALC-SCORE" "CULL-SEGMENTS"
                  "MAKE-SEGMENT" "JOIN-SUBSTRING-WORDS*" "JOIN-SUBSTRING-WORDS"
                  "FIND-BEST-PATH" "FILL-SEGMENT-PATH" "GET-SUFFIX-MAP"
                  "APPLY-SEGFILTER" "GET-SEG-SPLITS" "FIND-STICKY-POSITIONS"
                  "MATCH-SENSE-RESTRICTIONS" "GET-SENSES" "GET-SENSES-JSON"
                  "CONJ-INFO-JSON" "READING-STR" "WORD-INFO-READING"))
      (inst nm))
    (clrhash *counts*) (clrhash *times*)
    (let* ((t0 (get-internal-real-time))
           (res (dolist (l lines) (ichiran:romanize l)))
           (total (- (get-internal-real-time) t0))
           (rows '()))
      (declare (ignore res))
      (maphash (lambda (k v) (push (list (symbol-name k) (gethash k *counts* 0) v) rows)) *times*)
      (setf rows (sort rows #'> :key #'third))
      (format t "~&CALLS lines=~a total-romanize=~,1fms ~,3f ms/line~%" n (/ total 1000.0) (/ total 1000.0 n))
      (format t "CALLS ~28a ~10a ~10a ~10a ~7a~%" "function" "calls" "calls/line" "ms" "%")
      (dolist (r rows)
        (format t "CALLS ~28a ~10a ~10,1f ~10,1f ~6,1f%~%" (first r) (second r)
                (/ (second r) (float n)) (/ (third r) 1000.0)
                (* 100.0 (/ (third r) (max 1 total)))))))
  (finish-output))
