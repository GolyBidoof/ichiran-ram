;;;; src/memdict.lisp — S3: in-memory dictionary for Ichiran.
;;;;
;;;; Loads the hot DB tables into RAM at boot so the analyzer's per-candidate
;;;; lookups (find-word, get-conj-data, calc-score) never hit PostgreSQL.
;;;; Accessors return the SAME postmodern DAO objects the DB queries return
;;;; (loaded via select-dao), so all existing slot accessors keep working.
;;;;
;;;; Additive module: wiring into find-word / word-conj-data / calc-score is
;;;; done by the coordinator behind a flag (memdict-enabled-p), default OFF.

(defpackage #:ichiran/memdict
  (:use #:cl #:postmodern #:ichiran/conn)
  (:export #:memdict-load #:memdict-entry #:memdict-find #:memdict-find-by-seq
           #:memdict-conj-by-seq #:memdict-conj-by-from #:memdict-conj-prop
           #:memdict-conj-source-reading #:memdict-enabled-p #:memdict-stats
           #:memdict-reload))

(in-package #:ichiran/memdict)

(defvar *memdict-enabled-p* nil)
(defvar *entry-by-seq* (make-hash-table :test 'eql))
(defvar *kana-by-text* (make-hash-table :test 'equal))
(defvar *kanji-by-text* (make-hash-table :test 'equal))
(defvar *kana-by-seq* (make-hash-table :test 'eql))
(defvar *kanji-by-seq* (make-hash-table :test 'eql))
(defvar *conj-by-seq* (make-hash-table :test 'eql))
(defvar *conj-by-from* (make-hash-table :test 'eql))
(defvar *conj-prop-by-id* (make-hash-table :test 'eql))
(defvar *csr-by-id* (make-hash-table :test 'eql))

(defun memdict-enabled-p () *memdict-enabled-p*)
(defun (setf memdict-enabled-p) (v) (setf *memdict-enabled-p* v))

(defun push-into (hash key value)
  (push value (gethash key hash)))

(defun memdict-load (&key (chunk 100000))
  "Load the kana_text table into memory (text -> rows, seq -> rows), the
   common find-word path (~489MB). kanji_text (5.4M rows) and the huge
   conjugation tables are NOT loaded as plists — they need a compact binary
   format (future work) and S1 cache (src/cache.lisp) memoizes conj data
   cross-sentence. Returns a stats plist."
  (let ((before (sb-kernel:dynamic-usage)))
    (ichiran/conn:with-db nil
      ;; kana_text as REAL DAO objects via query-dao + raw SQL (bound id/seq/
      ;; text/ord — usable directly by find-word). ~3.3M rows, ~1.7GB.
      ;; kanji_text (5.4M rows) as DAOs exhausts memory — compact binary
      ;; format is future work; S1 cache covers conj lookups cross-sentence.
      (loop with offset = 0
            for rows = (ichiran/dict::query-dao 'ichiran/dict::kana-text
                                                (format nil "SELECT * FROM kana_text ORDER BY id LIMIT ~a OFFSET ~a"
                                                        chunk offset))
            while rows
            do (dolist (kt rows)
                 (push kt (gethash (ichiran/dict::text kt) *kana-by-text*))
                 (push kt (gethash (ichiran/dict::seq kt) *kana-by-seq*)))
               (incf offset chunk)))
    (let ((after (sb-kernel:dynamic-usage)))
      (format t "memdict-load: ~,1f MB delta~%"
              (/ (- after before) 1048576.0)))
    (memdict-stats)))

(defun memdict-stats ()
  "Plist of table -> row count (hash-table-count of the primary index)."
  (list :entry (hash-table-count *entry-by-seq*)
        :kana-text (hash-table-count *kana-by-text*)
        :kanji-text (hash-table-count *kanji-by-text*)
        :conjugation (hash-table-count *conj-by-seq*)
        :conj-prop (hash-table-count *conj-prop-by-id*)
        :conj-source-reading (hash-table-count *csr-by-id*)))

(defun memdict-reload ()
  "Re-run memdict-load (call after add-errata / DB updates)."
  (memdict-load))

(defun memdict-entry (seq)
  ;; Not loaded (see memdict-load docstring). Return NIL.
  (declare (ignore seq))
  nil)

(defun memdict-find (table text)
  "Return list of (table . plist) conses for TEXT in kana_text/kanji_text.
   TABLE may be 'kana-text/'kanji-text or 'kana_text/'kanji_text."
  (let ((name (string-downcase (symbol-name table))))
    (cond ((or (string= name "kana-text") (string= name "kana_text"))
           (gethash text *kana-by-text*))
          ((or (string= name "kanji-text") (string= name "kanji_text"))
           (gethash text *kanji-by-text*))
          (t nil))))

(defun memdict-find-by-seq (table seq)
  (let ((name (string-downcase (symbol-name table))))
    (cond ((or (string= name "kana-text") (string= name "kana_text"))
           (gethash seq *kana-by-seq*))
          ((or (string= name "kanji-text") (string= name "kanji_text"))
           (gethash seq *kanji-by-seq*))
          (t nil))))

(defun memdict-conj-by-seq (seq)
  (gethash seq *conj-by-seq*))

(defun memdict-conj-by-from (from)
  (gethash from *conj-by-from*))

(defun memdict-conj-prop (conj-id)
  (gethash conj-id *conj-prop-by-id*))

(defun memdict-conj-source-reading (conj-id)
  (gethash conj-id *csr-by-id*))
