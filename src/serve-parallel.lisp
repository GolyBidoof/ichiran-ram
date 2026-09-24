;;;; src/serve-parallel.lisp - Tier 1: thread-parallel sentence serving.
;;;;
;;;; Why: the in-RAM dictionary is read-only after load and sentences are
;;;; independent, so a page of text is embarrassingly parallel. Measured on
;;;; 1456 corpus lines: 1.85x / 3.79x / 4.91x at 2 / 4 / 8 workers.
;;;;
;;;; Thread safety. Cache *initialization* is already locked (conn.lisp's
;;;; `ensure` double-checks under a per-cache mutex), but three memo tables are
;;;; written during serving and are NOT safe for concurrent writes:
;;;;
;;;;   *is-arch-cache*     (dict.lisp, one entry per unseen seq)
;;;;   *reading-cache*     (kanji.lisp, one entry per unseen word/reading)
;;;;   *memdict-fn-cache*  (dict.lisp, symbol -> function memo)
;;;;
;;;; plus cl-ppcre's scanner cache. Each worker therefore binds PRIVATE copies
;;;; of these, seeded from the warmed globals: reads still hit, writes stay
;;;; private, and no lock is needed on the hot path. Everything else touched
;;;; during romanize is either read-only after load or written only at
;;;; load time (the modified-hepburn slot write in romanize.lisp is inside
;;;; initialize-instance, not the serving path).
;;;;
;;;; Ordering. Output order must match input order, so a batch is distributed
;;;; by index into a result vector rather than printed as workers finish.

(defpackage #:ichiran/serve-parallel
  (:use #:cl)
  (:export #:serve-stream #:map-lines-parallel #:worker-count #:warm-caches
           #:romanize-safe #:probe-db #:*db-available*
           #:load-dictionary #:*dict-baked*
           ;; The bake extras: the three sets the snapshot format does not
           ;; carry. See src/bake-extras.lisp.
           #:load-bake-extras #:write-bake-extras #:bake-extras-path))

(in-package #:ichiran/serve-parallel)

(defvar *workers* nil
  "Cached worker count; override with the WORKERS environment variable.")

(defun cpu-count ()
  "Logical CPU count, or NIL when it cannot be determined. sb-posix is
   resolved at runtime: it is a contrib, so referencing the package at read
   time fails to load unless something already required it."
  (or (ignore-errors
        (progn (require :sb-posix)
               (let* ((pkg (find-package :sb-posix))
                      (fn (and pkg (fboundp (find-symbol "SYSCONF" pkg))
                               (symbol-function (find-symbol "SYSCONF" pkg))))
                      (key (and pkg (let ((s (find-symbol "_SC_NPROCS_ONLN" pkg)))
                                      (and s (symbol-value s))))))
                 (and fn key (funcall fn key)))))
      (ignore-errors
        (parse-integer
         (string-trim '(#\Space #\Newline)
                      (uiop:run-program '("sysctl" "-n" "hw.ncpu")
                                        :output :string :ignore-error-status t))
         :junk-allowed t))
      (ignore-errors
        (let ((s (uiop:getenv "NUMBER_OF_PROCESSORS")))
          (when s (parse-integer s :junk-allowed t))))))

(defun performance-core-count ()
  "Count of performance cores, or NIL where the OS does not distinguish.
   macOS exposes hw.perflevel0.logicalcpu; Linux generally does not, and its
   cores are homogeneous, so NIL there is fine."
  (ignore-errors
    (let ((out (uiop:run-program '("sysctl" "-n" "hw.perflevel0.logicalcpu")
                                 :output :string :ignore-error-status t)))
      (let ((n (parse-integer (string-trim '(#\Space #\Newline) out)
                              :junk-allowed t)))
        (and n (plusp n) n)))))

(defun worker-count ()
  "Workers to use: WORKERS env var if set, else the performance-core count,
   else one less than the logical CPU count.
   Measured on a 10P+4E machine (140 the visual novel dialogue lines, best of 2):
   8 workers 7.59x, 10 workers 7.82x, 11 workers 6.93x, 13 workers 6.63x,
   14 workers 5.66x. Past the P-core count the extra work lands on
   efficiency cores, which are far slower, so throughput FALLS - using
   cpu-count-1 as the default (13 here) was 15% slower than the optimum."
  (or *workers*
      (setf *workers*
            (max 1 (or (let ((env (uiop:getenv "WORKERS")))
                         (and env (parse-integer env :junk-allowed t)))
                       (performance-core-count)
                       (let ((cpus (cpu-count)))
                         (if cpus (max 1 (1- cpus)) 4)))))))

(defun romanize-safe (text)
  "Romanize TEXT, or an ERROR: line - never signals, so one bad sentence
   cannot kill a worker."
  (if (zerop (length text))
      ""
      (handler-case (ichiran:romanize text)
        (error (e) (format nil "ERROR: ~a" e)))))

(defun load-restricted-readings (&key conn)
  "Install RESTRICTED_READINGS into RAM from PostgreSQL.

   It is not one of the resident tables, so it has to be fetched explicitly. It
   is 6,332 rows, nothing next to a 2.9s dictionary load, and it takes
   MATCH-SENSE-RESTRICTIONS off the connection path while serving: measured over
   the F/SN prologue that one function cost about 2.6 ms per line, a third of
   core serving, because every call reached for a connection it did not need.

   LOAD-DICTIONARY calls this, and so does the core build. A baked core never
   calls LOAD-DICTIONARY, so without the build-time call the hash is empty,
   RAM-RESTRICTED-READINGS-AVAILABLE-P is false, and every restricted sense falls
   back to SQL: with PostgreSQL stopped, ROMANIZE failed on lines as ordinary as
   ＊いただきます＊ with 'No database connection selected.'"
  (handler-case
      (let ((rows (if conn
                      ;; The core build has no ambient connection: it passes an
                      ;; explicit spec to MEMDICT-LOAD/LOAD-INT and only clears
                      ;; the pool afterwards, so a bare QUERY here found no
                      ;; database and the readings were silently never baked.
                      (postmodern:with-connection conn
                        (postmodern:query
                         (:select 'seq 'reading 'text :from 'restricted-readings)))
                      (postmodern:query
                       (:select 'seq 'reading 'text :from 'restricted-readings)))))
        (format t "~&restricted readings for ~a seqs~%"
                (ichiran/memdict-compact:memdict-set-restricted-readings rows)))
    (error (e)
      (format t "~&restricted readings unavailable: ~a~%" e))))

(defun load-dictionary (&key (int-snapshot "local-env/ichiran-int.snap")
                             (sense-snapshot "local-env/ichiran-sense.snap"))
  "Load the whole dictionary into this image, preferring snapshots to SQL.

   The integer layer always comes from INT-SNAPSHOT. The sense layer comes from
   SENSE-SNAPSHOT when it exists, which is what lets the RAM path run with no
   database at all, and from PostgreSQL otherwise. Callers that have a baked
   core should not call this: check *DICT-BAKED* first."
  (let* ((extras (or (uiop:getenv "ICHIRAN_BAKE_SNAP")
                     "local-env/ichiran-bake.snap"))
         ;; All three artifacts present means this load needs no database at all,
         ;; so it must not open a socket even when a server happens to be there.
         ;; This is what makes a from-source build possible with no PostgreSQL.
         (dbless (and (probe-file int-snapshot)
                      (probe-file sense-snapshot)
                      (probe-file extras)
                      (fboundp 'load-bake-extras))))
    (let ((ichiran/conn::*no-database* dbless))
      (ichiran/conn:with-db nil
    (ichiran/memdict-compact:memdict-load-int :snapshot int-snapshot)
    (if (probe-file sense-snapshot)
        (progn
          (format t "~&load-dictionary: sense layer from ~a (no database)~%" sense-snapshot)
          (ichiran/memdict-compact:memdict-load-sense-snapshot
           sense-snapshot :int-snapshot int-snapshot))
        (progn
          (format t "~&load-dictionary: sense layer from PostgreSQL~%")
          (ichiran/memdict-compact:memdict-load
           :chunk 200000 :tables '("sense" "gloss" "sense_prop"))))
    ;; The three sets that are not in the snapshot format: archaic seqs, seqs
    ;; with no conjugation data, and the restricted readings. The extras file
    ;; carries all three, so this path needs no database. LOAD-RESTRICTED-READINGS
    ;; is the SQL fallback for a checkout that has a database and no extras yet.
    ;; The extra FBPOUNDP is only for someone loading this file without
    ;; src/bake-extras.lisp: a sentence beats an undefined-function error.
    (cond ((and (probe-file extras) (fboundp 'load-bake-extras))
           (load-bake-extras extras))
          (t
           (unless (probe-file extras)
             (format t "~&load-dictionary: no ~a, falling back to SQL for the ~
                        restricted readings and the arch/conj caches~%" extras))
           (load-restricted-readings)))
    (setf ichiran/dict::*memdict-p* t)
    ;; Size the flat gloss JSON caches from the dictionary just loaded, before
    ;; the warm pass, so the warm pass also fills them.
    (let ((m (ichiran/dict::gloss-json-cache-init)))
      (format t "~&load-dictionary: gloss json caches sized to seq<=~a (~,0f MB)~%"
              m (/ (* 8.0 (1+ m)) 1048576.0)))
    (warm-caches)
    ;; Probed, not asserted. On the snapshot path nothing above touched
    ;; PostgreSQL, so claiming T here would tell workers to open connections
    ;; for fallback paths without ever having checked that one can be opened.
    (setf *db-available* (probe-db))))
    ;; A server that was not there during the load stays not there for the rest
    ;; of the process, so serving takes the RAM paths instead of discovering it
    ;; once per lookup. *DB-AVAILABLE* was set by the probe above, inside the
    ;; binding, so it says NIL here exactly when the load went fully RAM.
    (when (and dbless (not *db-available*))
      (setf ichiran/conn::*no-database* t))
  (ichiran:romanize "テスト")
  (sleep 2)
  t))

(defun warm-caches ()
  "Force the one-time cache initializations in the main thread, so workers
   only ever read them. Safe to call repeatedly."
  (ignore-errors (ichiran/dict::ensure :is-arch))
  (ignore-errors (ichiran/dict::ensure :no-conj-data))
  ;; ord-0 sense-id set (lazy in the integer layer)
  (let ((pkg (find-package :ichiran/memdict-compact)))
    (when pkg
      (let ((fn (and (fboundp (intern "MEMDICT-ORD-0-SENSE-IDS" pkg))
                     (symbol-function (intern "MEMDICT-ORD-0-SENSE-IDS" pkg)))))
        (when fn (ignore-errors (funcall fn))))))
  ;; Exercise the analyzer paths once so lazy memo tables are populated. This
  ;; also runs the suffix cache to completion in the main thread, so workers
  ;; inherit a finished cache instead of each racing to build their own.
  ;; The probes below are chosen to trigger the expensive one-time paths, not
  ;; just to touch the analyzer. 聖杯戦争。 is six characters and measured 354ms
  ;; COLD against 1.678ms warm, a dense compound whose candidate lattice is the
  ;; worst case in the corpus; the other two add a katakana run and a long
  ;; comma-chained clause, the two shapes that dominate the warm tail. Paying
  ;; them here moves that cost off whichever request happens to arrive first.
  (dolist (probe '("日本語" "たべる" "がっこう" "読みます"
                   "聖杯戦争。"
                   "なにしろサーヴァントはいつマスターを裏切ってもおかしくない連中だ。"
                   "この冬木の土地には聖杯が在るとされ、過去何人もの魔術師たちが技を競い合ったという。"))
    (ignore-errors (ichiran:romanize probe)))
  ;; Run the suffix cache to completion here so workers inherit a finished one
  ;; instead of racing its builder.
  (ignore-errors (ichiran/dict::ensure-suffixes-ready))
  t)

(defun copy-memo-table (table)
  "Shallow copy of a memo hash table; SBCL has no built-in copier."
  (let ((new (make-hash-table :test (hash-table-test table)
                              :size (max 16 (hash-table-size table)))))
    (maphash (lambda (k v) (setf (gethash k new) v)) table)
    new))

(defvar *dict-baked* nil
  "T when the dictionary is already resident in the process image. A baked
   core sets this before dumping, so startup code can skip re-loading the
   snapshot and the sense layer, which is the whole point of the core.")

(defvar *db-available* nil
  "Whether workers should open their own DB connection. Probed once, so a
   DB-free core still serves (with only the verified-RAM paths).")

(defun probe-db ()
  "T when a connection can be opened with the default spec."
  (handler-case
      (progn (ichiran/conn:with-db nil (postmodern:query "SELECT 1" :single)) t)
    (error () nil)))

(defmacro with-worker-state (&body body)
  "Bind per-thread copies of the memo tables written during serving, and a
   PRIVATE DB connection. Postmodern's *database* is a global special, so a
   worker that inherited the parent's connection object would use it
   concurrently and corrupt the protocol - each worker opens its own."
  `(let ((ichiran/dict::*is-arch-cache*
           (copy-memo-table (ichiran/dict::ensure :is-arch)))
         (ichiran/kanji::*reading-cache*
           (copy-memo-table ichiran/kanji::*reading-cache*))
         (ichiran/dict::*memdict-fn-cache*
           (copy-memo-table ichiran/dict::*memdict-fn-cache*))
         ;; A FRESH table, not a copy: this is a per-worker score cache whose
         ;; whole value is accumulating across the batch. It is entered once
         ;; per worker for the worker's lifetime, so it stays warm from the
         ;; first dozen sentences onward and needs no lock.
         (ichiran/dict::*gen-score-cache*
           (make-hash-table :test 'eql :size 8192)))
     ;; NOTE: cl-ppcre in this tree exposes no scanner cache at all, so there
     ;; is no shared scanner table to protect. Caching scanners was tried
     ;; anyway and LOST: see worklogs/LOAD-AND-SPEED-PLAN.md ("allocation share
     ;; is not time share").
     (if *db-available*
         (ichiran/conn:with-db nil ,@body)
         (progn ,@body))))

(defun map-lines-parallel (lines fn &key (workers (worker-count)))
  "Apply FN to each line of vector LINES using WORKERS threads. Returns a
   vector of results in input order. FN must be thread-safe."
  (let* ((n (length lines))
         (results (make-array n))
         (next 0)
         (lock (sb-thread:make-mutex :name "serve-parallel work"))
         (nworkers (min workers (max 1 n)))
         (threads
           (loop for i below nworkers
                 collect (sb-thread:make-thread
                          (lambda ()
                            (with-worker-state
                              (loop for idx = (sb-thread:with-mutex (lock)
                                                (when (< next n)
                                                  (prog1 next (incf next))))
                                    while idx
                                    do (setf (aref results idx)
                                             (funcall fn (aref lines idx))))))
                          :name (format nil "ichiran-worker-~a" i)))))
    (mapc #'sb-thread:join-thread threads)
    results))

(defun serve-stream (&key (in *standard-input*) (out *standard-output*)
                          (batch 256) (workers (worker-count)))
  "Read sentences from IN, romanize them across WORKERS threads, and write one
   result line per input line to OUT in input order. Prints a ready line
   first (the core's banner precedes it; clients skip until then)."
  (warm-caches)
  (setf *db-available* (probe-db))
  (format out "{\"ready\":true,\"workers\":~a,\"db\":~a}~%"
          workers (if *db-available* "true" "false"))
  (finish-output out)
  (loop
    (let ((lines (make-array 0 :adjustable t :fill-pointer 0)))
      (dotimes (i batch)
        (let ((line (read-line in nil nil)))
          (if line
              (vector-push-extend
               (string-trim '(#\Space #\Tab #\Newline #\Return) line) lines)
              (return))))
      (when (zerop (length lines)) (return))
      (let ((results (map-lines-parallel lines #'romanize-safe :workers workers)))
        (dotimes (i (length results))
          (write-string (aref results i) out)
          (terpri out))
        (finish-output out))))
  (finish-output out)
  t)
