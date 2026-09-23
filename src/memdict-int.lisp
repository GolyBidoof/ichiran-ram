;;;; src/memdict-int.lisp — integer-keyed compact dictionary (milestone 1).
;;;;
;;;; Why: memdict-compact stores one defstruct + hash entries per row
;;;; (~2.7GB for kana_text). Most of that is per-row overhead, not data.
;;;; This module stores each table as:
;;;;   - column vectors in id order (fixnum/(unsigned-byte 32) arrays),
;;;;   - a text-major position array + per-text (start,count) ranges,
;;;;   - a seq-major position array + dense per-seq (start,count) ranges
;;;;     (seq values are dense integers, so direct indexing beats hashing),
;;;;   - pooled string vectors for texts/tags/readings (stored once).
;;;; Target: kana_text in ~1.5GB (measured below), full dict servable on 16GB.
;;;;
;;;; Bare-load safe: pure CL + postmodern, no ichiran deps. All queries take
;;;; an explicit table object (no globals), so serving cores can hold several.

(defpackage #:ichiran/memdict-int
  (:use #:cl #:postmodern)
  (:export #:int-load-text #:int-text-by-seq #:int-text-find
           #:int-text-row-count #:int-text-table-p
           #:int-text-row #:int-text-find-rows #:int-text-rows-by-seq
           #:int-text-find-by-seq #:int-text-by-id
           #:int-text-row-fields #:int-text-find-rows-indexes #:int-text-index-by-id
           #:int-text-rows-by-seq-indexes #:int-text-find-by-seq-indexes
           #:int-load-entry #:int-entry-by-seq #:int-entry-row-count
           #:int-load-conjugation #:int-conj-row-count
           #:int-has-conj-p #:int-conj-rows-by-seq #:int-conj-seqs-by-from
           #:int-load-conj-prop #:int-conj-prop-row-count #:int-conj-props-by-id
           #:int-load-csr #:int-csr-row-count #:int-csr-by-id
           #:make-int-text-table))

(in-package #:ichiran/memdict-int)

(defstruct int-text-table
  (n 0 :type fixnum)
  (texts #() :type simple-vector)
  (text-index (make-hash-table :test 'equal))
  (ids #() :type (simple-array (unsigned-byte 32) (*)))
  (seqs #() :type (simple-array (unsigned-byte 32) (*)))
  (ords #() :type (simple-array (unsigned-byte 32) (*)))
  (ranks #() :type (simple-array (unsigned-byte 32) (*)))
  (text-ids #() :type (simple-array (unsigned-byte 32) (*)))
  (commons #() :type (simple-array (signed-byte 32) (*)))
  (flags #() :type (simple-array (unsigned-byte 8) (*)))
  (tags #() :type simple-vector)
  (tag-ids #() :type (simple-array (unsigned-byte 32) (*)))
  (kanjis #() :type simple-vector)
  (kanji-ids #() :type (simple-array (unsigned-byte 32) (*)))
  (kanas #() :type simple-vector)
  (kana-ids #() :type (simple-array (unsigned-byte 32) (*)))
  (text-major #() :type (simple-array (unsigned-byte 32) (*)))
  (text-start #() :type (simple-array (unsigned-byte 32) (*)))
  (text-count #() :type (simple-array (unsigned-byte 32) (*)))
  (seq-major #() :type (simple-array (unsigned-byte 32) (*)))
  (seq-start #() :type (simple-array (unsigned-byte 32) (*)))
  (seq-count #() :type (simple-array (unsigned-byte 32) (*)))
  (max-seq 0 :type fixnum))

(defun default-conn ()
  (let ((pkg (find-package :ichiran/conn)))
    (if pkg
        (symbol-value (find-symbol "*CONNECTION*" pkg))
        (error "int-load-text needs a :conn spec (no ichiran/conn loaded)"))))

(defun int-load-text (table &key (chunk 200000) conn)
  "Load kana_text or kanji_text into an integer-keyed table. ORDER BY id (unordered
   LIMIT/OFFSET paging silently loses rows). Returns (values table bytes)."
  (sb-ext:gc :full t)
  (let ((before (sb-kernel:dynamic-usage)))
    (let* ((conn (or conn (default-conn)))
           (best-col (cond ((equal table "kana_text") "best_kanji")
                           ((equal table "kanji_text") "best_kana")
                           (t (error "int-load-text: unknown text table ~a" table))))
           (best-is-kanji (equal table "kana_text"))
           (est (if best-is-kanji 3350000 5500000))
           (est-texts (if best-is-kanji 3100000 5400000))
          (ids (make-array est :element-type '(unsigned-byte 32)
                           :fill-pointer 0 :adjustable t))
          (seqs (make-array est :element-type '(unsigned-byte 32)
                            :fill-pointer 0 :adjustable t))
          (ords (make-array est :element-type '(unsigned-byte 32)
                            :fill-pointer 0 :adjustable t))
          (text-ids (make-array est :element-type '(unsigned-byte 32)
                                :fill-pointer 0 :adjustable t))
          (commons (make-array est :element-type '(signed-byte 32)
                               :fill-pointer 0 :adjustable t))
          (flags (make-array est :element-type '(unsigned-byte 8)
                             :fill-pointer 0 :adjustable t))
          (tag-ids (make-array est :element-type '(unsigned-byte 32)
                               :fill-pointer 0 :adjustable t))
          (kanji-ids (make-array est :element-type '(unsigned-byte 32)
                                 :fill-pointer 0 :adjustable t))
          (kana-ids (make-array est :element-type '(unsigned-byte 32)
                                :fill-pointer 0 :adjustable t))
          (texts (make-array est-texts :fill-pointer 0 :adjustable t))
          (text-index (make-hash-table :test 'equal :size est-texts))
          (tags-pool (make-array 1024 :fill-pointer 0 :adjustable t))
          (tag-pool-idx (make-hash-table :test 'equal))
          (kanjis-pool (make-array 1024 :fill-pointer 0 :adjustable t))
          (kanji-pool-idx (make-hash-table :test 'equal))
          (kanas-pool (make-array 1024 :fill-pointer 0 :adjustable t))
          (kana-pool-idx (make-hash-table :test 'equal))
          (max-seq 0))
      (labels ((pool (s pool-vec pool-idx)
                 (or (gethash s pool-idx)
                     (let ((i (fill-pointer pool-vec)))
                       (vector-push-extend s pool-vec)
                       (setf (gethash s pool-idx) i)
                       i))))
        ;; Null sentinel: "" is always pool index 0 on both sides.
        (pool "" kanjis-pool kanji-pool-idx)
        (pool "" kanas-pool kana-pool-idx)
        (postmodern:with-connection conn
          ;; Keyset pagination, not LIMIT/OFFSET: with OFFSET k Postgres
          ;; re-scans and discards k rows for every chunk, which is quadratic
          ;; (conj_source_reading needs 42 chunks for its 8.4M rows).
          (loop with last-id = -1
                for rows = (postmodern:query
                            (format nil "SELECT id, seq, text, ord, common, common_tags, conjugate_p, nokanji, ~a FROM ~a WHERE id > ~a ORDER BY id LIMIT ~a"
                                    best-col table last-id chunk)
                            :lists)
                while rows
                do (dolist (pl rows)
                     (destructuring-bind (id seq text ord common tags conj nokanji best-kanji) pl
                       (let ((ti (or (gethash text text-index)
                                     (let ((i (fill-pointer texts)))
                                       (vector-push-extend text texts)
                                       (setf (gethash text text-index) i)
                                       i))))
                         (vector-push-extend id ids)
                         (vector-push-extend seq seqs)
                         (vector-push-extend ord ords)
                         (vector-push-extend ti text-ids)
                         (vector-push-extend (if (eql common :null) -1 common) commons)
                         (vector-push-extend (logior (if conj 1 0) (if nokanji 2 0)) flags)
                         (vector-push-extend (pool tags tags-pool tag-pool-idx) tag-ids)
                         (let ((best (if (eql best-kanji :null) "" best-kanji)))
                           (if best-is-kanji
                               (progn (vector-push-extend (pool best kanjis-pool kanji-pool-idx) kanji-ids)
                                      (vector-push-extend 0 kana-ids))
                               (progn (vector-push-extend 0 kanji-ids)
                                      (vector-push-extend (pool best kanas-pool kana-pool-idx) kana-ids))))
                         (when (> seq max-seq) (setf max-seq seq)))))
                   (setf last-id (caar (last rows))))))
        ;; Freeze columns (explicit copies: fill-pointer semantics of
        ;; coerce are implementation-subtle; replace respects active length).
        (let* ((n (fill-pointer ids))
               (freeze-u32 (lambda (v) (let ((out (make-array n :element-type '(unsigned-byte 32))))
                                         (replace out v))))
               (freeze-i32 (lambda (v) (let ((out (make-array n :element-type '(signed-byte 32))))
                                         (replace out v))))
               (freeze-u8 (lambda (v) (let ((out (make-array n :element-type '(unsigned-byte 8))))
                                        (replace out v))))
               (freeze-vec (lambda (v) (let ((out (make-array (fill-pointer v))))
                                         (replace out v))))
               (texts-vec (funcall freeze-vec texts))
               (nt (length texts-vec))
               (text-major (make-array n :element-type '(unsigned-byte 32)))
               (text-start (make-array nt :element-type '(unsigned-byte 32) :initial-element 0))
               (text-count (make-array nt :element-type '(unsigned-byte 32) :initial-element 0))
               (seq-major (make-array n :element-type '(unsigned-byte 32)))
               (seq-start (make-array (1+ max-seq) :element-type '(unsigned-byte 32) :initial-element 0))
               (seq-count (make-array (1+ max-seq) :element-type '(unsigned-byte 32) :initial-element 0))
               ;; Physical row order. The database path reaches these rows
               ;; through select-dao calls that carry no ORDER BY, so Postgres
               ;; returns them in ctid order (the text btree stores equal keys
               ;; in ctid order, so an index scan preserves it). Downstream,
               ;; expand-segment-list stable-sorts candidates by score and a
               ;; stable sort leaves ties in input order, which makes this
               ;; order visible in the output: 72 of 364 golden lines differed
               ;; purely because the tie-break here was id rather than
               ;; physical position.
               (ranks (let* ((heap-ids (query (format nil "SELECT id FROM ~a ORDER BY ctid"
                                                      table)
                                              :column))
                             (rank-of-id (make-array (1+ (reduce #'max heap-ids))
                                                     :element-type '(unsigned-byte 32)
                                                     :initial-element 0)))
                        (loop for id in heap-ids for r from 0
                              do (setf (aref rank-of-id id) r))
                        (let ((out (make-array n :element-type '(unsigned-byte 32))))
                          (loop for i from 0 below n
                                do (setf (aref out i)
                                         (aref rank-of-id (aref ids i))))
                          out))))
          ;; Text-major order: sort row indices by (text-idx, physical rank).
          ;; Key packs into one fixnum (text-idx < 2^22, rank < 2^32).
          (let ((order (make-array n :element-type 'fixnum)))
            (loop for i from 0 below n do (setf (aref order i) i))
            (sort order '< :key (lambda (i) (+ (ash (aref text-ids i) 32)
                                               (aref ranks i))))
            (loop for pos from 0 below n
                  for i = (aref order pos)
                  do (setf (aref text-major pos) i)
                     (let ((ti (aref text-ids i)))
                       (when (zerop (aref text-count ti))
                         (setf (aref text-start ti) pos))
                       (incf (aref text-count ti)))))
          ;; Seq-major order: sort row indices by (seq, id). Same packing
          ;; (seq < 2^24).
          (let ((order (make-array n :element-type 'fixnum)))
            (loop for i from 0 below n do (setf (aref order i) i))
            (sort order '< :key (lambda (i) (+ (ash (aref seqs i) 32)
                                               (aref ranks i))))
            (loop for pos from 0 below n
                  for i = (aref order pos)
                  do (setf (aref seq-major pos) i)
                     (let ((sq (aref seqs i)))
                       (when (zerop (aref seq-count sq))
                         (setf (aref seq-start sq) pos))
                       (incf (aref seq-count sq)))))
          (sb-ext:gc :full t)
          (let ((after (sb-kernel:dynamic-usage)))
            (values (make-int-text-table
                     :n n :texts texts-vec :text-index text-index
                     :ids (funcall freeze-u32 ids) :seqs (funcall freeze-u32 seqs)
                     :ords (funcall freeze-u32 ords) :ranks (funcall freeze-u32 ranks)
                     :text-ids (funcall freeze-u32 text-ids)
                     :commons (funcall freeze-i32 commons)
                     :flags (funcall freeze-u8 flags)
                     :tags (funcall freeze-vec tags-pool) :tag-ids (funcall freeze-u32 tag-ids)
                     :kanjis (funcall freeze-vec kanjis-pool) :kanji-ids (funcall freeze-u32 kanji-ids)
                     :kanas (funcall freeze-vec kanas-pool) :kana-ids (funcall freeze-u32 kana-ids)
                     :text-major text-major :text-start text-start :text-count text-count
                     :seq-major seq-major :seq-start seq-start :seq-count seq-count
                     :max-seq max-seq)
                    (- after before)))))))

(defun int-text-row-count (table)
  (int-text-table-n table))

(defun int-text-by-seq (table seq &optional (ord 0))
  "First TEXT for SEQ with ORD (mirrors memdict-text-by-seq). NIL if none."
  (when (<= seq (int-text-table-max-seq table))
    (let ((start (aref (int-text-table-seq-start table) seq))
          (count (aref (int-text-table-seq-count table) seq)))
      (loop for k from start below (+ start count)
            for row = (aref (int-text-table-seq-major table) k)
            when (= (aref (int-text-table-ords table) row) ord)
              do (let ((ti (aref (int-text-table-text-ids table) row)))
                   (return (aref (int-text-table-texts table) ti)))))))

(defun int-text-row-fields (table row)
  "The ten decoded text-row fields as multiple values, without consing a
   plist: id seq text ord common common-tags conjugate-p nokanji
   best-kanji best-kana. Callers build their struct directly from these."
  (values (aref (int-text-table-ids table) row)
          (aref (int-text-table-seqs table) row)
          (aref (int-text-table-texts table)
                (aref (int-text-table-text-ids table) row))
          (aref (int-text-table-ords table) row)
          (let ((c (aref (int-text-table-commons table) row)))
            (if (= c -1) :null c))
          (aref (int-text-table-tags table)
                (aref (int-text-table-tag-ids table) row))
          (plusp (logand (aref (int-text-table-flags table) row) 1))
          (plusp (logand (aref (int-text-table-flags table) row) 2))
          (let ((b (aref (int-text-table-kanjis table)
                         (aref (int-text-table-kanji-ids table) row))))
            (if (equal b "") nil b))
          (let ((b (aref (int-text-table-kanas table)
                         (aref (int-text-table-kana-ids table) row))))
            (if (equal b "") nil b))))

(defun int-text-find-rows-indexes (table text)
  "Row indexes for TEXT in id order. NIL if none."
  (multiple-value-bind (ti found) (gethash text (int-text-table-text-index table))
    (when found
      (let ((start (aref (int-text-table-text-start table) ti))
            (count (aref (int-text-table-text-count table) ti)))
        (loop for k from start below (+ start count)
              for row = (aref (int-text-table-text-major table) k)
              collect row)))))

(defun int-text-rows-by-seq-indexes (table seq)
  "Row indexes for SEQ in ord order. NIL if none."
  (when (<= seq (int-text-table-max-seq table))
    (let ((start (aref (int-text-table-seq-start table) seq))
          (count (aref (int-text-table-seq-count table) seq)))
      (when (plusp count)
        (stable-sort (loop for k from start below (+ start count)
                           for row = (aref (int-text-table-seq-major table) k)
                           collect row)
                     '< :key (lambda (r) (aref (int-text-table-ords table) r)))))))

(defun int-text-find-by-seq-indexes (table seq)
  "Row indexes for SEQ in physical (ctid) order, matching the database. The
   seq-major index already uses physical rank as its tie-break, so re-sorting
   by id here is exactly what reordered tied candidates."
  (when (<= seq (int-text-table-max-seq table))
    (let ((start (aref (int-text-table-seq-start table) seq))
          (count (aref (int-text-table-seq-count table) seq)))
      (when (plusp count)
        (sort (loop for k from start below (+ start count)
                    for row = (aref (int-text-table-seq-major table) k)
                    collect row)
              '< :key (lambda (r) (aref (int-text-table-ids table) r)))))))

(defun int-text-row (table row)
  "Decode ROW (integer index) to a plist with all fields. BEST is the
   best-kanji/best-kana string or NIL (:null in DB); SIDE tells which."
  (list :id (aref (int-text-table-ids table) row)
          :seq (aref (int-text-table-seqs table) row)
          :text (aref (int-text-table-texts table)
                      (aref (int-text-table-text-ids table) row))
          :ord (aref (int-text-table-ords table) row)
          :common (let ((c (aref (int-text-table-commons table) row)))
                    (if (= c -1) :null c))
          :common-tags (aref (int-text-table-tags table)
                             (aref (int-text-table-tag-ids table) row))
          :conjugate-p (plusp (logand (aref (int-text-table-flags table) row) 1))
          :nokanji (plusp (logand (aref (int-text-table-flags table) row) 2))
          :best-kanji (let ((b (aref (int-text-table-kanjis table)
                                     (aref (int-text-table-kanji-ids table) row))))
                        (if (equal b "") nil b))
          :best-kana (let ((b (aref (int-text-table-kanas table)
                                    (aref (int-text-table-kana-ids table) row))))
                       (if (equal b "") nil b))))

(defun int-text-index-by-id (table id)
  "Row index for primary key ID, or NIL. Binary search over the ascending
   ids vector (ids have gaps, so id-1 is not an index)."
  (let ((ids (int-text-table-ids table)))
    (loop with lo = 0
          with hi = (1- (length ids))
          while (<= lo hi)
          for mid = (ash (+ lo hi) -1)
          for v = (aref ids mid)
          do (cond ((= v id) (return mid))
                   ((< v id) (setf lo (1+ mid)))
                   (t (setf hi (1- mid)))))))

(defun int-text-by-id (table id)
  "Decoded row plist for primary key ID, or NIL. IDS is ascending (loaded
   ORDER BY id) so this is a binary search; ids have gaps, so a direct
   id-1 index would be wrong."
  (let ((ids (int-text-table-ids table)))
    (loop with lo = 0
          with hi = (1- (length ids))
          while (<= lo hi)
          for mid = (ash (+ lo hi) -1)
          for v = (aref ids mid)
          do (cond ((= v id) (return (int-text-row table mid)))
                   ((< v id) (setf lo (1+ mid)))
                   (t (setf hi (1- mid)))))))

(defun int-text-find-rows (table text)
  "List of decoded row plists for TEXT in id order. NIL if none."
  (multiple-value-bind (ti found) (gethash text (int-text-table-text-index table))
    (when found
      (let ((start (aref (int-text-table-text-start table) ti))
            (count (aref (int-text-table-text-count table) ti)))
        (loop for k from start below (+ start count)
              for row = (aref (int-text-table-text-major table) k)
              collect (int-text-row table row))))))

(defun int-text-rows-by-seq (table seq)
  "List of decoded row plists for SEQ in ord order. NIL if none."
  (when (<= seq (int-text-table-max-seq table))
    (let ((start (aref (int-text-table-seq-start table) seq))
          (count (aref (int-text-table-seq-count table) seq))
          (out nil))
      (loop for k from start below (+ start count)
            for row = (aref (int-text-table-seq-major table) k)
            do (push (int-text-row table row) out))
      (stable-sort out '< :key (lambda (r) (getf r :ord))))))

(defun int-text-find-by-seq (table seq)
  "List of decoded row plists for SEQ in id order (mirror of DB select-dao
   order for memdict-find-by-seq). NIL if none."
  (when (<= seq (int-text-table-max-seq table))
    (let ((start (aref (int-text-table-seq-start table) seq))
          (count (aref (int-text-table-seq-count table) seq))
          (out nil))
      (loop for k from start below (+ start count)
            for row = (aref (int-text-table-seq-major table) k)
            do (push (int-text-row table row) out))
      (sort out '< :key (lambda (r) (getf r :id))))))

;;; ---- entry table (keyed by seq, unique: dense direct index) ----

(defun int-load-entry (&key (chunk 200000) conn)
  "Load entry into columns + dense seq direct index. ORDER BY seq."
  (sb-ext:gc :full t)
  (let ((before (sb-kernel:dynamic-usage)))
    (let ((conn (or conn (default-conn)))
          (seqs (make-array 2600000 :element-type '(unsigned-byte 32)
                            :fill-pointer 0 :adjustable t))
          (content-ids (make-array 2600000 :element-type '(unsigned-byte 32)
                                   :fill-pointer 0 :adjustable t))
          (flags (make-array 2600000 :element-type '(unsigned-byte 8)
                             :fill-pointer 0 :adjustable t))
          (nkanji (make-array 2600000 :element-type '(unsigned-byte 32)
                              :fill-pointer 0 :adjustable t))
          (nkana (make-array 2600000 :element-type '(unsigned-byte 32)
                             :fill-pointer 0 :adjustable t))
          (contents (make-array 1024 :fill-pointer 0 :adjustable t))
          (content-index (make-hash-table :test 'equal))
          (max-seq 0))
      (labels ((pool (s)
                 (or (gethash s content-index)
                     (let ((i (fill-pointer contents)))
                       (vector-push-extend s contents)
                       (setf (gethash s content-index) i)
                       i))))
        (postmodern:with-connection conn
          (loop with last-seq = -1
                for rows = (postmodern:query
                            (format nil "SELECT seq, content, root_p, n_kanji, n_kana, primary_nokanji FROM entry WHERE seq > ~a ORDER BY seq LIMIT ~a"
                                    last-seq chunk)
                            :lists)
                while rows
                do (dolist (pl rows)
                     (destructuring-bind (seq content root-p n-kanji n-kana primary-nokanji) pl
                       (vector-push-extend seq seqs)
                       (vector-push-extend (pool content) content-ids)
                       (vector-push-extend (logior (if root-p 1 0)
                                                   (if primary-nokanji 2 0))
                                           flags)
                       (vector-push-extend n-kanji nkanji)
                       (vector-push-extend n-kana nkana)
                       (when (> seq max-seq) (setf max-seq seq))))
                   (setf last-seq (caar (last rows))))))
        (let* ((n (fill-pointer seqs))
               (freeze (lambda (v et) (let ((out (make-array n :element-type et)))
                                        (replace out v))))
               (seq-vec (funcall freeze seqs '(unsigned-byte 32)))
               (direct (make-array (1+ max-seq) :element-type '(signed-byte 32)
                                   :initial-element -1)))
          (loop for i from 0 below n
                do (setf (aref direct (aref seq-vec i)) i))
          (sb-ext:gc :full t)
          (let ((after (sb-kernel:dynamic-usage)))
            (values (list :n n
                          :seqs seq-vec
                          :contents (let ((out (make-array (fill-pointer contents))))
                                      (replace out contents))
                          :content-ids (funcall freeze content-ids '(unsigned-byte 32))
                          :flags (funcall freeze flags '(unsigned-byte 8))
                          :nkanji (funcall freeze nkanji '(unsigned-byte 32))
                          :nkana (funcall freeze nkana '(unsigned-byte 32))
                          :direct direct
                          :max-seq max-seq)
                     (- after before)))))))

(defun int-entry-row-count (table)
  (getf table :n))

(defun int-entry-by-seq (table seq)
  "Plist (:seq :content :root-p :n-kanji :n-kana :primary-nokanji) or NIL."
  (when (<= seq (getf table :max-seq))
    (let ((i (aref (getf table :direct) seq)))
      (when (>= i 0)
        (let ((fl (aref (getf table :flags) i)))
          (list :seq seq
                :content (aref (getf table :contents)
                               (aref (getf table :content-ids) i))
                :root-p (plusp (logand fl 1))
                :n-kanji (aref (getf table :nkanji) i)
                :n-kana (aref (getf table :nkana) i)
                :primary-nokanji (plusp (logand fl 2))))))))

(defun int-text-find (table text)
  "List of (id seq ord) for TEXT in id order (mirror of memdict-find shape
   for verification; serving returns richer rows later)."
  (multiple-value-bind (ti found) (gethash text (int-text-table-text-index table))
    (when found
      (let ((start (aref (int-text-table-text-start table) ti))
            (count (aref (int-text-table-text-count table) ti)))
        (loop for k from start below (+ start count)
              for row = (aref (int-text-table-text-major table) k)
              collect (list (aref (int-text-table-ids table) row)
                            (aref (int-text-table-seqs table) row)
                            (aref (int-text-table-ords table) row)))))))
;;; ---- conjugation trio (compact integer columns + range indexes) ----

;;; ---- shared range-index helpers (flat style: minimal nesting) ----

(defun int-sort-positions (n key-fn)
  "Vector MAJOR where MAJOR[pos] = row index, rows sorted by KEY-FN ascending.
   KEY-FN must return fixnums."
  (let ((order (make-array n :element-type 'fixnum)))
    (loop for i from 0 below n do (setf (aref order i) i))
    (sort order '< :key key-fn)))

(defun int-group-ranges (major n group-fn)
  "Hash GROUP -> (start . count) over MAJOR positions using GROUP-FN on rows.
   Assumes MAJOR is sorted by group (ties broken stably enough for ranges)."
  (let ((ht (make-hash-table :test 'eql)))
    (loop for pos from 0 below n
          for row = (aref major pos)
          for g = (funcall group-fn row)
          for cell = (gethash g ht)
          do (if cell
                 (incf (cdr cell))
                 (setf (gethash g ht) (cons pos 1))))
    ht))

(defun int-u32-col (fill-vec n)
  "Freeze adjustable FILL-VEC (active elements) to (unsigned-byte 32) vector."
  (let ((out (make-array n :element-type '(unsigned-byte 32))))
    (replace out fill-vec)))

(defun int-load-conjugation (&key (chunk 200000) conn)
  "Load conjugation (id seq from via). via :null becomes -1. ORDER BY id."
  (sb-ext:gc :full t)
  (let ((before (sb-kernel:dynamic-usage)))
    (let ((conn (or conn (default-conn)))
          (ids (make-array 2400000 :element-type '(unsigned-byte 32)
                           :fill-pointer 0 :adjustable t))
          (seqs (make-array 2400000 :element-type '(unsigned-byte 32)
                            :fill-pointer 0 :adjustable t))
          (froms (make-array 2400000 :element-type '(unsigned-byte 32)
                             :fill-pointer 0 :adjustable t))
          (vias (make-array 2400000 :element-type '(signed-byte 32)
                            :fill-pointer 0 :adjustable t)))
      (postmodern:with-connection conn
        (loop with last-id = -1
              for rows = (postmodern:query
                          (format nil "SELECT id, seq, \"from\", via FROM conjugation WHERE id > ~a ORDER BY id LIMIT ~a"
                                  last-id chunk)
                          :lists)
              while rows
              do (dolist (pl rows)
                   (destructuring-bind (id seq from via) pl
                     (vector-push-extend id ids)
                     (vector-push-extend seq seqs)
                     (vector-push-extend from froms)
                     (vector-push-extend (if (eql via :null) -1 via) vias)))
                 (setf last-id (caar (last rows)))))
      (let* ((n (fill-pointer ids))
             (ids-v (int-u32-col ids n))
             (seqs-v (int-u32-col seqs n))
             (froms-v (int-u32-col froms n))
             (vias-v (make-array n :element-type '(signed-byte 32))))
        (replace vias-v vias)
        (let ((major (int-sort-positions
                      n (lambda (i) (+ (ash (aref seqs-v i) 32)
                                       (aref ids-v i))))))
          ;; Second permutation by "from" so a source word can find its
          ;; conjugated rows without a scan (get-kana-forms* needs this).
          (let ((major-from (int-sort-positions
                             n (lambda (i) (+ (ash (aref froms-v i) 32)
                                              (aref ids-v i))))))
            (sb-ext:gc :full t)
            (let ((after (sb-kernel:dynamic-usage)))
              (values (list :n n :ids ids-v :seqs seqs-v :froms froms-v
                            :vias vias-v :major major
                            :by-seq (int-group-ranges
                                     major n (lambda (r) (aref seqs-v r)))
                            :major-from major-from
                            :by-from (int-group-ranges
                                      major-from n (lambda (r) (aref froms-v r))))
                      (- after before)))))))))

(defun int-conj-row-count (table)
  (getf table :n))

(defun int-has-conj-p (table seq)
  (nth-value 1 (gethash seq (getf table :by-seq))))

(defun int-conj-rows-by-seq (table seq)
  "List of (id seq from via-or-nil) for SEQ in id order."
  (let ((range (gethash seq (getf table :by-seq))))
    (when range
      (loop for k from (car range) below (+ (car range) (cdr range))
            for i = (aref (getf table :major) k)
            collect (list (aref (getf table :ids) i)
                          (aref (getf table :seqs) i)
                          (aref (getf table :froms) i)
                          (let ((v (aref (getf table :vias) i)))
                            (if (= v -1) nil v)))))))

(defun int-conj-seqs-by-from (table from)
  "List of conjugation SEQ values whose \"from\" is FROM, in id order."
  (let ((range (gethash from (getf table :by-from))))
    (when range
      (loop for k from (car range) below (+ (car range) (cdr range))
            for i = (aref (getf table :major-from) k)
            collect (aref (getf table :seqs) i)))))

(defun int-load-conj-prop (&key (chunk 200000) conn)
  "Load conj_prop (id conj-id type pos neg fml). ORDER BY id."
  (sb-ext:gc :full t)
  (let ((before (sb-kernel:dynamic-usage)))
    (let ((conn (or conn (default-conn)))
          (ids (make-array 2400000 :element-type '(unsigned-byte 32)
                           :fill-pointer 0 :adjustable t))
          (conj-ids (make-array 2400000 :element-type '(unsigned-byte 32)
                                :fill-pointer 0 :adjustable t))
          (type-ids (make-array 2400000 :element-type '(unsigned-byte 32)
                                :fill-pointer 0 :adjustable t))
          (pos-ids (make-array 2400000 :element-type '(unsigned-byte 32)
                               :fill-pointer 0 :adjustable t))
          (flags (make-array 2400000 :element-type '(unsigned-byte 8)
                             :fill-pointer 0 :adjustable t))
          (types (make-array 256 :fill-pointer 0 :adjustable t))
          (type-index (make-hash-table :test 'equal))
          (poss (make-array 1024 :fill-pointer 0 :adjustable t))
          (pos-index (make-hash-table :test 'equal)))
      (labels ((pool (s vec idx)
                 (or (gethash s idx)
                     (let ((i (fill-pointer vec)))
                       (vector-push-extend s vec)
                       (setf (gethash s idx) i)
                       i))))
        (postmodern:with-connection conn
          (loop with last-id = -1
                for rows = (postmodern:query
                            (format nil "SELECT id, conj_id, conj_type, pos, neg, fml FROM conj_prop WHERE id > ~a ORDER BY id LIMIT ~a"
                                    last-id chunk)
                            :lists)
                while rows
                do (dolist (pl rows)
                     (destructuring-bind (id conj-id conj-type pos neg fml) pl
                       (vector-push-extend id ids)
                       (vector-push-extend conj-id conj-ids)
                       (vector-push-extend (pool conj-type types type-index) type-ids)
                       (vector-push-extend (pool pos poss pos-index) pos-ids)
                       ;; neg/fml are three-state in the DB: t, false, and
                       ;; NULL. Collapsing "non-nil" into true turned the
                       ;; 85k NULL neg and 102k NULL fml rows into "neg":
                       ;; true, which the database path omits, and that alone
                       ;; made 190 of 364 golden lines differ between the two
                       ;; paths. Two bits per flag carry all three states.
                       (vector-push-extend (logior (if (eq neg t) 1 0)
                                                   (if (eq neg :null) 2 0)
                                                   (if (eq fml t) 4 0)
                                                   (if (eq fml :null) 8 0))
                                           flags)))
                   (setf last-id (caar (last rows))))))
      (let* ((n (fill-pointer ids))
             (ids-v (int-u32-col ids n))
             (conj-v (int-u32-col conj-ids n))
             (type-v (int-u32-col type-ids n))
             (pos-v (int-u32-col pos-ids n))
             (flags-v (make-array n :element-type '(unsigned-byte 8))))
        (replace flags-v flags)
        (let ((major (int-sort-positions
                      n (lambda (i) (+ (ash (aref conj-v i) 32)
                                       (aref ids-v i))))))
          (sb-ext:gc :full t)
          (let ((after (sb-kernel:dynamic-usage)))
            (values (list :n n :ids ids-v :conj-ids conj-v
                          :types (coerce types 'simple-vector)
                          :type-ids type-v
                          :poss (coerce poss 'simple-vector)
                          :pos-ids pos-v :flags flags-v
                          :major major
                          :by-conj (int-group-ranges
                                    major n (lambda (r) (aref conj-v r))))
                    (- after before))))))))

(defun int-conj-prop-row-count (table)
  (getf table :n))

(defun int-conj-props-by-id (table conj-id)
  "List of (id conj-id type pos neg fml) for CONJ-ID in id order.
   CONJ-ID is echoed so callers can destructure all six slots."
  (let ((range (gethash conj-id (getf table :by-conj))))
    (when range
      (loop for k from (car range) below (+ (car range) (cdr range))
            for i = (aref (getf table :major) k)
            for fl = (aref (getf table :flags) i)
            collect (list (aref (getf table :ids) i)
                          conj-id
                          (aref (getf table :types) (aref (getf table :type-ids) i))
                          (aref (getf table :poss) (aref (getf table :pos-ids) i))
                          ;; t / false / NULL, matching what the DB loader
                          ;; hands the analyzer.
                          (if (logtest 1 fl) t (if (logtest 2 fl) :null nil))
                          (if (logtest 4 fl) t (if (logtest 8 fl) :null nil)))))))

(defun pool-encode (vec)
  "Encode VEC (a vector of strings) as (values BLOB OFFSETS): one concatenated
   string plus N+1 character offsets. A pool then decodes as ONE big string and
   ONE u32 vector, instead of allocating a Lisp string per entry. That is what
   made conj_source_reading cost 2.79s of the 6.4s snapshot decode: 8.4M rows
   over two pools, so millions of small string allocations."
  (let* ((n (length vec))
         (off (make-array (1+ n) :element-type '(unsigned-byte 32)))
         (total (loop for i from 0 below n
                      sum (length (aref vec i)) of-type fixnum))
         (blob (make-string total))
         (pos 0))
    (loop for i from 0 below n
          for str = (aref vec i)
          do (setf (aref off i) pos)
             (replace blob str :start1 pos)
             (incf pos (length str)))
    (setf (aref off n) pos)
    (values blob off)))

(defun pool-ref (blob off i)
  "The I-th string of a pool encoded by POOL-ENCODE."
  (subseq blob (aref off i) (aref off (1+ i))))

(defun int-load-csr (&key (chunk 200000) conn)
  "Load conj_source_reading (id conj-id text source-text). ORDER BY id."
  (sb-ext:gc :full t)
  (let ((before (sb-kernel:dynamic-usage)))
    (let ((conn (or conn (default-conn)))
          (ids (make-array 8400000 :element-type '(unsigned-byte 32)
                           :fill-pointer 0 :adjustable t))
          (conj-ids (make-array 8400000 :element-type '(unsigned-byte 32)
                                :fill-pointer 0 :adjustable t))
          (text-ids (make-array 8400000 :element-type '(unsigned-byte 32)
                                :fill-pointer 0 :adjustable t))
          (src-ids (make-array 8400000 :element-type '(unsigned-byte 32)
                               :fill-pointer 0 :adjustable t))
          (texts (make-array 1024 :fill-pointer 0 :adjustable t))
          (text-index (make-hash-table :test 'equal))
          (srcs (make-array 1024 :fill-pointer 0 :adjustable t))
          (src-index (make-hash-table :test 'equal)))
      (labels ((pool (s vec idx)
                 (or (gethash s idx)
                     (let ((i (fill-pointer vec)))
                       (vector-push-extend s vec)
                       (setf (gethash s idx) i)
                       i))))
        (postmodern:with-connection conn
          (loop with last-id = -1
                for rows = (postmodern:query
                            (format nil "SELECT id, conj_id, text, source_text FROM conj_source_reading WHERE id > ~a ORDER BY id LIMIT ~a"
                                    last-id chunk)
                            :lists)
                while rows
                do (dolist (pl rows)
                     (destructuring-bind (id conj-id text source-text) pl
                       (vector-push-extend id ids)
                       (vector-push-extend conj-id conj-ids)
                       (vector-push-extend (pool text texts text-index) text-ids)
                       (vector-push-extend (pool source-text srcs src-index) src-ids)))
                   (setf last-id (caar (last rows))))))
      (let* ((n (fill-pointer ids))
             (ids-v (int-u32-col ids n))
             (conj-v (int-u32-col conj-ids n))
             (text-v (int-u32-col text-ids n))
             (src-v (int-u32-col src-ids n)))
        (let ((major (int-sort-positions
                      n (lambda (i) (+ (ash (aref conj-v i) 32)
                                       (aref ids-v i))))))
          (sb-ext:gc :full t)
          (multiple-value-bind (texts-blob text-off) (pool-encode texts)
            (multiple-value-bind (srcs-blob src-off) (pool-encode srcs)
              (let ((after (sb-kernel:dynamic-usage)))
                (values (list :n n :ids ids-v :conj-ids conj-v
                              :texts texts-blob :text-offsets text-off
                              :srcs srcs-blob :src-offsets src-off
                              :text-ids text-v :src-ids src-v
                              :major major
                              :by-conj (int-group-ranges
                                        major n (lambda (r) (aref conj-v r))))
                        (- after before))))))))))

(defun int-csr-row-count (table)
  (getf table :n))

(defun int-csr-by-id (table conj-id)
  "List of (text source-text) for CONJ-ID in id order. Strings are materialised
   here from the encoded pools, so the millions of pool strings that used to be
   built at load time are only built for the rows actually asked for."
  (let ((range (gethash conj-id (getf table :by-conj)))
        (t-blob (getf table :texts))
        (t-off (getf table :text-offsets))
        (s-blob (getf table :srcs))
        (s-off (getf table :src-offsets)))
    (when range
      (loop for k from (car range) below (+ (car range) (cdr range))
            for i = (aref (getf table :major) k)
            collect (list (pool-ref t-blob t-off (aref (getf table :text-ids) i))
                          (pool-ref s-blob s-off (aref (getf table :src-ids) i)))))))
