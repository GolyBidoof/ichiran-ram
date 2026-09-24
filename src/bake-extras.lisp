;;;; src/bake-extras.lisp - the three data sets a database-free build still needs.
;;;;
;;;; Serving has been database-free since the snapshot work. Building the
;;;; dictionary was not. Four things were fetched from PostgreSQL while the
;;;; snapshots and the core were built, and baked in, so a build with no
;;;; database produced a core that failed on the first restricted sense or
;;;; archaic word:
;;;;
;;;;   :is-arch              a set of seqs (dict.lisp), scoring: archaic senses
;;;;                         are worth fewer points, and how many points is a
;;;;                         tiebreak, so this changes output when it is missing
;;;;   :no-conj-data         a set of seqs (dict.lisp), conjugation lookups
;;;;   restricted-readings   6,332 (seq reading text) rows
;;;;   :counters             the number counter cache (dict-counters.lisp)
;;;;
;;;; The first three are computed here, once, while a database is still around,
;;;; and written to local-env/ichiran-bake.snap next to the two snapshots that
;;;; already exist. Installing them pre-sets the cache specials, and ENSURE is
;;;; (or (symbol-value var) (init-cache ...)), so a value that is already there
;;;; is returned as is and the SQL bodies in dict.lisp are never reached. That
;;;; is the whole trick, and it needs no change to dict.lisp.
;;;;
;;;; :counters needs no entry here. It is a cache of closures built by a
;;;; function, not a set of rows, so it would not survive a round trip anyway.
;;;; Its input now comes from the RAM layer instead: see COUNTER-TEXT-ROWS in
;;;; dict-counters.lisp, which follows the same pattern dict.lisp already uses
;;;; in get-kanji-kana-old and get-counter-ids.
;;;;
;;;; The file format is the little-endian primitives from int-snapshot, so the
;;;; tree keeps one binary reader and one binary writer rather than two.
(in-package #:ichiran/serve-parallel)

(eval-when (:compile-toplevel :load-toplevel :execute)
  ;; sb-posix is a contrib: CPU-COUNT below already requires it at runtime for
  ;; the same reason, and this file opens files with it at load time.
  (require :sb-posix))

(defparameter *bake-extras-magic* "ICHBAKE1"
  "8-byte file magic. Different from the snapshot magic on purpose: this is a
   separate file with a separate lifetime, and a mixed-up pair should say so
   rather than be read as garbage.")

(defparameter *bake-extras-version* 1
  "Bumped when the layout below changes. The loader refuses other versions
   instead of misreading them.")

(defparameter *bake-extras-default* "local-env/ichiran-bake.snap")

(defun bake-extras-path ()
  "Where the bake extras live. ICHIRAN_BAKE_SNAP overrides the default."
  (or (uiop:getenv "ICHIRAN_BAKE_SNAP") *bake-extras-default*))

(defun bake-extras-sql (&key conn)
  "Fetch the three sets from PostgreSQL.
   Returns (values is-arch-seqs no-conj-seqs restricted-rows)."
  (flet ((collect ()
           (values (alexandria:hash-table-keys (ichiran/dict::ensure :is-arch))
                   (alexandria:hash-table-keys (ichiran/dict::ensure :no-conj-data))
                   (postmodern:query
                    (:select 'seq 'reading 'text :from 'restricted-readings)))))
    (if conn
        ;; The core build has no ambient connection, the same reason
        ;; load-restricted-readings takes an explicit spec.
        (postmodern:with-connection conn (collect))
        (collect))))

(defun write-bake-extras (path &key conn)
  "Write the three sets to PATH. Returns the byte size.
   Needs a database, which is the point: it runs while the other snapshots are
   being built, so no later step has to."
  (multiple-value-bind (is-arch no-conj restricted) (bake-extras-sql :conn conn)
    (let ((seqs (coerce (sort (copy-list is-arch) '<) 'vector))
          (no-conj-seqs (coerce (sort (copy-list no-conj) '<) 'vector))
          (r-seq (coerce (mapcar #'first restricted) 'vector))
          (r-reading (coerce (mapcar #'second restricted) 'vector))
          (r-text (coerce (mapcar #'third restricted) 'vector)))
      (let ((fd (sb-posix:open path (logior sb-posix:o-wronly sb-posix:o-creat
                                             sb-posix:o-trunc)
                               #o644)))
        (unwind-protect
             (let ((sink (ichiran/int-snapshot::make-sink fd)))
               (ichiran/int-snapshot::sink-octets
                sink (sb-ext:string-to-octets *bake-extras-magic*
                                              :external-format :ascii))
               (ichiran/int-snapshot::sink-u8 sink *bake-extras-version*)
               (dolist (v (list seqs no-conj-seqs r-seq r-reading r-text))
                 (ichiran/int-snapshot::write-value sink v))
               (ichiran/int-snapshot::sink-flush sink)
               (sb-posix:lseek fd 0 sb-posix:seek-end))
          (sb-posix:close fd))))))

(defun bake-extras-file-p (path)
  "T when PATH starts with this file's magic, without reading it all."
  (and (probe-file path)
       (handler-case
           (let ((fd (sb-posix:open path sb-posix:o-rdonly)))
             (unwind-protect
                  (let ((src (ichiran/int-snapshot::make-source fd)))
                    (equal (sb-ext:octets-to-string
                            (ichiran/int-snapshot::source-octets
                             src (length *bake-extras-magic*))
                            :external-format :ascii)
                           *bake-extras-magic*))
               (sb-posix:close fd)))
         (error () nil))))

(defun read-bake-extras (path)
  "Read PATH and return (values is-arch-seqs no-conj-seqs restricted-rows).
   Errors rather than guessing when the file is not one of ours."
  (let ((fd (sb-posix:open path sb-posix:o-rdonly)))
    (unwind-protect
         (let ((src (ichiran/int-snapshot::make-source fd)))
           (unless (equal (sb-ext:octets-to-string
                           (ichiran/int-snapshot::source-octets
                            src (length *bake-extras-magic*))
                           :external-format :ascii)
                          *bake-extras-magic*)
             (error "bake-extras: ~a is not a bake extras file" path))
           (let ((version (ichiran/int-snapshot::source-u8 src)))
             (unless (= version *bake-extras-version*)
               (error "bake-extras: ~a is version ~a and this code reads ~a. ~
                       Rebuild it with scripts/build-snapshot.sh."
                      path version *bake-extras-version*)))
           (values (ichiran/int-snapshot::read-value src)
                   (ichiran/int-snapshot::read-value src)
                   (let ((seqs (ichiran/int-snapshot::read-value src))
                         (readings (ichiran/int-snapshot::read-value src))
                         (texts (ichiran/int-snapshot::read-value src)))
                     (loop for i from 0 below (length seqs)
                           collect (list (aref seqs i)
                                         (aref readings i)
                                         (aref texts i))))))
      (sb-posix:close fd))))

(defun load-bake-extras (&optional (path (bake-extras-path)))
  "Install the bake extras from PATH into RAM. Returns (values seqs restricted).
   After this, IS-ARCH and NO-CONJ-DATA answer from RAM and the restricted
   readings are in the RAM layer, so no part of serving or scoring reaches for
   PostgreSQL."
  (multiple-value-bind (seqs no-conj-seqs restricted) (read-bake-extras path)
    (let ((is-arch (make-hash-table :size (max 4096 (length seqs))))
          (no-conj (make-hash-table :size (max 4096 (length no-conj-seqs)))))
      (loop for seq across seqs do (setf (gethash seq is-arch) t))
      (loop for seq across no-conj-seqs do (setf (gethash seq no-conj) t))
      ;; Pre-set the specials. ENSURE returns these untouched, so the SQL
      ;; bodies in dict.lisp cannot run even if something calls ENSURE later.
      (setf ichiran/dict::*is-arch-cache* is-arch
            ichiran/dict::*no-conj-data* no-conj)
      (let ((restricted-seqs
              (ichiran/memdict-compact:memdict-set-restricted-readings restricted)))
        (format t "~&bake-extras: ~a archaic seqs, ~a without conj data, ~
                   ~a restricted seqs from ~a~%"
                (length seqs) (length no-conj-seqs) restricted-seqs path)
        (values (+ (length seqs) (length no-conj-seqs)) restricted-seqs)))))
