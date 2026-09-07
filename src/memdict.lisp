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
  "Load the hot lookup tables into memory in chunks. Scope (kept memory-
   sane for a 24GB box): kana-text, kanji-text (text->rows + seq->rows),
   conjugation, conj-prop, conj-source-reading. The full entry table
   (2.5M fat DAOs) is NOT loaded — find-word needs text->rows, and entry
   rows are only used for n-kanji/n-kana stats which the text tables carry.
   Returns a stats plist."
  (let ((before (sb-kernel:dynamic-usage)))
    (ichiran/conn:with-db nil
      ;; kana-text / kanji-text: text -> list, seq -> list (chunked raw SQL)
      (loop for table in '("kana_text" "kanji_text")
            for hash-by-text = (if (equal table "kana_text") *kana-by-text* *kanji-by-text*)
            for hash-by-seq = (if (equal table "kana_text") *kana-by-seq* *kanji-by-seq*)
            do (loop with offset = 0
                     for rows = (ichiran/conn::query
                                 (format nil "SELECT * FROM ~a ORDER BY id LIMIT ~a OFFSET ~a"
                                         table chunk offset)
                                 :plists)
                     while rows
                     do (dolist (pl rows)
                          (let* ((txt (getf pl :text))
                                 (seq (getf pl :seq))
                                 (obj (cons table pl)))
                            (push obj (gethash txt hash-by-text))
                            (push obj (gethash seq hash-by-seq))))
                        (incf offset chunk)))
      ;; conjugation: seq -> list, from -> list (chunked)
      (loop with offset = 0
            for rows = (ichiran/conn::query
                        (format nil "SELECT * FROM conjugation ORDER BY id LIMIT ~a OFFSET ~a"
                                chunk offset)
                        :plists)
            while rows
            do (dolist (pl rows)
                 (push (cons :conjugation pl) (gethash (getf pl :seq) *conj-by-seq*))
                 (push (cons :conjugation pl) (gethash (getf pl :from) *conj-by-from*)))
               (incf offset chunk))
      ;; conj-prop: conj-id -> list
      (loop with offset = 0
            for rows = (ichiran/conn::query
                        (format nil "SELECT * FROM conj_prop ORDER BY id LIMIT ~a OFFSET ~a"
                                chunk offset)
                        :plists)
            while rows
            do (dolist (pl rows)
                 (push (cons :conj-prop pl) (gethash (getf pl :conj-id) *conj-prop-by-id*)))
               (incf offset chunk))
      ;; conj-source-reading: conj-id -> list
      (loop with offset = 0
            for rows = (ichiran/conn::query
                        (format nil "SELECT * FROM conj_source_reading ORDER BY id LIMIT ~a OFFSET ~a"
                                chunk offset)
                        :plists)
            while rows
            do (dolist (pl rows)
                 (push (cons :csr pl) (gethash (getf pl :conj-id) *csr-by-id*)))
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
  "Return list of (table . plist) conses for TEXT in kana_text/kanji_text."
  (gethash text (ecase table
                  (kana-text *kana-by-text*)
                  (kanji-text *kanji-by-text*))))

(defun memdict-find-by-seq (table seq)
  (gethash seq (ecase table
                 (kana-text *kana-by-seq*)
                 (kanji-text *kanji-by-seq*))))

(defun memdict-conj-by-seq (seq)
  (gethash seq *conj-by-seq*))

(defun memdict-conj-by-from (from)
  (gethash from *conj-by-from*))

(defun memdict-conj-prop (conj-id)
  (gethash conj-id *conj-prop-by-id*))

(defun memdict-conj-source-reading (conj-id)
  (gethash conj-id *csr-by-id*))
