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
           #:memdict-entry-by-seq #:memdict-conj-data #:memdict-has-conj-p
           #:memdict-reset #:memdict-loaded-tables
           ;; R6 residual-query helpers (reading-str/short-sense/conj lists)
           #:memdict-text-by-seq #:memdict-find-by-seq-text
           #:memdict-rows-by-seq #:memdict-select-conjs #:memdict-conj-props
           #:memdict-short-sense-str #:memdict-normalize-order
           ;; R6 trie-in-core
           #:memdict-build-trie #:memdict-trie #:*trie*
           ;; R6 counters (scalar queries; DAO-row readings stay on DB)
           #:memdict-counter-ids #:memdict-counter-stags
           ;; R6b: row accessors API consumers may need (uk/conj paths)
           #:compact-kana-id #:compact-kanji-id
           #:compact-conj-id #:compact-conj-seq #:compact-conj-from #:compact-conj-via
           #:compact-sense-prop-id #:compact-sense-prop-sense-id #:compact-sense-prop-seq))

(in-package #:ichiran/memdict-compact)

(defvar *memdict-enabled-p* nil)
(defun memdict-enabled-p () *memdict-enabled-p*)
(defun (setf memdict-enabled-p) (v) (setf *memdict-enabled-p* v))

;; Which tables have been loaded (for partial loads: lookups on unloaded
;; tables must fall back to the DB rather than return "no data").
(defvar *loaded-tables* nil)
(defun memdict-loaded-tables ()
  "Return the list of table names currently loaded in RAM."
  *loaded-tables*)

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
  id sense-id tag text ord seq)

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

(defun memdict-normalize-order ()
  "Stable-sort every push-built per-key list into ascending id order,
   mirroring the DB select-dao row order. Called once at the end of
   memdict-load (O(N log n) over small per-key lists). Idempotent and
   order-correct regardless of load history: unlike nreverse, sorting is
   a fixed point, so incremental/second loads cannot un-flip previously
   normalized lists (re-loading an already-loaded table still duplicates
   rows — pre-existing behavior, out of scope — but order stays ascending
   id). Gloss display order is re-sorted by ord at read time in
   memdict-glosses-by-sense, so id order at rest is fine.
   Without this, RAM lookups return reversed-DB order
   and scoring tiebreaks (e.g. te-iru しています → して+います vs してい+ます)
   can pick a different segmentation than the DB path."
  (flet ((sort-ht (ht key)
           (maphash (lambda (k v) (setf (gethash k ht) (stable-sort v '< :key key))) ht)))
    (sort-ht *kana-by-text* #'compact-kana-id)
    (sort-ht *kana-by-seq* #'compact-kana-id)
    (sort-ht *kanji-by-text* #'compact-kanji-id)
    (sort-ht *kanji-by-seq* #'compact-kanji-id)
    (sort-ht *conj-by-seq* #'compact-conj-id)
    (sort-ht *conj-by-from* #'compact-conj-id)
    (sort-ht *conj-prop-by-id* #'compact-conj-prop-id)
    (sort-ht *csr-by-id* #'compact-csr-id)
    (sort-ht *sense-by-seq* #'compact-sense-id)
    (sort-ht *gloss-by-sense* #'compact-gloss-id)
    (sort-ht *prop-by-sense* #'compact-sense-prop-id))
  t)

(defun memdict-table-row-count (table)
  "In-RAM row total for TABLE (sums per-key lists; entry is one row per seq)."
  (flet ((sum-hash (ht)
           (let ((n 0))
             (maphash (lambda (k v) (declare (ignore k)) (incf n (length v))) ht)
             n)))
    (cond ((equal table "kana_text") (sum-hash *kana-by-text*))
          ((equal table "kanji_text") (sum-hash *kanji-by-text*))
          ((equal table "entry") (hash-table-count *entry-by-seq*))
          ((equal table "conjugation") (sum-hash *conj-by-seq*))
          ((equal table "conj_prop") (sum-hash *conj-prop-by-id*))
          ((equal table "conj_source_reading") (sum-hash *csr-by-id*))
          ((equal table "sense") (sum-hash *sense-by-seq*))
          ((equal table "gloss") (sum-hash *gloss-by-sense*))
          ((equal table "sense_prop") (sum-hash *prop-by-sense*))
          (t nil))))

(defun memdict-verify-counts (tables get-db-count)
  "Compare in-RAM row totals against the DB for TABLES (fresh loads only —
   incremental reloads duplicate push-built lists). GET-DB-COUNT is a function
   of table name. Prints VERIFY_OK/VERIFY_FAIL lines; returns T iff all match."
  (let ((ok t))
    (dolist (table tables ok)
      (let ((ram (memdict-table-row-count table))
            (db (funcall get-db-count table)))
        (cond ((null ram) (format t "MEMDICT-VERIFY-SKIP: ~a (unknown table)~%" table))
              ((= ram db) (format t "MEMDICT-VERIFY-OK: ~a ram=~a db=~a~%" table ram db))
              (t (setf ok nil)
                 (format t "MEMDICT-VERIFY-FAIL: ~a ram=~a db=~a (rows missing or duplicated!)~%"
                         table ram db)))))))

(defun memdict-load (&key (chunk 100000) conn
                          (tables '("kana_text" "kanji_text" "entry" "conjugation"
                                    "conj_prop" "conj_source_reading" "sense" "gloss"
                                    "sense_prop")))
  "Load TABLES as compact structs with interned strings. Default: ALL tables
   (the full in-RAM dictionary; ~12-16GB with indexes — for a 64GB host).
   Pass :tables '(\"kana_text\" \"kanji_text\") for the light serving core.
   CONN is a postmodern connection spec (defaults to ichiran/conn's
   *connection* when that package is loaded).
   Expects fresh state (call memdict-reset first) for memdict-verify-counts
   to be meaningful: re-loading an already-loaded table duplicates rows
   (pre-existing push-accumulation behavior, out of scope to fix here)."
  (let ((before (sb-kernel:dynamic-usage)))
    (with-db-connection (conn)
      (flet ((load-table (table maker &key (order-by "id"))
               ;; ORDER BY a unique key is REQUIRED (not just nice): without
               ;; it, Postgres may parallelize/reshuffle the scan and LIMIT/
               ;; OFFSET pages overlap — rows load twice and others never
               ;; load (measured: entry stopped at 1.55M/2.5M with silent
               ;; missing rows). entry has no id column; seq is its key.
               (loop with offset = 0
                     for rows = (query (format nil "SELECT * FROM ~a ORDER BY ~a LIMIT ~a OFFSET ~a"
                                               table order-by chunk offset)
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
                                                    :primary-nokanji primary-nokanji))))
                      :order-by "seq"))
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
                        (destructuring-bind (id tag sense-id text ord seq) pl
                          (let ((sp (make-compact-sense-prop :id id :sense-id sense-id
                                                             :tag (intern-text tag)
                                                             :text (intern-text text) :ord ord
                                                             :seq seq)))
                            (push sp (gethash sense-id *prop-by-sense*)))))))))
    ;; Normalize per-key list order to ascending id (mirror DB select-dao).
    ;; Loads push rows, so every list is reversed-id at this point.
    (memdict-normalize-order)
    ;; Verify in-RAM row totals against the DB. Fresh loads only:
    ;; incremental reloads of an already-loaded table duplicate push-built
    ;; lists, so re-verify after memdict-reset + full load.
    ;; Own connection scope: the loader's with-db-connection has closed by
    ;; now (and in bare-core builds there is no ambient connection at all).
    (with-db-connection (conn)
      (memdict-verify-counts tables
                             (lambda (table)
                               (query (format nil "SELECT count(*) FROM ~a" table)
                                      :single))))
    (let ((after (sb-kernel:dynamic-usage)))
      (format t "memdict-compact load: ~,1f MB delta~%"
              (/ (- after before) 1048576.0)))
    (setf *loaded-tables* (union *loaded-tables* tables :test 'equal))
    (memdict-stats)))

(defun memdict-reset ()
  "Clear ALL loaded dict data (for benchmarking partial loads)."
  (clrhash *kana-by-text*) (clrhash *kana-by-seq*)
  (clrhash *kanji-by-text*) (clrhash *kanji-by-seq*)
  (clrhash *entry-by-seq*) (clrhash *conj-by-seq*) (clrhash *conj-by-from*)
  (clrhash *conj-prop-by-id*) (clrhash *csr-by-id*)
  (clrhash *sense-by-seq*) (clrhash *gloss-by-sense*) (clrhash *prop-by-sense*)
  (clrhash *string-pool*)
  (setf *loaded-tables* nil)
  t)

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
  "Fresh reload with default tables: reset all RAM state, then memdict-load."
  (memdict-reset)
  (memdict-load))

;;; ---- accessors (return compact structs; NIL if missing) ----

;;; ---- R6b: copy-on-return (analyzer mutates readings) ----
;;; The analyzer setfs word-conjugations/hintedp on readings and nconcs
;;; find-word results (find-word-full). Returning aliased index lists or
;;; shared structs would corrupt the RAM dict across sentences (measured:
;;; suffix readings and compounds accumulated in *kana-by-text* lists until
;;; a compound seq-list leaked into an IN query: 42883 integer = record).
;;; So every kana/kanji row crossing to the analyzer is a fresh copy.
;;; (Entry/conj/prop structs are never mutated by the analyzer; their lists
;;; are still copied where the caller might nconc.)

(defun memdict-copy-row (row)
  "Fresh copy of a compact-kana/kanji row (mutable slots reset by copy)."
  (cond ((compact-kana-p row) (copy-compact-kana row))
        ((compact-kanji-p row) (copy-compact-kanji row))
        (t row)))

(defun memdict-copy-rows (rows)
  "Fresh list spine AND fresh row copies."
  (mapcar 'memdict-copy-row rows))

(defun memdict-find (table text)
  "Rows for TEXT (fresh copies; the analyzer mutates readings). NIL if none."
  (let ((name (string-downcase (symbol-name table))))
    (cond ((or (string= name "kana-text") (string= name "kana_text"))
           (memdict-copy-rows (gethash text *kana-by-text*)))
          ((or (string= name "kanji-text") (string= name "kanji_text"))
           (memdict-copy-rows (gethash text *kanji-by-text*)))
          (t nil))))

(defun memdict-find-by-seq (table seq)
  "Rows for SEQ (fresh copies; the analyzer mutates readings). NIL if none."
  (let ((name (string-downcase (symbol-name table))))
    (cond ((or (string= name "kana-text") (string= name "kana_text"))
           (memdict-copy-rows (gethash seq *kana-by-seq*)))
          ((or (string= name "kanji-text") (string= name "kanji_text"))
           (memdict-copy-rows (gethash seq *kanji-by-seq*)))
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
  (stable-sort (copy-list (gethash seq *sense-by-seq*)) '< :key 'compact-sense-ord))

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
   same tags the DB path uses (pos s_inf stagk stagr field).
   Deterministic order matching the DB's ORDER BY sense.ord, tag, prop.ord:
   senses by ord, tags sorted, texts in prop-ord order."
  (loop for sense in (memdict-senses-by-seq seq)
        for sense-id = (compact-sense-id sense)
        for gloss = (let ((gs (memdict-glosses-by-sense sense-id)))
                      (if gs
                          (join-strings "; " (mapcar 'cdr gs))
                          ""))
        for props = (let ((bag (make-hash-table :test 'equal)))
                      (dolist (p (sort (copy-list (gethash sense-id *prop-by-sense*))
                                       '< :key 'compact-sense-prop-ord))
                        (when (member (compact-sense-prop-tag p)
                                      '("pos" "s_inf" "stagk" "stagr" "field") :test 'equal)
                          (push (compact-sense-prop-text p)
                                (gethash (compact-sense-prop-tag p) bag))))
                      (sort (loop for tag being the hash-keys of bag
                                  collect (cons tag (nreverse (gethash tag bag))))
                            'string< :key 'car))
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
  "Mirror select-dao sense-prop uk: list of compact-sense-prop rows for seqs
   in SEQ-SET with tag misc text uk (callers use sense-id on the rows)."
  (loop for seq in seq-set
        nconc (loop for sense in (gethash seq *sense-by-seq*)
                    nconc (loop for p in (gethash (compact-sense-id sense) *prop-by-sense*)
                                when (and (equal (compact-sense-prop-tag p) "misc")
                                          (equal (compact-sense-prop-text p) "uk"))
                                collect p))))

(defun memdict-kanji-kana-fallback (kanji-text seq)
  "RAM fallback for a kanji row with NULL best_kana (mirrors
   ichiran/dict::get-kanji-kana-old's last-resort): return the first kana
   reading for SEQ from the RAM kana-by-seq index. NIL if kana_text is not
   loaded for SEQ (caller falls back to the DB path)."
  (declare (ignorable kanji-text))
  (let ((rows (gethash seq *kana-by-seq*)))
    (when rows
      (compact-kana-text (car rows)))))

;;; ---- R6: residual-query helpers (reading-str / short-sense / conj lists) ----
;;; These serve the queries the R5 wiring left on the DB (see query-log
;;; enumeration): reading-str-seq (2/word), select-conjs, short-sense-str,
;;; get-original-text's seq+text probes. Table-parameterized helpers self-gate
;;; on *loaded-tables* (kana-only cores must still serve kana sides).

(defun memdict-table-loaded-p (table)
  "T when TABLE (string) was loaded into RAM."
  (member table *loaded-tables* :test 'equal))

(defun memdict-text-by-seq (table seq &optional (ord 0))
  "First TEXT for SEQ with ORD in TABLE. TABLE is kana-text/kanji-text (symbol
   or string). Mirrors reading-str-seq and entry get-kana/get-text/get-kanji
   (seq + ord 0 probes). NIL when TABLE isn't loaded (caller uses the DB)."
  (let ((name (string-downcase (symbol-name table))))
    (cond ((and (or (string= name "kana-text") (string= name "kana_text"))
                (memdict-table-loaded-p "kana_text"))
           (loop for r in (gethash seq *kana-by-seq*)
                 when (= (compact-kana-ord r) ord)
                   do (return (compact-kana-text r))))
          ((and (or (string= name "kanji-text") (string= name "kanji_text"))
                (memdict-table-loaded-p "kanji_text"))
           (loop for r in (gethash seq *kanji-by-seq*)
                 when (= (compact-kanji-ord r) ord)
                   do (return (compact-kanji-text r)))))))

(defun memdict-find-by-seq-text (table seq text)
  "Rows for SEQ with TEXT in TABLE (ascending id = DB select-dao order).
   Fresh copies (analyzer mutates readings). Mirrors get-original-text's
   (:and seq text) probes. NIL when TABLE isn't loaded (caller uses the DB)."
  (let ((name (string-downcase (symbol-name table))))
    (cond ((and (or (string= name "kana-text") (string= name "kana_text"))
                (memdict-table-loaded-p "kana_text"))
           (loop for r in (gethash seq *kana-by-seq*)
                 when (equal (compact-kana-text r) text)
                   collect (copy-compact-kana r)))
          ((and (or (string= name "kanji-text") (string= name "kanji_text"))
                (memdict-table-loaded-p "kanji_text"))
           (loop for r in (gethash seq *kanji-by-seq*)
                 when (equal (compact-kanji-text r) text)
                   collect (copy-compact-kanji r))))))

(defun memdict-rows-by-seq (table seq)
  "All rows for SEQ in TABLE ordered by ord (ascending id ties).
   Fresh copies (analyzer mutates readings). Mirrors get-kanji-kana-old's
   (select-dao ... 'ord). NIL when unloaded."
  (let ((name (string-downcase (symbol-name table))))
    (cond ((and (or (string= name "kana-text") (string= name "kana_text"))
                (memdict-table-loaded-p "kana_text"))
           (stable-sort (memdict-copy-rows (gethash seq *kana-by-seq*))
                        '< :key 'compact-kana-ord))
          ((and (or (string= name "kanji-text") (string= name "kanji_text"))
                (memdict-table-loaded-p "kanji_text"))
           (stable-sort (memdict-copy-rows (gethash seq *kanji-by-seq*))
                        '< :key 'compact-kanji-ord)))))

(defun memdict-select-conjs (seq &optional conj-ids)
  "Mirror ichiran/dict::select-conjs: conjugation rows for SEQ; with
   CONJ-IDS filter by id (unless :root); without, prefer via-NULL rows.
   Id-ascending (DB select-dao order). Caller gates on the conjugation table."
  (let ((rows (sort (copy-list (gethash seq *conj-by-seq*)) '< :key 'compact-conj-id)))
    (cond ((and conj-ids (not (eql conj-ids :root)))
           (loop for c in rows when (member (compact-conj-id c) conj-ids) collect c))
          (t (or (loop for c in rows when (eql (compact-conj-via c) :null) collect c)
                 rows)))))

(defun memdict-conj-props (conj-id)
  "Copy of the conj_prop rows for CONJ-ID, id-ascending (DB select-dao order).
   Caller gates on the conj_prop table."
  (sort (copy-list (gethash conj-id *conj-prop-by-id*)) '< :key 'compact-conj-prop-id))

(defun memdict-short-sense-str (seq &key with-pos)
  "Mirror ichiran/dict::short-sense-str: gloss string of the first sense by
   ord (optionally restricted to senses carrying pos WITH-POS), glosses joined
   with '; ' in ord order. NIL when sense/gloss (or sense_prop for WITH-POS)
   aren't loaded (caller uses the DB)."
  (when (and (memdict-table-loaded-p "sense") (memdict-table-loaded-p "gloss")
             (or (null with-pos) (memdict-table-loaded-p "sense_prop")))
    (let ((senses (memdict-senses-by-seq seq)))
      (when with-pos
        (setf senses
              (loop for s in senses
                    when (loop for p in (gethash (compact-sense-id s) *prop-by-sense*)
                               thereis (and (equal (compact-sense-prop-tag p) "pos")
                                            (equal (compact-sense-prop-text p) with-pos)))
                      collect s)))
      (let ((first (car senses)))
        (when first
          (let ((gs (memdict-glosses-by-sense (compact-sense-id first))))
            (when gs (join-strings "; " (mapcar 'cdr gs)))))))))

(defun memdict-has-conj-p (seq)
  "T whether SEQ has any conjugation rows."
  (not (null (gethash seq *conj-by-seq*))))

;;; ---- R6: counter helpers (pure scalars; no DAO shapes) ----
;;; get-counter-ids / get-counter-stags fire per-process (cached by `ensure`)
;;; but each costs IN-queries over sense_prop. The readings query stays on the
;;; DB (batched, once per process, DAO-shaped rows).

(defun memdict-counter-ids ()
  "Sorted distinct seqs having a pos=ctr sense_prop. Mirrors
   ichiran/dict::get-counter-ids. NIL when sense_prop isn't loaded."
  (when (memdict-table-loaded-p "sense_prop")
    (let ((seen (make-hash-table :test 'eql))
          (out nil))
      (maphash (lambda (sid props)
                 (declare (ignore sid))
                 (dolist (p props)
                   (when (and (equal (compact-sense-prop-tag p) "pos")
                              (equal (compact-sense-prop-text p) "ctr"))
                     (let ((s (compact-sense-prop-seq p)))
                       (unless (gethash s seen)
                         (setf (gethash s seen) t)
                         (push s out))))))
               *prop-by-sense*)
      (sort out '<))))

(defun memdict-counter-stags (seqs)
  "Cons of stagk-hash and stagr-hash (seq -> list of text), restricted to
   senses carrying pos=ctr on the same sense. Mirrors
   ichiran/dict::get-counter-stags (membership use only; order irrelevant).
   NIL when sense_prop isn't loaded."
  (when (memdict-table-loaded-p "sense_prop")
    (let ((wanted (let ((h (make-hash-table :test 'eql)))
                    (dolist (s seqs) (setf (gethash s h) t))
                    h))
          (stagks (make-hash-table))
          (stagrs (make-hash-table)))
      (maphash (lambda (sid props)
                 (declare (ignore sid))
                 (when (loop for p in props
                             thereis (and (equal (compact-sense-prop-tag p) "pos")
                                          (equal (compact-sense-prop-text p) "ctr")))
                   (dolist (p props)
                     (let ((tag (compact-sense-prop-tag p)))
                       (when (and (member tag '("stagk" "stagr") :test 'equal)
                                  (gethash (compact-sense-prop-seq p) wanted))
                         (push (compact-sense-prop-text p)
                               (gethash (compact-sense-prop-seq p)
                                        (if (equal tag "stagk") stagks stagrs))))))))
               *prop-by-sense*)
      (cons stagks stagrs))))

;;; ---- R6: trie-in-core ----
;;; The serving core can bake a compact character trie over the RAM text keys
;;; so per-sentence substring seeding only probes valid dict prefixes (see
;;; ichiran/dict::find-substring-words-ram-seed). No hard dependency: the
;;; ichiran/trie package is resolved at call time.

(defvar *trie* nil "Baked prefix trie over the loaded text keys (or NIL).")
(defun memdict-trie () *trie*)

(defun memdict-build-trie (&key (tables '("kana_text" "kanji_text")))
  "Build the compact trie over the RAM text keys of TABLES and store it in
   *TRIE*. Requires src/trie.lisp loaded (bare-safe: postmodern+trie only).
   Payloads are the texts themselves (interned, shared with the dict)."
  (let ((trie-pkg (find-package :ichiran/trie)))
    (unless trie-pkg
      (error "memdict-build-trie needs the ichiran/trie package (load src/trie.lisp first)"))
    (let ((pairs nil))
      (when (and (member "kana_text" tables :test 'equal)
                 (memdict-table-loaded-p "kana_text"))
        (maphash (lambda (text rows)
                   (declare (ignore rows))
                   (push (cons text text) pairs))
                 *kana-by-text*))
      (when (and (member "kanji_text" tables :test 'equal)
                 (memdict-table-loaded-p "kanji_text"))
        (maphash (lambda (text rows)
                   (declare (ignore rows))
                   (push (cons text text) pairs))
                 *kanji-by-text*))
      (format t "memdict-build-trie: ~a texts...~%" (length pairs))
      (setf *trie* (funcall (symbol-function (find-symbol "BUILD-TRIE" trie-pkg)) pairs))
      (format t "memdict-build-trie: nodes=~a edges=~a~%"
              (funcall (symbol-function (find-symbol "TRIE-NODE-COUNT" trie-pkg)) *trie*)
              (funcall (symbol-function (find-symbol "TRIE-EDGE-COUNT" trie-pkg)) *trie*))
      *trie*)))

(defun memdict-conj-data (seq &optional from/conj-ids)
  "Return list of (conj src-map props) for SEQ filtered by FROM/CONJ-IDS:
   - conj    : compact-conj
   - src-map : list of (text . source-text) from conj_source_reading
   - props   : list of compact-conj-prop
   Mirrors the raw pieces ichiran/dict::get-conj-data's DB path reads.
   Conj rows sorted by id (DB select-dao order); src-map in csr-id order."
  (let ((conjs (sort (copy-list
                      (cond ((null from/conj-ids)
                             (gethash seq *conj-by-seq*))
                            ((listp from/conj-ids)
                             (loop for c in (gethash seq *conj-by-seq*)
                                   when (member (compact-conj-id c) from/conj-ids)
                                     collect c))
                            (t (loop for c in (gethash seq *conj-by-seq*)
                                     when (= (compact-conj-from c) from/conj-ids)
                                       collect c))))
                     '< :key 'compact-conj-id)))
    (loop for conj in conjs
          collect (list conj
                        (loop for r in (sort (copy-list (gethash (compact-conj-id conj) *csr-by-id*))
                                             '< :key 'compact-csr-id)
                              collect (list (compact-csr-text r)
                                            (compact-csr-source-text r)))
                        (sort (copy-list (gethash (compact-conj-id conj) *conj-prop-by-id*))
                              '< :key 'compact-conj-prop-id)))))
