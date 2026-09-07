;;;; src/memdict-compact.lisp — R1/R4: compact in-memory dictionary.
;;;;
;;;; Loads hot tables as COMPACT structs (defstruct, not fat CLOS DAOs):
;;;;   - kana_text, kanji_text:  ~4-6 words/row vs ~10+ slots + class overhead
;;;;   - conjugation, conj_prop, conj_source_reading, entry
;;;;
;;;; DECOUPLED for R4 (zero-DB serving): this file depends ONLY on
;;;; postmodern. It no longer :use's :ichiran/conn or :ichiran/dict, so it
;;;; can be loaded into a MINIMAL SBCL image (quickload :postmodern only) for
;;;; the dedicated serving core. All analyzer shims (defmethod on ichiran/dict
;;;; generics) are conditional on the ichiran/dict package being present; when
;;;; loading bare they are skipped, and the standalone API (memdict-find,
;;;; memdict-find-by-seq, ...) remains for the serving core to call directly.

(defpackage #:ichiran/memdict-compact
  (:use #:cl #:postmodern)
  (:export #:memdict-load #:memdict-find #:memdict-find-by-seq
           #:memdict-conj-by-seq #:memdict-conj-by-from #:memdict-conj-prop
           #:memdict-conj-source-reading #:memdict-enabled-p #:memdict-entry
           #:memdict-stats #:memdict-reload #:compact-kana #:compact-kanji
           #:compact-conj #:compact-conj-prop #:compact-csr #:compact-entry
           #:compact-kana-text #:compact-kanji-text #:compact-kana-seq
           #:compact-kanji-seq #:compact-kana-ord #:compact-kanji-ord
           #:compact-kana-best-kana #:compact-kanji-best-kana
           #:make-compact-kana #:make-compact-kanji))

(in-package #:ichiran/memdict-compact)

(defvar *memdict-enabled-p* nil)
(defun memdict-enabled-p () *memdict-enabled-p*)
(defun (setf memdict-enabled-p) (v) (setf *memdict-enabled-p* v))

;;; ---- connection spec helper (bare-load friendly) ----
;;; When :ichiran/conn is loaded, memdict-load uses its *connection* by
;;; default; otherwise the caller must pass :conn (a postmodern spec list).

(defun default-conn ()
  (let ((pkg (find-package :ichiran/conn)))
    (if pkg
        (symbol-value (find-symbol "*CONNECTION*" pkg))
        (error "memdict-load needs a :conn spec (no ichiran/conn loaded)"))))

(defmacro with-db-connection ((spec) &body body)
  "Run BODY with a postmodern connection to SPEC. SPEC may be NIL (use
   ichiran/conn:*connection* if available, else error)."
  `(let ((conn (or ,spec (default-conn))))
     (postmodern:with-connection conn
       ,@body)))

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

(defun memdict-load (&key (chunk 100000) conn (tables '("kana_text" "kanji_text")))
  "Load TABLES as compact structs with interned strings. Default tables:
   kana_text + kanji_text. CONN is a postmodern connection spec (defaults to
   ichiran/conn's *connection* when that package is loaded)."
  (let ((before (sb-kernel:dynamic-usage)))
    (with-db-connection (conn)
      (flet ((load-table (table maker)
               (loop with offset = 0
                     for rows = (query (format nil "SELECT * FROM ~a ORDER BY id LIMIT ~a OFFSET ~a"
                                               table chunk offset)
                                       :lists)
                     while rows
                     do (dolist (pl rows) (funcall maker pl))
                        (incf offset chunk))))
        (when (member "kana_text" tables :test 'equal)
          (format t "memdict-compact: loading kana_text...~%")
          (load-table "kana_text"
                      (lambda (pl)
                        (destructuring-bind (id seq text ord common common-tags conjugate-p nokanji best-kanji) pl
                          (let ((o (make-compact-kana :id id :seq seq :text (intern-text text) :ord ord
                                                      :common common :common-tags common-tags
                                                      :conjugate-p conjugate-p :nokanji nokanji
                                                      :best-kanji best-kanji)))
                            (push o (gethash (compact-kana-text o) *kana-by-text*)))))))
        (when (member "kanji_text" tables :test 'equal)
          (format t "memdict-compact: loading kanji_text...~%")
          (load-table "kanji_text"
                      (lambda (pl)
                        (destructuring-bind (id seq text ord common common-tags conjugate-p nokanji best-kana) pl
                          (let ((o (make-compact-kanji :id id :seq seq :text (intern-text text) :ord ord
                                                       :common common :common-tags common-tags
                                                       :conjugate-p conjugate-p :nokanji nokanji
                                                       :best-kana best-kana)))
                            (push o (gethash (compact-kanji-text o) *kanji-by-text*)))))))))
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

