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
           #:prefetch-seq-data #:prefetch-conj-data #:prefetch-senses
           #:ensure-senses
           #:conj-batch
           #:conj-prop-batch #:csr-batch #:cache-reset #:cache-stats))

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

;;; S2-v2: per-sentence batched conjugation data (filled by
;;; prefetch-conj-data; consumed by get-conj-data's caller via conj-batch).
(defparameter *conj-batch* nil "hash: conj-id -> conjugation DAO")
(defparameter *conj-prop-batch* (make-hash-table :test 'eql) "hash: conj-id -> list of conj-prop DAOs")
(defparameter *csr-batch* (make-hash-table :test 'eql) "hash: conj-id -> list of conj-source-reading DAOs")

(defun conj-batch ()
  "Return the current sentence's conjugation-by-id hash (or NIL)."
  *conj-batch*)

(defun conj-prop-batch ()
  "Return the current sentence's conj-id -> conj-prop list hash."
  *conj-prop-batch*)

(defun csr-batch ()
  "Return the current sentence's conj-id -> conj-source-reading list hash."
  *csr-batch*)

;;; ---- S2-v2b: per-sentence batched gloss/sense data (:with-info path) ----

(defparameter *senses-table* (make-memo-table :test 'eql))

(defun ensure-senses (seq)
  "Memoized ichiran/dict::get-senses-raw seq (the 2-query gloss+props
   lookup used by the :with-info path)."
  (memo-fill *senses-table* seq
             (lambda ()
               (let ((ichiran/dict::*in-sense-cache* t))
                 (ichiran/dict::get-senses-raw seq)))))

(defun prefetch-senses (seqs)
  "Batch-load sense/gloss/sense-prop for all SEQS in 2 IN queries total
   (instead of 2 per seq), storing per-seq results into *senses-table* in
   the same shape get-senses-raw returns (list of (:ord :gloss :props))."
  (let ((seqs (remove-duplicates (remove nil seqs))))
    (when seqs
      (let ((to-load (loop for s in seqs
                           unless (nth-value 1 (memo-get *senses-table* s))
                           collect s)))
        (when to-load
          ;; 1. glosses: one query over all seqs, grouped per seq
          (let ((gloss-by-seq (make-hash-table :test 'eql))
                (sense-by-seq (make-hash-table :test 'eql))
                (props-by-id (make-hash-table :test 'eql)))
            (let ((sql (format nil "SELECT s.seq, s.id, s.ord, string_agg(g.text, '; ' ORDER BY g.ord) FROM sense s LEFT JOIN gloss g ON g.sense_id = s.id WHERE s.seq IN (~{~a~^,~}) GROUP BY s.id, s.seq, s.ord" to-load)))
              (dolist (row (ichiran/conn::query sql :lists))
              ;; row = (seq id ord gloss)
              (destructuring-bind (seq sid ord gloss) row
                (push (list :ord ord :gloss (if (eql gloss :null) "" gloss) :props nil :sense-id sid)
                      (gethash seq gloss-by-seq)))))
            ;; 2. props: one query over all seqs, grouped per sense
            (let ((sql (format nil "SELECT s.seq, s.id, sp.tag, sp.text FROM sense s, sense_prop sp WHERE sp.sense_id = s.id AND s.seq IN (~{~a~^,~}) AND sp.tag IN ('pos','s_inf','stagk','stagr','field')" to-load)))
              (dolist (row (ichiran/conn::query sql :lists))
              (destructuring-bind (seq sid tag text) row
                (push (list tag text) (gethash sid props-by-id)))))
            ;; merge props into senses, then store per-seq
            (dolist (seq to-load)
              (let ((senses (sort (gethash seq gloss-by-seq) '< :key (lambda (s) (getf s :ord)))))
                ;; attach props grouped by sense-id
                (dolist (sense senses)
                  (let ((sid (getf sense :sense-id)))
                    (setf (getf sense :props)
                          (let ((bag (make-hash-table :test 'equal)))
                            (dolist (p (gethash sid props-by-id))
                              (push (cadr p) (gethash (car p) bag)))
                            (loop for k being the hash-keys of bag
                                  collect (cons k (nreverse (gethash k bag))))))
                    (remf sense :sense-id)))
                (memo-set *senses-table* seq senses)))))
      (length seqs)))))


(defun cache-reset ()
  "Clear all memo tables (call from add-errata / tests when DB may have changed)."
  (dolist (tbl (list *entry-table* *posi-table* *uk-table* *conj-data-table*))
    (sb-thread:with-mutex ((memo-table-lock tbl))
      (clrhash (memo-table-hash tbl))
      (setf (memo-table-hits tbl) 0
            (memo-table-misses tbl) 0)))
  (setf *conj-batch* nil)
  (clrhash *conj-prop-batch*)
  (clrhash *csr-batch*)
  t)

(defun cache-stats ()
  "Return a plist of per-table (hits misses) pairs."
  (list :entry (list (memo-table-hits *entry-table*) (memo-table-misses *entry-table*))
        :posi (list (memo-table-hits *posi-table*) (memo-table-misses *posi-table*))
        :uk (list (memo-table-hits *uk-table*) (memo-table-misses *uk-table*))
        :conj-data (list (memo-table-hits *conj-data-table*) (memo-table-misses *conj-data-table*))
        :senses (list (memo-table-hits *senses-table*) (memo-table-misses *senses-table*))))

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

;;; ---- S2: sentence-level batched prefetch ----

(defun prefetch-seq-data (seqs)
  "Batch-load S1 entry table for all SEQS in ONE IN query (the biggest
   per-candidate cost: get-dao entry). posi/uk/conj stay lazy (S1 memoizes
   them; prefetching them per-seq costs MORE round-trips than the lazy
   path since many substrings never score). Returns count prefetched."
  (let ((seqs (remove-duplicates (remove nil seqs))))
    (when seqs
      (let ((to-load (loop for s in seqs
                           unless (nth-value 1 (memo-get *entry-table* s))
                           collect s)))
        (when to-load
          (dolist (row (ichiran/dict::select-dao 'ichiran/dict::entry
                                                 (:in 'seq (:set to-load))))
            (let ((seq (ichiran/dict::seq row)))
              (memo-set *entry-table* seq row))))))
    (length seqs)))

(defun prefetch-conj-data (seqs)
  "Batch-load conjugation data for all SEQS in ~3 IN queries (the biggest
   per-candidate cost after entries: get-conj-data fires conj-source-reading
   + conj-prop per conjugation row). Fills a cache keyed by conj-id so
   get-conj-data's per-row queries become cache hits. Returns count of
   conj-ids prefetched."
  (let ((seqs (remove-duplicates (remove nil seqs))))
    (when seqs
      ;; 1. conjugation rows for these seqs (one query)
      (let ((conj-ids nil)
            (conj-by-id (make-hash-table :test 'eql)))
        (dolist (row (ichiran/dict::select-dao 'ichiran/dict::conjugation
                                               (:in 'seq (:set seqs))))
          (let ((id (ichiran/dict::id row)))
            (push id conj-ids)
            (setf (gethash id conj-by-id) row)))
        (when conj-ids
          ;; 2. conj-prop for all conj-ids (one query)
          (dolist (p (ichiran/dict::select-dao 'ichiran/dict::conj-prop
                                               (:in 'conj-id (:set conj-ids))))
            (push p (gethash (ichiran/dict::conj-id p) *conj-prop-batch*)))
          ;; 3. conj-source-reading for all conj-ids (one query)
          (dolist (r (ichiran/dict::select-dao 'ichiran/dict::conj-source-reading
                                               (:in 'conj-id (:set conj-ids))))
            (push r (gethash (ichiran/dict::conj-id r) *csr-batch*)))
          (setf *conj-batch* conj-by-id))
        (length conj-ids)))))
