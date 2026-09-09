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
           #:make-compact-kana #:make-compact-kanji
           ;; R5 full-dict exports
           #:compact-sense #:compact-gloss #:compact-sense-prop
           #:make-compact-sense #:make-compact-gloss #:make-compact-sense-prop
           #:compact-sense-seq #:compact-sense-ord #:compact-sense-id
           #:compact-gloss-text #:compact-gloss-ord #:compact-sense-prop-tag
           #:compact-sense-prop-text #:compact-sense-prop-ord
           #:memdict-senses-raw #:memdict-non-arch-posi #:memdict-uk
           #:memdict-entry-by-seq #:memdict-conj-data #:memdict-has-conj-p))

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

;; R5: sense/gloss/sense-prop compact structs for the full in-RAM dict.
(defstruct compact-sense
  id seq ord)
(defstruct compact-gloss
  id sense-id text ord)
(defstruct compact-sense-prop
  id sense-id tag text ord)

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
;; R5: full-dict indexes
(defvar *sense-by-seq* (make-hash-table :test 'eql) "seq -> list of compact-sense")
(defvar *gloss-by-sense* (make-hash-table :test 'eql) "sense-id -> list of compact-gloss")
(defvar *prop-by-sense* (make-hash-table :test 'eql) "sense-id -> list of compact-sense-prop")

;;; ---- loading (chunked, compact) ----

(defvar *string-pool* (make-hash-table :test 'equal))
(defun intern-text (s)
  (or (gethash s *string-pool*)
      (setf (gethash s *string-pool*) s)))

(defun memdict-load (&key (chunk 100000) conn
                          (tables '("kana_text" "kanji_text" "entry" "conjugation"
                                    "conj_prop" "conj_source_reading" "sense" "gloss"
                                    "sense_prop")))
  "Load TABLES as compact structs with interned strings. Default: ALL tables
   (the full in-RAM dictionary; ~12-16GB with indexes — for a 64GB host).
   Pass :tables '(\"kana_text\" \"kanji_text\") for the light serving core.
   CONN is a postmodern connection spec (defaults to ichiran/conn's
   *connection* when that package is loaded)."
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
                            (push o (gethash (compact-kana-text o) *kana-by-text*))
                            (push o (gethash (compact-kana-seq o) *kana-by-seq*)))))))
        (when (member "kanji_text" tables :test 'equal)
          (format t "memdict-compact: loading kanji_text...~%")
          (load-table "kanji_text"
                      (lambda (pl)
                        (destructuring-bind (id seq text ord common common-tags conjugate-p nokanji best-kana) pl
                          (let ((o (make-compact-kanji :id id :seq seq :text (intern-text text) :ord ord
                                                       :common common :common-tags common-tags
                                                       :conjugate-p conjugate-p :nokanji nokanji
                                                       :best-kana best-kana)))
                            (push o (gethash (compact-kanji-text o) *kanji-by-text*))
                            (push o (gethash (compact-kanji-seq o) *kanji-by-seq*)))))))
        (when (member "entry" tables :test 'equal)
          (format t "memdict-compact: loading entry...~%")
          (load-table "entry"
                      (lambda (pl)
                        (destructuring-bind (seq content root-p n-kanji n-kana primary-nokanji) pl
                          (setf (gethash seq *entry-by-seq*)
                                (make-compact-entry :seq seq :content (intern-text content) :root-p root-p
                                                    :n-kanji n-kanji :n-kana n-kana
                                                    :primary-nokanji primary-nokanji))))))
        (when (member "conjugation" tables :test 'equal)
          (format t "memdict-compact: loading conjugation...~%")
          (load-table "conjugation"
                      (lambda (pl)
                        (destructuring-bind (id seq from via) pl
                          (let ((o (make-compact-conj :id id :seq seq :from from :via via)))
                            (push o (gethash seq *conj-by-seq*))
                            (push o (gethash from *conj-by-from*)))))))
        (when (member "conj_prop" tables :test 'equal)
          (format t "memdict-compact: loading conj_prop...~%")
          (load-table "conj_prop"
                      (lambda (pl)
                        (destructuring-bind (id conj-id conj-type pos neg fml) pl
                          (push (make-compact-conj-prop :id id :conj-id conj-id :conj-type conj-type
                                                        :pos (intern-text pos) :neg neg :fml fml)
                                (gethash conj-id *conj-prop-by-id*))))))
        (when (member "conj_source_reading" tables :test 'equal)
          (format t "memdict-compact: loading conj_source_reading...~%")
          (load-table "conj_source_reading"
                      (lambda (pl)
                        (destructuring-bind (id conj-id text source-text) pl
                          (push (make-compact-csr :id id :conj-id conj-id :text (intern-text text)
                                                  :source-text (intern-text source-text))
                                (gethash conj-id *csr-by-id*))))))
        (when (member "sense" tables :test 'equal)
          (format t "memdict-compact: loading sense...~%")
          (load-table "sense"
                      (lambda (pl)
                        (destructuring-bind (id seq ord) pl
                          (push (make-compact-sense :id id :seq seq :ord ord)
                                (gethash seq *sense-by-seq*))))))
        (when (member "gloss" tables :test 'equal)
          (format t "memdict-compact: loading gloss...~%")
          (load-table "gloss"
                      (lambda (pl)
                        (destructuring-bind (id sense-id text ord) pl
                          (push (make-compact-gloss :id id :sense-id sense-id :text (intern-text text) :ord ord)
                                (gethash sense-id *gloss-by-sense*))))))
        (when (member "sense_prop" tables :test 'equal)
          (format t "memdict-compact: loading sense_prop...~%")
          (load-table "sense_prop"
                      (lambda (pl)
                        (destructuring-bind (id sense-id tag text ord) pl
                          (let ((sp (make-compact-sense-prop :id id :sense-id sense-id
                                                             :tag (intern-text tag)
                                                             :text (intern-text text) :ord ord)))
                            (push sp (gethash sense-id *prop-by-sense*)))))))))
    (let ((after (sb-kernel:dynamic-usage)))
      (format t "memdict-compact load: ~,1f MB delta~%"
              (/ (- after before) 1048576.0)))
    (memdict-stats)))

(defun memdict-stats ()
  (list :kana-text (hash-table-count *kana-by-text*)
        :kanji-text (hash-table-count *kanji-by-text*)
        :entry (hash-table-count *entry-by-seq*)
        :conjugation (hash-table-count *conj-by-seq*)
        :conj-prop (hash-table-count *conj-prop-by-id*)
        :conj-source-reading (hash-table-count *csr-by-id*)
        :sense (hash-table-count *sense-by-seq*)
        :gloss (hash-table-count *gloss-by-sense*)
        :sense-prop (hash-table-count *prop-by-sense*)))

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

;;; ---- R5: RAM lookups mirroring the analyzer's DB queries ----
;;; These return data in the same shape the DB queries return, so the
;;; analyzer can serve them from RAM behind *memdict-p* with identical
;;; behavior.

(defun memdict-entry-by-seq (seq)
  "Return the compact-entry for SEQ, or NIL."
  (gethash seq *entry-by-seq*))

(defun memdict-senses-by-seq (seq)
  "Return list of compact-sense for SEQ (ordered by ord)."
  (sort (copy-list (gethash seq *sense-by-seq*)) '< :key 'compact-sense-ord))

(defun memdict-glosses-by-sense (sense-id)
  "Return list of (ord . text) for a sense, ordered by ord (like the DB
   string_agg group)."
  (let ((glosses (gethash sense-id *gloss-by-sense*)))
    (sort (mapcar (lambda (g) (cons (compact-gloss-ord g) (compact-gloss-text g)))
                  glosses)
          '< :key 'car)))

(defun memdict-props-by-sense (sense-id)
  "Return list of (tag ord text) for a sense."
  (let ((props (gethash sense-id *prop-by-sense*)))
    (mapcar (lambda (p) (list (compact-sense-prop-tag p)
                              (compact-sense-prop-ord p)
                              (compact-sense-prop-text p)))
            props)))


(defun join-strings (separator strings)
  "Join STRINGS with SEPARATOR (bare-load-safe local helper)."
  (with-output-to-string (out)
    (loop for s in strings
          for first = t then nil
          do (unless first (princ separator out))
             (princ s out))))

(defun memdict-senses-raw (seq)
  "Mirror ichiran/dict::get-senses-raw's return: list of
   (:ord N :gloss STR :props ((tag . texts)...)). Filters sense_prop to the
   same tags the DB path uses (pos s_inf stagk stagr field)."
  (loop for sense in (memdict-senses-by-seq seq)
        for sense-id = (compact-sense-id sense)
        for gloss = (let ((gs (memdict-glosses-by-sense sense-id)))
                      (if gs
                          (join-strings "; " (mapcar 'cdr gs))
                          ""))
        for props = (let ((bag (make-hash-table :test 'equal)))
                      (dolist (p (memdict-props-by-sense sense-id))
                        (when (member (car p) '("pos" "s_inf" "stagk" "stagr" "field") :test 'equal)
                          (let ((tag (car p)) (text (caddr p)))
                            (push text (gethash tag bag)))))
                      (loop for tag being the hash-keys of bag
                            collect (cons tag (nreverse (gethash tag bag)))))
        collect (list :ord (compact-sense-ord sense) :gloss gloss :props props)))

(defun memdict-non-arch-posi (seq-set)
  "Mirror ichiran/dict::get-non-arch-posi: distinct pos texts for seqs in
   SEQ-SET, excluding senses tagged arch/obsc/rare."
  (let ((arch (make-hash-table :test 'eql)))
    (dolist (seq seq-set)
      (dolist (sense (gethash seq *sense-by-seq*))
        (dolist (p (gethash (compact-sense-id sense) *prop-by-sense*))
          (when (and (equal (compact-sense-prop-tag p) "misc")
                     (member (compact-sense-prop-text p) '("arch" "obsc" "rare") :test 'equal))
            (setf (gethash (compact-sense-id sense) arch) t)))))
    (let ((result nil))
      (dolist (seq seq-set)
        (dolist (sense (gethash seq *sense-by-seq*))
          (unless (gethash (compact-sense-id sense) arch)
            (dolist (p (gethash (compact-sense-id sense) *prop-by-sense*))
              (when (and (equal (compact-sense-prop-tag p) "pos")
                         (not (member (compact-sense-prop-text p) result :test 'equal)))
                (push (compact-sense-prop-text p) result))))))
      (nreverse result))))

(defun memdict-uk (seq-set)
  "Mirror select-dao sense-prop uk: list of (seq . sense-prop) rows for seqs
   in SEQ-SET with tag misc text uk."
  (loop for seq in seq-set
        nconc (loop for sense in (gethash seq *sense-by-seq*)
                    nconc (loop for p in (gethash (compact-sense-id sense) *prop-by-sense*)
                                when (and (equal (compact-sense-prop-tag p) "misc")
                                          (equal (compact-sense-prop-text p) "uk"))
                                collect (cons seq p)))))

(defun memdict-has-conj-p (seq)
  "T whether SEQ has any conjugation rows."
  (not (null (gethash seq *conj-by-seq*))))

(defun memdict-conj-data (seq &optional from/conj-ids texts)
  "Mirror ichiran/dict::get-conj-data's return: list of
   (list conj fprops src-map) — actually mirror the shape used by
   select-conjs-and-props: list of (conj fprops val)."
  ;; Simplest faithful shape: return (list conj) where conj is a compact-conj,
  ;; plus conj-props and csr rows; the caller (dict.lisp) will be adapted.
  (let ((conjs (if (null from/conj-ids)
                   (gethash seq *conj-by-seq*)
                   (if (listp from/conj-ids)
                       (loop for c in (gethash seq *conj-by-seq*)
                             when (member (compact-conj-id c) from/conj-ids)
                               collect c)
                       (loop for c in (gethash seq *conj-by-seq*)
                             when (= (compact-conj-from c) from/conj-ids)
                               collect c)))))
    (loop for conj in conjs
          collect (list conj
                        (gethash (compact-conj-id conj) *conj-prop-by-id*)
                        (gethash (compact-conj-id conj) *csr-by-id*)))))
