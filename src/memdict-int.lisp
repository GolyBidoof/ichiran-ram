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
           #:int-text-find-by-seq
           #:make-int-text-table))

(in-package #:ichiran/memdict-int)

(defstruct int-text-table
  (n 0 :type fixnum)
  (texts #() :type simple-vector)
  (text-index (make-hash-table :test 'equal))
  (ids #() :type (simple-array (unsigned-byte 32) (*)))
  (seqs #() :type (simple-array (unsigned-byte 32) (*)))
  (ords #() :type (simple-array (unsigned-byte 32) (*)))
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
          (loop with offset = 0
                for rows = (postmodern:query
                            (format nil "SELECT id, seq, text, ord, common, common_tags, conjugate_p, nokanji, ~a FROM ~a ORDER BY id LIMIT ~a OFFSET ~a"
                                    best-col table chunk offset)
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
                   (incf offset chunk))))
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
               (seq-count (make-array (1+ max-seq) :element-type '(unsigned-byte 32) :initial-element 0)))
          ;; Text-major order: sort row indices by (text-idx, id).
          ;; Key packs into one fixnum (text-idx < 2^22, id < 2^32).
          (let ((order (make-array n :element-type 'fixnum)))
            (loop for i from 0 below n do (setf (aref order i) i))
            (sort order '< :key (lambda (i) (+ (ash (aref text-ids i) 32)
                                               (aref ids i))))
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
                                               (aref ids i))))
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
                     :ords (funcall freeze-u32 ords) :text-ids (funcall freeze-u32 text-ids)
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
