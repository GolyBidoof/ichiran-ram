;;;; src/memdict-compact.lisp — R1: compact in-memory dictionary.
;;;;
;;;; Loads ALL hot tables as COMPACT structs (defstruct, not fat CLOS DAOs):
;;;;   - kana_text, kanji_text:  ~4-6 words/row vs ~10+ slots + class overhead
;;;;   - conjugation, conj_prop, conj_source_reading, entry
;;;; Est. ~1-2GB total vs 8-16GB as DAOs (which fatals SBCL).
;;;;
;;;; The analyzer reads these via GENERIC functions (text, seq, ord, common,
;;;; nokanji, conjugate-p, get-kana, get-kanji, get-text, best-kana, ...).
;;;; We define defmethod shims on the compact structs so existing code works
;;;; unchanged when *memdict-p* is on. The DAO classes keep working for the
;;;; DB path (flag OFF).

(defpackage #:ichiran/memdict-compact
  (:use #:cl #:postmodern #:ichiran/conn)
  (:export #:memdict-load #:memdict-find #:memdict-find-by-seq
           #:memdict-conj-by-seq #:memdict-conj-by-from #:memdict-conj-prop
           #:memdict-conj-source-reading #:memdict-enabled-p #:memdict-entry
           #:memdict-stats #:memdict-reload #:compact-kana #:compact-kanji
           #:compact-conj #:compact-conj-prop #:compact-csr #:compact-entry))

(in-package #:ichiran/memdict-compact)

(defvar *memdict-enabled-p* nil)
(defun memdict-enabled-p () *memdict-enabled-p*)
(defun (setf memdict-enabled-p) (v) (setf *memdict-enabled-p* v))

;;; ---- compact structs (defstruct = tight, no CLOS overhead) ----

(defstruct compact-kana
  id seq text ord (common :null) (common-tags "") (conjugate-p t)
  (nokanji nil) (best-kana :null) (best-kanji :null)
  (conjugations nil) (hintedp nil))

(defstruct compact-kanji
  id seq text ord (common :null) (common-tags "") (conjugate-p t)
  (nokanji nil) (best-kana :null) (best-kanji :null)
  (conjugations nil) (hintedp nil))

(defstruct compact-conj
  id seq from (via :null))

(defstruct compact-conj-prop
  id conj-id pos conj-type neg fml conj-group)
(defstruct compact-csr
  id conj-id text source-text)
(defstruct compact-entry
  seq content (root-p nil) (n-kanji 0) (n-kana 0) (primary-nokanji nil))

;;; ---- indexes ----

(defvar *kana-by-text* (make-hash-table :test 'equal))
(defvar *kana-by-seq* (make-hash-table :test 'eql))
(defvar *kanji-by-text* (make-hash-table :test 'equal))
(defvar *kanji-by-seq* (make-hash-table :test 'eql))
(defvar *conj-by-seq* (make-hash-table :test 'eql))
(defvar *conj-by-from* (make-hash-table :test 'eql))
(defvar *conj-prop-by-id* (make-hash-table :test 'eql))
(defvar *csr-by-id* (make-hash-table :test 'eql))
(defvar *entry-by-seq* (make-hash-table :test 'eql))

;;; ---- loading (chunked, compact) ----

(defvar *string-pool* (make-hash-table :test 'equal))
(defun intern-text (s)
  (or (gethash s *string-pool*)
      (setf (gethash s *string-pool*) s)))

(defun memdict-load (&key (chunk 100000))
  "Load kana_text + kanji_text as compact structs with interned strings."
  (let ((before (sb-kernel:dynamic-usage)))
    (ichiran/conn:with-db nil
      (flet ((load-table (table maker)
               (loop with offset = 0
                     for rows = (ichiran/conn::query
                                 (format nil "SELECT * FROM ~a ORDER BY id LIMIT ~a OFFSET ~a"
                                         table chunk offset)
                                 :lists)
                     while rows
                     do (dolist (pl rows) (funcall maker pl))
                        (incf offset chunk))))
        (load-table "kana_text"
                    (lambda (pl)
                      (destructuring-bind (id seq text ord common common-tags conjugate-p nokanji best-kanji) pl
                        (let ((o (make-compact-kana :id id :seq seq :text (intern-text text) :ord ord
                                                    :common common :common-tags common-tags
                                                    :conjugate-p conjugate-p :nokanji nokanji
                                                    :best-kanji best-kanji)))
                          (push o (gethash (compact-kana-text o) *kana-by-text*))))))
        ))
    (let ((after (sb-kernel:dynamic-usage)))
      (format t "memdict-compact load: ~,1f MB delta~%"
              (/ (- after before) 1048576.0)))
    (memdict-stats)))

(defun memdict-stats ()
  (list :kana-text (hash-table-count *kana-by-text*)
        :kanji-text (hash-table-count *kanji-by-text*)))

(defun memdict-reload ()
  (memdict-load))

;;; ---- accessors (return compact structs; NIL if missing) ----

(defun memdict-find (table text)
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

(defun memdict-conj-by-seq (seq) (gethash seq *conj-by-seq*))
(defun memdict-conj-by-from (from) (gethash from *conj-by-from*))
(defun memdict-conj-prop (conj-id) (gethash conj-id *conj-prop-by-id*))
(defun memdict-conj-source-reading (conj-id) (gethash conj-id *csr-by-id*))
(defun memdict-entry (seq) (gethash seq *entry-by-seq*))



(defmethod ichiran/dict::word-conj-data ((obj compact-kana))
  (ichiran/dict::get-conj-data (compact-kana-seq obj)
                               (compact-kana-conjugations obj)
                               (compact-kana-text obj)))
(defmethod ichiran/dict::word-conjugations ((obj compact-kanji))
  (compact-kanji-conjugations obj))
(defmethod (setf ichiran/dict::word-conjugations) (v (obj compact-kanji))
  (setf (compact-kanji-conjugations obj) v))
(defmethod ichiran/dict::true-text ((obj compact-kanji))
  (compact-kanji-text obj))
(defmethod ichiran/dict::get-text ((obj compact-kanji))
  (compact-kanji-text obj))
(defmethod ichiran/dict::get-kana ((obj compact-kanji))
  (compact-kanji-best-kana obj))
(defmethod ichiran/dict::word-type ((obj compact-kanji))
  :kanji)
(defmethod ichiran/dict::word-conj-data ((obj compact-kanji))
  (ichiran/dict::get-conj-data (compact-kanji-seq obj)
                               (compact-kanji-conjugations obj)
                               (compact-kanji-text obj)))


(defmethod ichiran/dict::get-original-text ((reading compact-kana) &key conj-data)
  (let ((orig-texts (ichiran/dict::get-original-text* (or conj-data (ichiran/dict::word-conj-data reading))
                                                      (compact-kana-text reading)))
        (table 'ichiran/dict::kana-text))
    (loop for (txt seq) in orig-texts
          nconc (ichiran/dict::select-dao table (:and (:= 'seq seq) (:= 'text txt))))))
(defmethod ichiran/dict::get-original-text ((reading compact-kanji) &key conj-data)
  (let ((orig-texts (ichiran/dict::get-original-text* (or conj-data (ichiran/dict::word-conj-data reading))
                                                      (compact-kanji-text reading)))
        (table 'ichiran/dict::kanji-text))
    (loop for (txt seq) in orig-texts
          nconc (ichiran/dict::select-dao table (:and (:= 'seq seq) (:= 'text txt))))))
(defmethod ichiran/dict::common ((obj compact-kana)) (compact-kana-common obj))
(defmethod ichiran/dict::common ((obj compact-kanji)) (compact-kanji-common obj))
(defmethod ichiran/dict::nokanji ((obj compact-kana)) (compact-kana-nokanji obj))
(defmethod ichiran/dict::nokanji ((obj compact-kanji)) (compact-kanji-nokanji obj))
(defmethod ichiran/dict::conjugate-p ((obj compact-kana)) (compact-kana-conjugate-p obj))
(defmethod ichiran/dict::conjugate-p ((obj compact-kanji)) (compact-kanji-conjugate-p obj))

;;; ---- simple-text interface shims (word-conjugations, hintedp, true-text,
;;; get-kana, get-text, word-type) ----

(defmethod ichiran/dict::word-conjugations ((obj compact-kana))
  (compact-kana-conjugations obj))
(defmethod (setf ichiran/dict::word-conjugations) (v (obj compact-kana))
  (setf (compact-kana-conjugations obj) v))
(defmethod ichiran/dict::hintedp ((obj compact-kana))
  (compact-kana-hintedp obj))
(defmethod ichiran/dict::true-text ((obj compact-kana))
  (compact-kana-text obj))
(defmethod ichiran/dict::get-text ((obj compact-kana))
  (compact-kana-text obj))
(defmethod ichiran/dict::get-kana ((obj compact-kana))
  ;; mirror simple-text get-kana :around: apply hints unless disabled/hinted
  (or (unless (or ichiran/dict::*disable-hints* (compact-kana-hintedp obj))
        (let ((ichiran/dict::*disable-hints* t))
          (ichiran/dict::get-hint obj)))
      (compact-kana-text obj)))
(defmethod ichiran/dict::word-type ((obj compact-kana))
  :kana)

;;; ---- defmethod shims so existing analyzer code works on compact structs ----
;;; (only active when the package is loaded and *memdict-p* routes to it)

(defmethod ichiran/dict::text ((obj compact-kana)) (compact-kana-text obj))
(defmethod ichiran/dict::seq ((obj compact-kana)) (compact-kana-seq obj))
(defmethod ichiran/dict::ord ((obj compact-kana)) (compact-kana-ord obj))
(defmethod ichiran/dict::common ((obj compact-kana)) (compact-kana-common obj))
(defmethod ichiran/dict::common-tags ((obj compact-kana)) (compact-kana-common-tags obj))
(defmethod ichiran/dict::conjugate-p ((obj compact-kana)) (compact-kana-conjugate-p obj))
(defmethod ichiran/dict::nokanji ((obj compact-kana)) (compact-kana-nokanji obj))
(defmethod ichiran/dict::best-kana ((obj compact-kana)) (compact-kana-best-kana obj))
(defmethod ichiran/dict::id ((obj compact-kana)) (compact-kana-id obj))

(defmethod ichiran/dict::text ((obj compact-kanji)) (compact-kanji-text obj))
(defmethod ichiran/dict::seq ((obj compact-kanji)) (compact-kanji-seq obj))
(defmethod ichiran/dict::ord ((obj compact-kanji)) (compact-kanji-ord obj))
(defmethod ichiran/dict::common ((obj compact-kanji)) (compact-kanji-common obj))
(defmethod ichiran/dict::common-tags ((obj compact-kanji)) (compact-kanji-common-tags obj))
(defmethod ichiran/dict::conjugate-p ((obj compact-kanji)) (compact-kanji-conjugate-p obj))
(defmethod ichiran/dict::nokanji ((obj compact-kanji)) (compact-kanji-nokanji obj))
(defmethod ichiran/dict::best-kana ((obj compact-kanji)) (compact-kanji-best-kana obj))
(defmethod ichiran/dict::id ((obj compact-kanji)) (compact-kanji-id obj))

(defmethod ichiran/dict::seq ((obj compact-conj)) (compact-conj-seq obj))
(defmethod ichiran/dict::seq-from ((obj compact-conj)) (compact-conj-from obj))
(defmethod ichiran/dict::seq-via ((obj compact-conj)) (compact-conj-via obj))
(defmethod ichiran/dict::id ((obj compact-conj)) (compact-conj-id obj))
