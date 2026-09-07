;;;; src/cache.lisp — S1: seq-keyed memoized DB lookups (thread-safe).
;;;;
;;;; Why: calc-score and get-conj-data fire 3+ queries per candidate word
;;;; (entry, sense-prop "uk", get-non-arch-posi, conjugation +
;;;; conj-source-reading + conj-prop). Most repeat for the same seq within a
;;;; sentence and across sentences. Memoizing per seq collapses 139-1041
;;;; queries/sentence down to one-time fills.
;;;;
;;;; Contract (docs/seams.md S1): return EXACTLY what the underlying
;;;; postmodern/ichiran calls return (same DAO objects / nil semantics),
;;;; never re-hit the DB for a cached key, thread-safe, invalidatable.

(defpackage #:ichiran/cache
  (:use #:cl #:postmodern #:ichiran/conn)
  (:export #:ensure-entry #:ensure-posi #:ensure-uk #:ensure-conj-data
           #:cache-reset #:cache-stats))

(in-package #:ichiran/cache)

;;; Sentinel for "cached a missing result" (so NIL results are cached too).
(defconstant +missing+ (gensym "MISSING"))
(defconstant +nil+ (gensym "NIL"))

(declaim (inline cache-miss-value))
(defun cache-miss-value (v)
  "Convert a raw function result to a cache slot value."
  (if (null v) +nil+ v))

(declaim (inline cache-slot-value))
(defun cache-slot-value (slot)
  "Convert a cache slot value back to the caller's result."
  (if (eql slot +nil+) nil slot))

;;; Per-table state: a hash table + a lock + hit/miss counters.
(defstruct (memo-table (:constructor make-memo-table (&key (test 'eql))))
  (hash (make-hash-table :test test))
  (lock (sb-thread:make-mutex))
  (hits 0 :type fixnum)
  (misses 0 :type fixnum))

(declaim (inline memo-get memo-set memo-hit memo-miss))
(defun memo-get (table key)
  (sb-thread:with-mutex ((memo-table-lock table))
    (multiple-value-bind (v found) (gethash key (memo-table-hash table))
      (if found
          (progn (incf (memo-table-hits table)) (cache-slot-value v))
          (progn (incf (memo-table-misses table)) (values nil nil))))))

(defun memo-set (table key value)
  (sb-thread:with-mutex ((memo-table-lock table))
    (setf (gethash key (memo-table-hash table)) (cache-miss-value value))
    value))

(defun memo-fill (table key thunk)
  "Return cached value for KEY or compute via THUNK, store, return. Handles
   a genuinely-missing result (NIL) being cached too. Returns (values v found-p)."
  (multiple-value-bind (v found) (memo-get table key)
    (if found
        (values v t)
        (let ((new (funcall thunk)))
          (memo-set table key new)
          (values new t)))))

;;; The tables.
(defparameter *entry-table* (make-memo-table))
(defparameter *posi-table* (make-memo-table :test 'equal))
(defparameter *uk-table* (make-memo-table :test 'equal))
(defparameter *conj-data-table* (make-memo-table :test 'equal))

(defun cache-reset ()
  "Clear all memo tables (call from add-errata / tests when DB may have changed)."
  (dolist (tbl (list *entry-table* *posi-table* *uk-table* *conj-data-table*))
    (sb-thread:with-mutex ((memo-table-lock tbl))
      (clrhash (memo-table-hash tbl))
      (setf (memo-table-hits tbl) 0
            (memo-table-misses tbl) 0)))
  t)

(defun cache-stats ()
  "Return a plist of per-table (hits misses) pairs."
  (list :entry (list (memo-table-hits *entry-table*) (memo-table-misses *entry-table*))
        :posi (list (memo-table-hits *posi-table*) (memo-table-misses *posi-table*))
        :uk (list (memo-table-hits *uk-table*) (memo-table-misses *uk-table*))
        :conj-data (list (memo-table-hits *conj-data-table*) (memo-table-misses *conj-data-table*))))

;;; Normalize a seq-set list into a stable key: sorted copy.
(defun normalize-seq-set (seq-set)
  (sort (copy-list seq-set) '<))

;;; ---- the four accessors ----

(defun ensure-entry (seq)
  "Memoized (get-dao 'entry seq). Returns the entry DAO or NIL if missing."
  (memo-fill *entry-table* seq
             (lambda ()
               (ichiran/dict::get-dao 'ichiran/dict::entry seq))))

(defun ensure-posi (seq-set)
  "Memoized ichiran/dict::get-non-arch-posi for a seq-set (sorted key)."
  (let ((key (normalize-seq-set seq-set)))
    (memo-fill *posi-table* key
               (lambda ()
                 (ichiran/dict::get-non-arch-posi seq-set)))))

(defun ensure-uk (seq-set)
  "Memoized select-dao sense-prop 'uk' for a seq-set (sorted key)."
  (let ((key (normalize-seq-set seq-set)))
    (memo-fill *uk-table* key
               (lambda ()
                 (ichiran/dict::select-dao 'ichiran/dict::sense-prop
                                           (:and (:in 'seq (:set seq-set))
                                                 (:= 'tag "misc") (:= 'text "uk")))))))

(defun normalize-conj-key (seq from &optional texts)
  "Stable key for get-conj-data: (list seq from texts) with from normalized.
   nil -> :none, :root -> :root, list -> sorted list, integer -> integer.
   texts nil -> :none, string -> itself, list -> sorted list."
  (list seq
        (cond ((null from) :none)
              ((eql from :root) :root)
              ((listp from) (normalize-seq-set from))
              (t from))
        (cond ((null texts) :none)
              ((listp texts) (normalize-seq-set texts))
              (t texts))))

(defun ensure-conj-data (seq &optional from texts)
  "Memoized ichiran/dict::get-conj-data seq from texts. Returns list of
   conj-data structs (or NIL), identical to calling get-conj-data directly."
  (let ((key (normalize-conj-key seq from texts)))
    (memo-fill *conj-data-table* key
               (lambda ()
                 (ichiran/dict::get-conj-data seq from texts)))))
