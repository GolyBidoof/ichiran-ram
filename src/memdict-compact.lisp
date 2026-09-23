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
           #:memdict-save-sense-snapshot #:memdict-load-sense-snapshot
           #:compact-sense-seq #:compact-sense-ord #:compact-sense-id
           #:compact-gloss-text #:compact-gloss-ord #:compact-sense-prop-tag
           #:compact-sense-prop-text #:compact-sense-prop-ord
           #:memdict-senses-raw #:memdict-non-arch-posi #:memdict-uk
           #:memdict-entry-by-seq #:memdict-conj-data #:memdict-has-conj-p
           #:memdict-conj-from-via #:memdict-max-seq
           #:memdict-set-restricted-readings #:memdict-restricted-readings
           #:memdict-restricted-readings-loaded-p
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
           #:compact-sense-prop-id #:compact-sense-prop-sense-id #:compact-sense-prop-seq
           ;; R7 integer backend registry
           #:int-register-text-table #:int-table-loaded-p #:*int-tables*
           #:memdict-query-parents
           #:memdict-load-int #:*int-backed-tables*
           ;; R8/Tier 0: remaining serving-path query mirrors
           #:memdict-find-with-pos #:memdict-text-rows-by-text
           #:memdict-find-by-words-seqs
           #:memdict-conj-ids-by-seq-from #:memdict-seq-has-pos-p
           #:memdict-text-row-by-id #:memdict-csr-texts
           #:memdict-kana-forms #:memdict-conj-seqs-from
           #:memdict-any-sense-ord-0-p #:memdict-conj-count-by-seq-from
           #:memdict-words-by-conj-from
           #:memdict-complete-p #:memdict-mark-complete #:*complete-tables*))

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
   rows - pre-existing behavior, out of scope - but order stays ascending
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

(defvar *complete-tables* nil
  "Tables whose row count was verified against the DB. A RAM miss on a
   complete table is definitive, so find-word can skip the confirming DB probe
   (see memdict-complete-p). Partial/failed loads are never listed here.")

(defun memdict-complete-p (&rest tables)
  "T when every table in TABLES was loaded AND verified complete."
  (loop for table in tables always (member table *complete-tables* :test 'equal)))

(defun memdict-mark-complete (tables)
  (dolist (table tables)
    (pushnew table *complete-tables* :test 'equal))
  *complete-tables*)

(defun memdict-verify-counts (tables get-db-count)
  "Compare in-RAM row totals against the DB for TABLES (fresh loads only - 
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
   (the full in-RAM dictionary; ~12-16GB with indexes - for a 64GB host).
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
               ;; OFFSET pages overlap - rows load twice and others never
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
      (when (memdict-verify-counts tables
                                   (lambda (table)
                                     (query (format nil "SELECT count(*) FROM ~a" table)
                                            :single)))
        ;; all counts matched: RAM misses on these tables are definitive
        (memdict-mark-complete tables)))
    (let ((after (sb-kernel:dynamic-usage)))
      (format t "memdict-compact load: ~,1f MB delta~%"
              (/ (- after before) 1048576.0)))
    (setf *loaded-tables* (union *loaded-tables* tables :test 'equal))
    (memdict-stats)))

(defvar *int-tables* (make-hash-table :test 'equal)
  "table name (kana_text/kanji_text, underscores) -> int-text-table.
   Defined early: memdict-reset clears it (declared before use).")

(defun memdict-reset ()
  "Clear ALL loaded dict data (for benchmarking partial loads)."
  (clrhash *kana-by-text*) (clrhash *kana-by-seq*)
  (clrhash *kanji-by-text*) (clrhash *kanji-by-seq*)
  (clrhash *entry-by-seq*) (clrhash *conj-by-seq*) (clrhash *conj-by-from*)
  (clrhash *conj-prop-by-id*) (clrhash *csr-by-id*)
  (clrhash *sense-by-seq*) (clrhash *gloss-by-sense*) (clrhash *prop-by-sense*)
  (clrhash *string-pool*) (clrhash *int-tables*)
  (setf *sense-ids-ord-0* nil)
  (setf *complete-tables* nil)
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

;;; ---- R7: integer-table backend (src/memdict-int.lisp) ----
;;; (*int-tables* is defvarred above memdict-reset, which clears it.)
;;; When an integer table is registered for kana_text/kanji_text, struct-path
;;; lookups decode from it (fresh structs every call: copy-on-return is free).
;;; Text-only probes go straight to the integer index (no decode).

(defun memdict-tables-loaded-p (&rest tables)
  "T when every table in TABLES is loaded. Local multi-table form of
   memdict-table-loaded-p (the ichiran/dict wrapper of the same name is a
   different function)."
  (loop for table in tables always (memdict-table-loaded-p table)))

(defun int-table-loaded-p (table)
  "T when an integer table is registered for TABLE (underscored name)."
  (nth-value 1 (gethash table *int-tables*)))

(defun int-register-text-table (table int-table &key (verify t))
  "Register INT-TEXT-TABLE (from ichiran/memdict-int:int-load-text) for TABLE.
   Also records TABLE in *loaded-tables* so table gating (memdict-call,
   memdict-table-loaded-p) treats the integer backend as loaded."
  (setf (gethash table *int-tables*) int-table)
  (pushnew table *loaded-tables* :test 'equal)
  ;; Verify the row count here rather than in memdict-load-int: harnesses and
  ;; the build script also register tables one by one, and a RAM miss is only
  ;; trustworthy (memdict-complete-p) if the count matched the DB. Skipped
  ;; silently in bare cores with no connection.
  ;;
  ;; :VERIFY NIL is for snapshot loads: the snapshot was written from tables
  ;; that had already been verified, and the whole point is to start without
  ;; a database.
  (when (null verify)
    (memdict-mark-complete (list table))
    (return-from int-register-text-table table))
  (handler-case
      (with-db-connection (nil)
        (let ((ram (int-object-row-count table int-table))
              (db (query (format nil "SELECT count(*) FROM ~a" table) :single)))
          (cond ((null ram) (format t "INT-VERIFY-SKIP: ~a~%" table))
                ((= ram db)
                 (memdict-mark-complete (list table))
                 (format t "INT-VERIFY-OK: ~a ram=~a db=~a~%" table ram db))
                (t (format t "INT-VERIFY-FAIL: ~a ram=~a db=~a~%" table ram db)))))
    (error (e)
      (declare (ignore e))
      (format t "INT-VERIFY-SKIP: ~a (no connection)~%" table)))
  table)

(defun int-fn (name)
  "Resolve NAME in ichiran/memdict-int, or NIL if not loaded."
  (let ((pkg (find-package :ichiran/memdict-int)))
    (when pkg
      (let ((sym (find-symbol (string name) pkg)))
        (when (and sym (fboundp sym)) (symbol-function sym))))))

(defun decode-int-row (kana-p plist)
  "Build a compact-kana/kanji struct from an int-text-row plist."
  (if kana-p
      (make-compact-kana :id (getf plist :id) :seq (getf plist :seq)
                         :text (getf plist :text) :ord (getf plist :ord)
                         :common (getf plist :common)
                         :common-tags (getf plist :common-tags)
                         :conjugate-p (getf plist :conjugate-p)
                         :nokanji (getf plist :nokanji)
                         :best-kanji (or (getf plist :best-kanji) :null))
      (make-compact-kanji :id (getf plist :id) :seq (getf plist :seq)
                          :text (getf plist :text) :ord (getf plist :ord)
                          :common (getf plist :common)
                          :common-tags (getf plist :common-tags)
                          :conjugate-p (getf plist :conjugate-p)
                          :nokanji (getf plist :nokanji)
                          :best-kana (or (getf plist :best-kana) :null))))

(defun decode-int-row-at (kana-p table row)
  "Build a compact-kana/kanji struct directly from TABLE's columns at ROW,
   with no plist intermediate (int-text-row's plist was a per-lookup cost on
   a very hot path). Fresh struct every call, since the analyzer mutates
   readings."
  (multiple-value-bind (id seq text ord common common-tags conj-p nokanji
                        best-kanji best-kana)
      (funcall (int-fn 'int-text-row-fields) table row)
    (if kana-p
        (make-compact-kana :id id :seq seq :text text :ord ord
                           :common common :common-tags common-tags
                           :conjugate-p conj-p :nokanji nokanji
                           :best-kanji (or best-kanji :null))
        (make-compact-kanji :id id :seq seq :text text :ord ord
                            :common common :common-tags common-tags
                            :conjugate-p conj-p :nokanji nokanji
                            :best-kana (or best-kana :null)))))

(defun int-conj-tables-present-p ()
  "T when all three conjugation int tables are registered."
  (and (gethash "conjugation" *int-tables*)
       (gethash "conj_prop" *int-tables*)
       (gethash "conj_source_reading" *int-tables*)))

(defun int->compact-conj (id seq from via-or-nil)
  "Build a compact-conj from int fields (nil via becomes :null, mirroring
   the DB-loader shape that select-conjs tests with eql :null)."
  (make-compact-conj :id id :seq seq :from from
                     :via (or via-or-nil :null)))

(defun int->compact-conj-prop (id conj-id type pos neg fml)
  (make-compact-conj-prop :id id :conj-id conj-id :conj-type type
                          :pos pos :neg neg :fml fml))

(defun memdict-find (table text)
  "Rows for TEXT (fresh copies; the analyzer mutates readings). NIL if none."
  (let ((name (string-downcase (symbol-name table))))
    (cond ((or (string= name "kana-text") (string= name "kana_text"))
           (or (let ((it (gethash "kana_text" *int-tables*)))
                 (when it
                   (mapcar (lambda (r) (decode-int-row-at t it r))
                           (funcall (int-fn 'int-text-find-rows-indexes) it text))))
               (memdict-copy-rows (gethash text *kana-by-text*))))
          ((or (string= name "kanji-text") (string= name "kanji_text"))
           (or (let ((it (gethash "kanji_text" *int-tables*)))
                 (when it
                   (mapcar (lambda (r) (decode-int-row-at nil it r))
                           (funcall (int-fn 'int-text-find-rows-indexes) it text))))
               (memdict-copy-rows (gethash text *kanji-by-text*))))
          (t nil))))

(defun memdict-find-by-seq (table seq)
  "Rows for SEQ (fresh copies; the analyzer mutates readings). NIL if none."
  (let ((name (string-downcase (symbol-name table))))
    (cond ((or (string= name "kana-text") (string= name "kana_text"))
           (or (let ((it (gethash "kana_text" *int-tables*)))
                 (when it
                   (mapcar (lambda (r) (decode-int-row-at t it r))
                           (funcall (int-fn 'int-text-find-by-seq-indexes) it seq))))
               (memdict-copy-rows (gethash seq *kana-by-seq*))))
          ((or (string= name "kanji-text") (string= name "kanji_text"))
           (or (let ((it (gethash "kanji_text" *int-tables*)))
                 (when it
                   (mapcar (lambda (r) (decode-int-row-at nil it r))
                           (funcall (int-fn 'int-text-find-by-seq-indexes) it seq))))
               (memdict-copy-rows (gethash seq *kanji-by-seq*))))
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
  "Return the compact-entry for SEQ, or NIL. Integer backend first when
   the entry int table is registered (fresh struct per call)."
  (or (let ((it (gethash "entry" *int-tables*)))
        (when it
          (let ((pl (funcall (int-fn 'int-entry-by-seq) it seq)))
            (when pl
              (make-compact-entry :seq (getf pl :seq)
                                  :content (getf pl :content)
                                  :root-p (getf pl :root-p)
                                  :n-kanji (getf pl :n-kanji)
                                  :n-kana (getf pl :n-kana)
                                  :primary-nokanji (getf pl :primary-nokanji))))))
      (gethash seq *entry-by-seq*)))

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
  (let ((senses (memdict-senses-by-seq seq)))
   (loop for sense in senses
        for idx from 0
        for last-sense-p = (= idx (1- (length senses)))
        for sense-id = (compact-sense-id sense)
        for gloss = (let ((gs (memdict-glosses-by-sense sense-id)))
                      (if gs
                          (join-strings "; " (mapcar 'cdr gs))
                          ""))
        for props = (memdict-props-in-db-order sense-id last-sense-p)
        collect (list :ord (compact-sense-ord sense) :gloss gloss :props props))))

(defun memdict-props-in-db-order (sense-id last-sense-p)
  "Tag/text pairs in exactly the order ichiran/dict::get-senses-raw produces.
   The DB path reads props ORDER BY sense.ord, tag, prop.ord and accumulates
   each (sense, tag) group with PUSH, reversing a group only when the NEXT
   group begins. Its final group therefore stays in reverse accumulating
   order, and reproducing that quirk is required for byte-identical output:
   entry 1648700 comes out as [vt,vs,n] from the database and would come out
   [n,vs,vt] from a path that reversed every group. Only the last tag group of
   the last sense is affected because it is the only one with no successor."
  (let* ((tags '("pos" "s_inf" "stagk" "stagr" "field"))
         (ps (remove-if-not (lambda (p)
                              (member (compact-sense-prop-tag p) tags :test 'equal))
                            (copy-list (gethash sense-id *prop-by-sense*))))
         ;; ORDER BY tag, prop.ord -- within a sense that is tag order first.
         (sorted (sort ps (lambda (a b)
                            (let ((ta (compact-sense-prop-tag a))
                                  (tb (compact-sense-prop-tag b)))
                              (if (equal ta tb)
                                  (< (compact-sense-prop-ord a)
                                     (compact-sense-prop-ord b))
                                  (string< ta tb))))))
         (groups nil))
    ;; consecutive same-tag runs, accumulated with PUSH like the DB path
    (dolist (p sorted)
      (let ((tag (compact-sense-prop-tag p)))
        (if (and groups (equal (caar groups) tag))
            (push (compact-sense-prop-text p) (cdar groups))
            (push (list tag (compact-sense-prop-text p)) groups))))
    (setf groups (nreverse groups))
    (loop for g in groups
          for last-group-p = (eq g (car (last groups)))
          collect (cons (car g)
                        (if (and last-group-p last-sense-p)
                            (cdr g)                 ; unreversed, as in the DB
                            (nreverse (cdr g)))))))

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
  "T when TABLE (string) was loaded into RAM, via struct hashes or integer
   tables (either backend satisfies table gating)."
  (or (member table *loaded-tables* :test 'equal)
      (int-table-loaded-p table)))

(defun memdict-text-by-seq (table seq &optional (ord 0))
  "First TEXT for SEQ with ORD in TABLE. TABLE is kana-text/kanji-text (symbol
   or string). Mirrors reading-str-seq and entry get-kana/get-text/get-kanji
   (seq + ord 0 probes). NIL when TABLE isn't loaded (caller uses the DB)."
  (let ((name (string-downcase (symbol-name table))))
    (cond ((and (or (string= name "kana-text") (string= name "kana_text"))
                (memdict-table-loaded-p "kana_text"))
           (or (let ((it (gethash "kana_text" *int-tables*)))
                 (when it (funcall (int-fn 'int-text-by-seq) it seq ord)))
               (loop for r in (gethash seq *kana-by-seq*)
                     when (= (compact-kana-ord r) ord)
                       do (return (compact-kana-text r)))))
          ((and (or (string= name "kanji-text") (string= name "kanji_text"))
                (memdict-table-loaded-p "kanji_text"))
           (or (let ((it (gethash "kanji_text" *int-tables*)))
                 (when it (funcall (int-fn 'int-text-by-seq) it seq ord)))
               (loop for r in (gethash seq *kanji-by-seq*)
                     when (= (compact-kanji-ord r) ord)
                       do (return (compact-kanji-text r))))))))

(defun memdict-find-by-words-seqs (table texts seqs)
  "One side of find-words-seqs' database call: a single select-dao over
   (text IN TEXTS AND seq IN SEQS). Those rows arrive in physical (ctid) order
   because the query carries no ORDER BY, and the caller depends on it:
   expand-segment-list stable-sorts candidates by score, so physical order is
   what decides which of two equally scored alternatives is printed first.
   Looping memdict-find-by-seq-text per (text, seq) pair returns word-major
   groups instead, which is what reordered tied alternatives on 72 golden
   lines. Rows come back sorted by physical rank, mirroring the database."
  (let* ((name (string-downcase (symbol-name table)))
         (kana-p (and (search "kana" name) t))
         (it (gethash (if kana-p "kana_text" "kanji_text") *int-tables*)))
    (when it
      (let ((ranks (funcall (int-fn 'int-text-table-ranks) it))
            (pairs nil))
        (dolist (s seqs)
          (loop for r in (funcall (int-fn 'int-text-find-by-seq-indexes) it s)
                for row = (decode-int-row-at (if kana-p t nil) it r)
                for txt = (if kana-p (compact-kana-text row)
                              (compact-kanji-text row))
                when (member txt texts :test 'equal)
                  do (push (cons (aref ranks r) row) pairs)))
        (loop for (nil . row) in (sort pairs '< :key 'car) collect row)))))

(defun memdict-find-by-seq-text (table seq text)
  "Rows for SEQ with TEXT in TABLE (ascending id = DB select-dao order).
   Fresh copies (analyzer mutates readings). Mirrors get-original-text's
   (:and seq text) probes. NIL when TABLE isn't loaded (caller uses the DB)."
  (let ((name (string-downcase (symbol-name table))))
    (cond ((and (or (string= name "kana-text") (string= name "kana_text"))
                (memdict-table-loaded-p "kana_text"))
           (or (let ((it (gethash "kana_text" *int-tables*)))
                 (when it
                   (loop for r in (funcall (int-fn 'int-text-find-by-seq-indexes) it seq)
                         for row = (decode-int-row-at t it r)
                         when (equal (compact-kana-text row) text)
                           collect row)))
               (loop for r in (gethash seq *kana-by-seq*)
                     when (equal (compact-kana-text r) text)
                       collect (copy-compact-kana r))))
          ((and (or (string= name "kanji-text") (string= name "kanji_text"))
                (memdict-table-loaded-p "kanji_text"))
           (or (let ((it (gethash "kanji_text" *int-tables*)))
                 (when it
                   (loop for r in (funcall (int-fn 'int-text-find-by-seq-indexes) it seq)
                         for row = (decode-int-row-at nil it r)
                         when (equal (compact-kanji-text row) text)
                           collect row)))
               (loop for r in (gethash seq *kanji-by-seq*)
                     when (equal (compact-kanji-text r) text)
                        collect (copy-compact-kanji r)))))))

(defun memdict-rows-by-seq (table seq)
  "All rows for SEQ in TABLE ordered by ord (ascending id ties).
   Fresh copies (analyzer mutates readings). Mirrors get-kanji-kana-old's
   (select-dao ... 'ord). NIL when unloaded."
  (let ((name (string-downcase (symbol-name table))))
    (cond ((and (or (string= name "kana-text") (string= name "kana_text"))
                (memdict-table-loaded-p "kana_text"))
           (or (let ((it (gethash "kana_text" *int-tables*)))
                 (when it
                   (mapcar (lambda (r) (decode-int-row-at t it r))
                           (funcall (int-fn 'int-text-rows-by-seq-indexes) it seq))))
               (stable-sort (memdict-copy-rows (gethash seq *kana-by-seq*))
                            '< :key 'compact-kana-ord)))
          ((and (or (string= name "kanji-text") (string= name "kanji_text"))
                (memdict-table-loaded-p "kanji_text"))
           (or (let ((it (gethash "kanji_text" *int-tables*)))
                 (when it
                   (mapcar (lambda (r) (decode-int-row-at nil it r))
                           (funcall (int-fn 'int-text-rows-by-seq-indexes) it seq))))
               (stable-sort (memdict-copy-rows (gethash seq *kanji-by-seq*))
                            '< :key 'compact-kanji-ord))))))

(defun memdict-select-conjs (seq &optional conj-ids)
  "Mirror ichiran/dict::select-conjs: conjugation rows for SEQ; with
   CONJ-IDS filter by id (unless :root); without, prefer via-NULL rows.
   Id-ascending (DB select-dao order). Caller gates on the conjugation table."
  (let ((rows (if (gethash "conjugation" *int-tables*)
                  (loop for (id sq from via) in (funcall (int-fn 'int-conj-rows-by-seq)
                                                         (gethash "conjugation" *int-tables*) seq)
                        collect (int->compact-conj id sq from via))
                  (sort (copy-list (gethash seq *conj-by-seq*)) '< :key 'compact-conj-id))))
    (cond ((and conj-ids (not (eql conj-ids :root)))
           (loop for c in rows when (member (compact-conj-id c) conj-ids) collect c))
          (t (or (loop for c in rows when (eql (compact-conj-via c) :null) collect c)
                 rows)))))

(defun memdict-conj-props (conj-id)
  "Copy of the conj_prop rows for CONJ-ID, id-ascending (DB select-dao order).
   Caller gates on the conj_prop table."
  (or (let ((it (gethash "conj_prop" *int-tables*)))
        (when it
          (loop for (id cid type pos neg fml) in (funcall (int-fn 'int-conj-props-by-id) it conj-id)
                collect (int->compact-conj-prop id cid type pos neg fml))))
      (sort (copy-list (gethash conj-id *conj-prop-by-id*)) '< :key 'compact-conj-prop-id)))

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

(defvar *restricted-readings* (make-hash-table :test 'eql)
  "seq -> list of (reading . restricted-text), mirroring the restricted_readings
   table. That table is not one of the resident dictionary tables: it comes
   from JMdict's re_restr tags, so it is installed separately at load time.")

(defun memdict-set-restricted-readings (rows)
  "Install ROWS, a list of (seq reading text), replacing any previous set.
   Returns the number of seqs covered. The table is 6,332 rows."
  (clrhash *restricted-readings*)
  (dolist (r rows)
    (destructuring-bind (seq reading text) r
      ;; A proper two element list, not a dotted pair: MATCH-KANA-KANJI reads
      ;; these with (loop for (rt kt) in restricted ...), which destructures as
      ;; a list, so a dotted pair fails when it reaches the second element.
      (push (list reading text) (gethash seq *restricted-readings*))))
  (hash-table-count *restricted-readings*))

(defun memdict-restricted-readings (seq)
  "List of (reading . text) for SEQ, or NIL. Same pairs, in the same shape per
   row, as SELECT reading, text FROM restricted_readings WHERE seq = SEQ."
  (gethash seq *restricted-readings*))

(defun memdict-restricted-readings-loaded-p ()
  (plusp (hash-table-count *restricted-readings*)))

(defun memdict-max-seq ()
  "Largest seq in the loaded dictionary, or 0. Used to size the flat,
   seq-indexed gloss JSON caches, which want an exact bound rather than a
   growable structure."
  (let ((max-seq 0))
    (let ((it (gethash "entry" *int-tables*)))
      (when it
        (let ((sq (getf it :seqs)))
          (when sq
            (dotimes (i (length sq))
              (let ((v (aref sq i))) (when (> v max-seq) (setf max-seq v))))))))
    (when (zerop max-seq)
      (maphash (lambda (k v) (declare (ignore v))
                 (when (and (integerp k) (> k max-seq)) (setf max-seq k)))
               *entry-by-seq*))
    max-seq))

(defun memdict-conj-from-via (conj-id)
  "VALUES (FROM VIA) for CONJ-ID from the in-RAM conjugation table, or NIL.
   VIA is NIL where the database stores NULL. Mirrors what the analyzer reads
   out of (get-dao 'conjugation id), which it used to fetch per conj-id."
  (let ((it (gethash "conjugation" *int-tables*)))
    (when it
      (funcall (int-fn 'int-conj-by-id) it conj-id))))

(defun memdict-has-conj-p (seq)
  "T whether SEQ has any conjugation rows."
  (or (let ((it (gethash "conjugation" *int-tables*)))
        (when it (funcall (int-fn 'int-has-conj-p) it seq)))
      (not (null (gethash seq *conj-by-seq*)))))

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

(defun memdict-text-keys (table)
  "The distinct text keys of TABLE, from whichever backend is loaded.

   The compact loader keeps *KANA-BY-TEXT*/*KANJI-BY-TEXT*; the integer backend
   keeps an encoded pool with a parallel offsets array, which is why a trie
   built by MAPHASH over the hashes came out empty in a full-ram core."
  (let ((hash (cond ((equal table "kana_text")
                     (and (boundp '*kana-by-text*) *kana-by-text*))
                    ((equal table "kanji_text")
                     (and (boundp '*kanji-by-text*) *kanji-by-text*)))))
    (if hash
        (loop for k being the hash-keys of hash collect k)
        (let ((tbl (gethash table *int-tables*)))
          (when tbl
            (let ((nfn (int-fn 'int-text-table-n))
                  (sfn (int-fn 'int-text-pool-string)))
              (loop for i below (funcall nfn tbl)
                    collect (funcall sfn tbl i))))))))

(defun memdict-build-trie (&key (tables '("kana_text" "kanji_text")))
  "Build the compact trie over the RAM text keys of TABLES and store it in
   *TRIE*. Requires src/trie.lisp loaded (bare-safe: postmodern+trie only).
   Payloads are the texts themselves (interned, shared with the dict)."
  (let ((trie-pkg (find-package :ichiran/trie)))
    (unless trie-pkg
      (error "memdict-build-trie needs the ichiran/trie package (load src/trie.lisp first)"))
    (let ((pairs nil))
      ;; Each side is collected from whichever backend is loaded. The compact
      ;; loader fills *KANA-BY-TEXT*/*KANJI-BY-TEXT*; the integer columnar
      ;; backend fills neither, keeping an encoded text pool instead. MAPHASH
      ;; over those hashes therefore produced an EMPTY trie under full-ram, and
      ;; the only symptom was the build reporting success in 0.1s and serving
      ;; returning no candidates at all. MEMDICT-TEXT-KEYS handles both.
      (when (and (member "kana_text" tables :test 'equal)
                 (memdict-table-loaded-p "kana_text"))
        (dolist (text (memdict-text-keys "kana_text"))
          (push (cons text text) pairs)))
      (when (and (member "kanji_text" tables :test 'equal)
                 (memdict-table-loaded-p "kanji_text"))
        (dolist (text (memdict-text-keys "kanji_text"))
          (push (cons text text) pairs)))
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
  (if (int-conj-tables-present-p)
      (let ((conj-tab (gethash "conjugation" *int-tables*))
            (prop-tab (gethash "conj_prop" *int-tables*))
            (csr-tab (gethash "conj_source_reading" *int-tables*)))
        (loop for (id sq from via)
              in (funcall (int-fn 'int-conj-rows-by-seq) conj-tab seq)
              for cid = id
              when (cond ((null from/conj-ids) t)
                         ((listp from/conj-ids) (member cid from/conj-ids))
                         (t (= from from/conj-ids)))
                collect (list (int->compact-conj id sq from via)
                              (funcall (int-fn 'int-csr-by-id) csr-tab cid)
                              (loop for (pid pcid type pos neg fml)
                                    in (funcall (int-fn 'int-conj-props-by-id) prop-tab cid)
                                    collect (int->compact-conj-prop pid pcid type pos neg fml)))))
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
                              '< :key 'compact-conj-prop-id))))))

;;; ---- R7: conjugation parent lookup (mirror of query-parents-kanji/kana) ----
;;; best-kana-conj / best-kanji-conj resolve a conjugated form's reading by
;;; walking to the *parent* dictionary entry. The DB queries join
;;; kanji_text/kana_text with conj_source_reading and conjugation; these
;;; mirrors reproduce the same (parent-text-id conj-id) pairs from RAM so the
;;; analyzer's conjugation-aware reading path works off the integer tables.

(defun memdict-query-parents (text-table seq text)
  "RAM mirror of ichiran/dict::query-parents-kanji / query-parents-kana:
   list of (parent-text-id conj-id) such that a conjugation of SEQ maps TEXT
   (the conjugated form) through conj_source_reading to a source reading that
   exists in TEXT-TABLE. TEXT-TABLE is \"kanji_text\" or \"kana_text\".
   NIL when the conjugation trio or that text table isn't loaded.
   Order: conj rows by id, csr rows by id, text rows by id (deterministic)."
  (let ((conj-tab (gethash "conjugation" *int-tables*))
        (csr-tab (gethash "conj_source_reading" *int-tables*))
        (txt-tab (gethash text-table *int-tables*)))
    (when (and conj-tab csr-tab txt-tab (gethash "conj_prop" *int-tables*))
      (let ((found nil))
        (dolist (cr (funcall (int-fn 'int-conj-rows-by-seq) conj-tab seq))
          (destructuring-bind (cid cseq from via) cr
            (declare (ignore cseq))
            ;; DB joins kt.seq to conj.via when non-NULL, else conj.from.
            (let ((target (or via from)))
              (dolist (sr (funcall (int-fn 'int-csr-by-id) csr-tab cid))
                (destructuring-bind (ctext csrc) sr
                  (when (equal ctext text)
                    (dolist (r (funcall (int-fn 'int-text-find-by-seq-indexes) txt-tab target))
                      (let ((row (decode-int-row-at t txt-tab r)))
                        (when (equal (compact-kana-text row) csrc)
                          (push (list (compact-kana-id row) cid) found))))))))))
        (nreverse found)))))

;;; ---- R7: integer-backend bulk loader ----
;;; Loads the memory-tight tables through src/memdict-int.lisp and registers
;;; them, so the serving core can combine the integer layer (text/entry/conj)
;;; with compact hash tables for whatever is not integer-backed yet
;;; (the sense/gloss/sense_prop layer). Needs ichiran/memdict-int loaded.

(defparameter *int-backed-tables*
  '("kana_text" "kanji_text" "entry" "conjugation" "conj_prop"
    "conj_source_reading")
  "Tables the integer backend can serve, in load order.")

(defun int-object-row-count (table obj)
  "Row count of integer table object OBJ (which need not be registered yet)."
  (cond ((member table '("kana_text" "kanji_text") :test 'equal)
         (funcall (int-fn 'int-text-row-count) obj))
        ((equal table "entry") (funcall (int-fn 'int-entry-row-count) obj))
        ((equal table "conjugation") (funcall (int-fn 'int-conj-row-count) obj))
        ((equal table "conj_prop") (funcall (int-fn 'int-conj-prop-row-count) obj))
        ((equal table "conj_source_reading") (funcall (int-fn 'int-csr-row-count) obj))
        (t nil)))

(defun int-table-row-count (table)
  "Row count of an integer table object, by name."
  (cond ((member table '("kana_text" "kanji_text") :test 'equal)
         (funcall (int-fn 'int-text-row-count)
                  (gethash table *int-tables*)))
        ((equal table "entry") (funcall (int-fn 'int-entry-row-count)
                                        (gethash table *int-tables*)))
        ((equal table "conjugation") (funcall (int-fn 'int-conj-row-count)
                                              (gethash table *int-tables*)))
        ((equal table "conj_prop") (funcall (int-fn 'int-conj-prop-row-count)
                                            (gethash table *int-tables*)))
        ((equal table "conj_source_reading") (funcall (int-fn 'int-csr-row-count)
                                                      (gethash table *int-tables*)))
        (t nil)))

(defun int-snapshot-fn (name)
  "Resolve NAME in ichiran/int-snapshot, or NIL when that file is not loaded."
  (let ((pkg (find-package :ichiran/int-snapshot)))
    (when pkg
      (let ((sym (find-symbol (string name) pkg)))
        (when (and sym (fboundp sym)) (symbol-function sym))))))

(defun memdict-load-int (&key (tables *int-backed-tables*) (chunk 200000) conn
                              (verbose t) snapshot (save-snapshot nil))
  "Load TABLES via the integer backend and register them for lookups.
   Returns (values total-bytes size-alist). Signals if a table has no
   integer loader (so a typo can't silently load nothing)."
  (let ((total 0) (sizes nil) (load-text (int-fn 'int-load-text))
        ;; Resolve once: the integer loaders fall back to ichiran/conn, which a
        ;; bare serving core does not have.
        (conn (or conn (default-conn))))
    ;; Snapshot fast path: reading the columns as raw bytes avoids the SQL
    ;; round trips entirely (measured 70.3s -> 9.9s for the full dictionary).
    ;; Verification is skipped: the snapshot is written only from tables that
    ;; already passed the row-count check.
    (let ((file-p (int-snapshot-fn 'int-snapshot-file-p))
          (load-fn (int-snapshot-fn 'int-snapshot-load)))
      (when (and snapshot file-p load-fn (funcall file-p snapshot))
        (let ((start (get-internal-real-time)))
          (dolist (entry (funcall load-fn snapshot))
            (int-register-text-table (car entry) (cdr entry) :verify nil))
          (when verbose
            (format t "memdict-load-int: snapshot ~a in ~,2fs~%"
                    snapshot
                    (/ (- (get-internal-real-time) start)
                       internal-time-units-per-second)))
          (return-from memdict-load-int (values 0 nil)))))
    (dolist (table tables)
      (let ((start (get-internal-real-time)))
        (multiple-value-bind (obj bytes)
            (cond ((member table '("kana_text" "kanji_text") :test 'equal)
                   (funcall load-text table :chunk chunk :conn conn))
                  ((equal table "entry")
                   (funcall (int-fn 'int-load-entry) :chunk chunk :conn conn))
                  ((equal table "conjugation")
                   (funcall (int-fn 'int-load-conjugation) :chunk chunk :conn conn))
                  ((equal table "conj_prop")
                   (funcall (int-fn 'int-load-conj-prop) :chunk chunk :conn conn))
                  ((equal table "conj_source_reading")
                   (funcall (int-fn 'int-load-csr) :chunk chunk :conn conn))
                  (t (error "memdict-load-int: no integer loader for ~a" table)))
          (int-register-text-table table obj)
          (incf total bytes)
          (push (cons table bytes) sizes)
          (when verbose
            (format t "int-loaded ~a: ~,1f MB in ~,1fs~%" table
                    (/ bytes 1048576.0)
                    (/ (- (get-internal-real-time) start)
                       internal-time-units-per-second))))))
    ;; Row-count verification happens in int-register-text-table.
    (when (and save-snapshot (int-snapshot-fn 'int-snapshot-save))
      (let ((start (get-internal-real-time)))
        (funcall (int-snapshot-fn 'int-snapshot-save) save-snapshot
                 (loop for table in tables
                       collect (cons table (gethash table *int-tables*))))
        (when verbose
          (format t "memdict-load-int: wrote snapshot ~a in ~,2fs~%"
                  save-snapshot
                  (/ (- (get-internal-real-time) start)
                     internal-time-units-per-second)))))
    (values total (nreverse sizes))))

;;; ---- R8/Tier 0: remaining serving-path query mirrors ----
;;; Each mirrors one prepared query the analyzer still issues per candidate
;;; word. All self-gate on *loaded-tables*, so partial loads keep the DB path.

(defun md-row-seq (row)
  "SEQ of a compact-kana/compact-kanji row."
  (if (compact-kana-p row) (compact-kana-seq row) (compact-kanji-seq row)))

(defun md-row-id (row)
  "ID of a compact-kana/compact-kanji row."
  (if (compact-kana-p row) (compact-kana-id row) (compact-kanji-id row)))

(defun memdict-seq-has-pos-p (seq posi)
  "T when SEQ has a sense_prop with tag \"pos\" and text in POSI."
  (loop for sense in (gethash seq *sense-by-seq*)
        thereis (loop for p in (gethash (compact-sense-id sense) *prop-by-sense*)
                      thereis (and (equal (compact-sense-prop-tag p) "pos")
                                   (member (compact-sense-prop-text p) posi
                                           :test 'equal)))))

(defun memdict-find-with-pos (table-name word posi)
  "RAM mirror of ichiran/dict::find-word-with-pos: rows of TABLE-NAME whose
   TEXT is WORD and whose seq carries a pos sense_prop with text in POSI.
   Distinct by id, since the DB selects DISTINCT across the sense_prop join.
   NIL unless the text table and sense_prop are loaded."
  (when (and (memdict-table-loaded-p "sense_prop")
             (memdict-table-loaded-p table-name))
    (let ((rows (if (search "kanji" table-name)
                    (memdict-find 'kanji-text word)
                    (memdict-find 'kana-text word)))
          (seen (make-hash-table :test 'eql))
          (out nil))
      (dolist (row rows)
        (let ((id (md-row-id row)))
          (when (and (not (gethash id seen))
                     (memdict-seq-has-pos-p (md-row-seq row) posi))
            (setf (gethash id seen) t)
            (push row out))))
      (nreverse out))))

(defun memdict-text-rows-by-text (table-name word)
  "Rows of TABLE-NAME whose TEXT is WORD (DB select-dao by text order: id).
   NIL unless TABLE-NAME is loaded."
  (when (memdict-table-loaded-p table-name)
    (let ((rows (if (search "kanji" table-name)
                    (memdict-find 'kanji-text word)
                    (memdict-find 'kana-text word))))
      (sort rows '< :key #'md-row-id))))

(defun memdict-conj-ids-by-seq-from (seq from)
  "RAM mirror of the (SELECT id FROM conjugation WHERE seq IN (...) AND
   \"from\" = ...) probe: ids of conjugation rows for SEQ whose from is FROM."
  (when (memdict-table-loaded-p "conjugation")
    (loop for (id nil row-from nil)
          in (or (let ((it (gethash "conjugation" *int-tables*)))
                   (when it (funcall (int-fn 'int-conj-rows-by-seq) it seq)))
                 (loop for c in (gethash seq *conj-by-seq*)
                       collect (list (compact-conj-id c) (compact-conj-seq c)
                                     (compact-conj-from c) (compact-conj-via c))))
          when (eql row-from from) collect id)))

(defun memdict-text-row-by-id (table-name id)
  "RAM text row for primary key ID in TABLE-NAME, or NIL. Integer backend
   only: compact cores keep using get-dao (they have no id index)."
  (let ((it (gethash table-name *int-tables*)))
    (when it
      (let ((row (funcall (int-fn 'int-text-index-by-id) it id)))
        (when row
          ;; kana-p: kana_table rows decode to compact-kana, kanji rows to
          ;; compact-kanji.
          (decode-int-row-at (not (search "kanji" table-name)) it row))))))

(defun memdict-csr-texts (conj-id source-text)
  "RAM mirror of (SELECT text FROM conj_source_reading WHERE conj_id = ?
   AND source_text = ?), in id order. NIL unless the table is loaded."
  (when (memdict-table-loaded-p "conj_source_reading")
    (let ((it (gethash "conj_source_reading" *int-tables*)))
      (if it
          (loop for (text src) in (funcall (int-fn 'int-csr-by-id) it conj-id)
                when (equal src source-text) collect text)
          (loop for r in (sort (copy-list (gethash conj-id *csr-by-id*))
                               '< :key 'compact-csr-id)
                when (equal (compact-csr-source-text r) source-text)
                  collect (compact-csr-text r))))))

(defun memdict-conj-seqs-from (from)
  "SEQ values whose conjugation has \"from\" = FROM (id order). NIL unless the
   conjugation table is loaded."
  (when (memdict-table-loaded-p "conjugation")
    (let ((it (gethash "conjugation" *int-tables*)))
      (if it
          (funcall (int-fn 'int-conj-seqs-by-from) it from)
          (loop for c in (sort (copy-list (gethash from *conj-by-from*))
                               '< :key 'compact-conj-id)
                collect (compact-conj-seq c))))))

(defun memdict-kana-forms (seq)
  "RAM mirror of ichiran/dict::get-kana-forms*'s UNION: kana_text rows for SEQ
   plus kana_text rows for seqs that have a conjugation whose \"from\" is SEQ,
   deduped by id (SQL UNION dedupes identical rows; kana rows are unique by id).
   NIL unless kana_text and conjugation are loaded."
  (when (memdict-tables-loaded-p "kana_text" "conjugation")
    (let ((seen (make-hash-table :test 'eql))
          (out nil))
      (flet ((add (rows)
               (dolist (r rows)
                 (let ((id (md-row-id r)))
                   (unless (gethash id seen)
                     (setf (gethash id seen) t)
                     (push r out))))))
        (add (memdict-rows-by-seq 'kana-text seq))
        (dolist (other (memdict-conj-seqs-from seq))
          (add (memdict-rows-by-seq 'kana-text other))))
      (nreverse out))))

;;; ---- R8/Tier 0.6: sense-ord probe, conj counts, remaining probes ----

(defvar *sense-ids-ord-0* nil
  "Hash set of sense ids whose ord is 0, built lazily from loaded senses.")

(defun memdict-ord-0-sense-ids ()
  "Hash set of sense ids with ord 0 (cached; cleared by memdict-reset)."
  (or *sense-ids-ord-0*
      (setf *sense-ids-ord-0*
            (let ((h (make-hash-table :test 'eql)))
              (maphash (lambda (seq senses)
                         (declare (ignore seq))
                         (dolist (s senses)
                           (when (zerop (compact-sense-ord s))
                             (setf (gethash (compact-sense-id s) h) t))))
                       *sense-by-seq*)
              h))))

(defun memdict-any-sense-ord-0-p (sense-ids)
  "T when any id in SENSE-IDS has ord 0. Mirrors the calc-score probe
   (SELECT id FROM sense WHERE id IN (...) AND ord = 0) being non-empty."
  (when (memdict-table-loaded-p "sense")
    (let ((set (memdict-ord-0-sense-ids)))
      (loop for id in sense-ids thereis (gethash id set)))))

(defun memdict-conj-count-by-seq-from (seqs from)
  "Number of conjugation rows with seq in SEQS and \"from\" = FROM."
  (when (memdict-table-loaded-p "conjugation")
    (let ((it (gethash "conjugation" *int-tables*))
          (n 0))
      (dolist (seq seqs)
        (let ((rows (if it
                        (funcall (int-fn 'int-conj-rows-by-seq) it seq)
                        (loop for c in (gethash seq *conj-by-seq*)
                              collect (list (compact-conj-id c) (compact-conj-seq c)
                                            (compact-conj-from c) (compact-conj-via c))))))
          (dolist (r rows)
            (when (eql (third r) from) (incf n)))))
      n)))

(defun memdict-words-by-conj-from (table-name word froms)
  "Rows of TABLE-NAME with TEXT = WORD whose seq appears as conj.seq for a
   conjugation row whose \"from\" is in FROMS. Mirrors find-word-conj-of's
   second query (the table/conjugation join)."
  (when (memdict-tables-loaded-p table-name "conjugation")
    (let ((seqs (loop for f in froms append (memdict-conj-seqs-from f))))
      (when seqs
        (loop for row in (memdict-text-rows-by-text table-name word)
              when (member (md-row-seq row) seqs :test '=)
                collect row)))))
