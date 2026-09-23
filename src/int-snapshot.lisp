;;;; src/int-snapshot.lisp — Tier 3.1: on-disk columnar snapshot of the
;;;; integer dictionary layer.
;;;;
;;;; Why: loading the integer layer from PostgreSQL costs ~82s on the full
;;;; dictionary, and that cost is paid by every process on a host that cannot
;;;; bake a core image (dumping the 8.1GB dictionary needs a 32GB+ machine).
;;;; The integer tables are already flat typed columns plus interned string
;;;; pools, so they can be written as raw bytes and read back with bulk
;;;; syscalls instead of SQL round trips.
;;;;
;;;; What is stored: every typed column as raw element bytes, every string
;;;; pool as length-prefixed UTF-8. What is NOT stored: the hash indexes
;;;; (text-index, by-seq, by-from, by-conj). They are pure derivations of the
;;;; columns, so they are rebuilt on load — cheaper and smaller than
;;;; serialising hash tables, and it keeps the file canonical.
;;;;
;;;; This is deliberately a flat-file snapshot rather than an mmap'able
;;;; layout: mapping in place additionally needs offset-based string pools
;;;; (Lisp strings cannot be mapped) and would change every accessor. A
;;;; sequential bulk read already removes the SQL round trips, which is the
;;;; cost that matters.
;;;;
;;;; Format is little-endian and versioned; the header records endianness so
;;;; a foreign-endian snapshot is rejected instead of silently misread.

(defpackage #:ichiran/int-snapshot
  (:use #:cl)
  (:export #:int-snapshot-save #:int-snapshot-load #:int-snapshot-file-p))

(in-package #:ichiran/int-snapshot)

(eval-when (:compile-toplevel :load-toplevel :execute)
  (require :sb-posix))

(defparameter *magic* "ICHSNAP1"
  "8-byte file magic.")

(defparameter *version* 2)

(defparameter *elem-types*
  '((unsigned-byte 8) (unsigned-byte 32) (signed-byte 32) fixnum)
  "Element type codes stored in the file. Fixnum is a 64-bit word on SBCL.")

(defconstant +nil-string+ #xFFFFFFFF
  "Pool entry marker for NIL (pools are strings, but be defensive).")

;;; ---- field layout per table -------------------------------------------

(defparameter *text-table-slots*
  '(n texts ids seqs ords ranks text-ids commons flags tags tag-ids kanjis kanji-ids
    kanas kana-ids text-major text-start text-count seq-major seq-start seq-count
    max-seq))

(defparameter *plist-fields*
  '(("entry" :n :seqs :contents :content-ids :flags :nkanji :nkana :direct :max-seq)
    ("conjugation" :n :ids :seqs :froms :vias :major :major-from)
    ("conj_prop" :n :ids :conj-ids :types :type-ids :poss :pos-ids :flags :major)
    ("conj_source_reading" :n :ids :conj-ids :texts :text-ids :srcs :src-ids :major)))

(defun text-table-name-p (name)
  (member name '("kana_text" "kanji_text") :test #'equal))

(defun plist-fields (name)
  "The field keyword list for a plist-shaped table, or NIL."
  (cdr (assoc name *plist-fields* :test #'equal)))

;;; ---- buffered raw i/o -------------------------------------------------
;;; The pools hold millions of short strings, so unbuffered per-string
;;; write()/read() calls dominate: 2 syscalls per pool entry meant tens of
;;; millions of syscalls. A userspace buffer turns those into memcpy, and
;;; large typed columns bypass the buffer with one syscall each.

(defparameter *bufsize* (* 8 1024 1024))

(defstruct (sink (:constructor make-sink (fd)))
  (fd nil)
  (buf (make-array *bufsize* :element-type '(unsigned-byte 8)))
  (pos 0))

(defun sink-flush (s)
  (let ((p (sink-pos s)))
    (when (plusp p)
      (sb-sys:with-pinned-objects ((sink-buf s))
        (write-all (sink-fd s) (sb-sys:vector-sap (sink-buf s)) p))
      (setf (sink-pos s) 0))))

(defun sink-u8 (s v)
  (let ((buf (sink-buf s)))
    (when (>= (sink-pos s) (length buf)) (sink-flush s))
    (setf (aref buf (sink-pos s)) (logand v #xFF))
    (incf (sink-pos s))))

(defun sink-u32 (s v)
  (let ((buf (sink-buf s)))
    (when (> (+ (sink-pos s) 4) (length buf)) (sink-flush s))
    (dotimes (i 4)
      (setf (aref buf (+ (sink-pos s) i)) (ldb (byte 8 (* 8 i)) v)))
    (incf (sink-pos s) 4)))

(defun sink-u64 (s v)
  (let ((buf (sink-buf s)))
    (when (> (+ (sink-pos s) 8) (length buf)) (sink-flush s))
    (dotimes (i 8)
      (setf (aref buf (+ (sink-pos s) i)) (ldb (byte 8 (* 8 i)) v)))
    (incf (sink-pos s) 8)))

(defun sink-octets (s octets)
  "Append a small octet vector via the buffer."
  (let ((n (length octets))
        (buf (sink-buf s)))
    (when (> (+ (sink-pos s) n) (length buf)) (sink-flush s))
    (replace buf octets :start1 (sink-pos s))
    (incf (sink-pos s) n)))

(defun sink-blob (s sap len)
  "Write a large region directly, after flushing the buffer."
  (when (plusp len)
    (sink-flush s)
    (write-all (sink-fd s) sap len)))

(defstruct (source (:constructor make-source (fd)))
  (fd nil)
  (buf (make-array *bufsize* :element-type '(unsigned-byte 8)))
  (pos 0)
  (end 0))

(defun source-fill (s)
  "Refill the buffer; returns the number of bytes available."
  (let ((buf (source-buf s)))
    (sb-sys:with-pinned-objects (buf)
      (let ((sap (sb-sys:vector-sap buf))
            (off 0)
            (want (length buf)))
        (loop while (< off want)
              for n = (sb-posix:read (source-fd s) (sb-sys:sap+ sap off) (- want off))
              do (if (and n (plusp n)) (incf off n) (return)))
        (setf (source-pos s) 0 (source-end s) off)
        off))))

(defun source-u8 (s)
  (when (>= (source-pos s) (source-end s))
    (when (zerop (source-fill s)) (error "int-snapshot: unexpected end of file")))
  (prog1 (aref (source-buf s) (source-pos s))
    (incf (source-pos s))))

(defun source-u32 (s)
  (let ((v 0))
    (dotimes (i 4) (setf v (logior v (ash (source-u8 s) (* 8 i)))))
    v))

(defun source-u64 (s)
  (let ((v 0))
    (dotimes (i 8) (setf v (logior v (ash (source-u8 s) (* 8 i)))))
    v))

(defun source-octets (s n)
  "Read exactly N octets (buffered)."
  (let ((out (make-array n :element-type '(unsigned-byte 8)))
        (got 0)
        (buf (source-buf s)))
    (loop while (< got n)
          do (when (>= (source-pos s) (source-end s))
               (when (zerop (source-fill s))
                 (error "int-snapshot: unexpected end of file")))
             (let* ((avail (- (source-end s) (source-pos s)))
                    (take (min avail (- n got))))
               (replace out buf :start1 got :start2 (source-pos s) :end2 (+ (source-pos s) take))
               (incf (source-pos s) take)
               (incf got take)))
    out))

(defun source-blob (s sap len)
  "Read a large region directly: consume the buffer, then read the rest."
  (let ((avail (- (source-end s) (source-pos s))))
    (let ((head (min avail len)))
      (when (plusp head)
        ;; vector -> SAP: SBCL has no public ub8 memcpy, and the destination
        ;; here is a pinned typed vector's raw storage.
        (sb-sys:with-pinned-objects ((source-buf s))
          (sb-kernel:copy-ub8-to-system-area (source-buf s) (source-pos s) sap 0 head))
        (incf (source-pos s) head))
      (let ((rest (- len head)))
        (when (plusp rest)
          (read-all (source-fd s) (sb-sys:sap+ sap head) rest))))
    len))

(defun write-all (fd sap len)
  (loop with off = 0
        while (< off len)
        for n = (sb-posix:write fd (sb-sys:sap+ sap off) (- len off))
        do (if (and n (plusp n))
               (incf off n)
               (error "int-snapshot: short write (~a of ~a)" off len))))

(defun read-all (fd sap len)
  (loop with off = 0
        while (< off len)
        for n = (sb-posix:read fd (sb-sys:sap+ sap off) (- len off))
        do (if (and n (plusp n))
               (incf off n)
               (error "int-snapshot: short read (~a of ~a)" off len))))

(defun write-string* (s str)
  (if (null str)
      (sink-u32 s +nil-string+)
      ;; (string ...) not the object directly: pools can hold fixed-size
      ;; character vectors (not stringp), and string-to-octets requires a
      ;; genuine string.
      (let ((octets (sb-ext:string-to-octets (string str) :external-format :utf-8)))
        (sink-u32 s (length octets))
        (sink-octets s octets))))

(defun read-string* (s)
  (let ((n (source-u32 s)))
    (if (= n +nil-string+)
        nil
        (sb-ext:octets-to-string (source-octets s n) :external-format :utf-8))))

(defun elem-code (type)
  (or (position type *elem-types* :test #'equal)
      (error "int-snapshot: unsupported element type ~a" type)))

(defun elem-size (type)
  (cond ((equal type '(unsigned-byte 8)) 1)
        ((member type '((unsigned-byte 32) (signed-byte 32)) :test #'equal) 4)
        ((equal type 'fixnum) 8)
        (t (error "int-snapshot: no byte size for ~a" type))))

(defun write-typed-vector (s vec)
  (let* ((type (array-element-type vec))
         (code (elem-code type))
         (es (elem-size type))
         (n (length vec)))
    (sink-u8 s code)
    (sink-u64 s n)
    (when (plusp n)
      (sb-sys:with-pinned-objects (vec)
        (sink-blob s (sb-sys:vector-sap vec) (* n es))))))

(defun read-typed-vector (s)
  (let* ((code (source-u8 s))
         (type (nth code *elem-types*))
         (es (elem-size type))
         (n (source-u64 s))
         (vec (make-array n :element-type type)))
    (when (plusp n)
      (sb-sys:with-pinned-objects (vec)
        (source-blob s (sb-sys:vector-sap vec) (* n es))))
    vec))

;;; ---- per-value dispatch ----------------------------------------------

(defun char-vector-p (x)
  "T for a character array that is not a STRING (fixed-size or displaced)."
  (and (arrayp x) (not (stringp x))
       (subtypep (array-element-type x) 'character)))

(defun write-value (s value)
  (cond ((hash-table-p value) (sink-u8 s 3))            ; derived: rebuilt on load
        ((and (vectorp value) (not (stringp value))
              (not (array-element-type-is-t value)))
         (sink-u8 s 1) (write-typed-vector s value))
        ((and (vectorp value) (not (stringp value)))
         ;; Element type T: either a string pool or a plain integer vector
         ;; (entry's per-slot arrays). Decide by inspecting an element —
         ;; guessing from the container type alone is wrong both ways.
         (let ((first (if (plusp (length value)) (aref value 0) nil)))
           (cond ((or (null first) (stringp first) (char-vector-p first))
                  (sink-u8 s 2)
                  (sink-u64 s (length value))
                  (dotimes (i (length value)) (write-string* s (aref value i))))
                 ((integerp first)
                  (sink-u8 s 4)
                  (sink-u64 s (length value))
                  (dotimes (i (length value)) (sink-u64 s (aref value i))))
                 (t (error "int-snapshot: cannot store vector of ~s" (type-of first))))))
        ((integerp value) (sink-u8 s 0) (sink-u64 s value))
        (t (error "int-snapshot: cannot store ~s" value))))

(defun array-element-type-is-t (vec)
  (equal (array-element-type vec) t))

(defun read-value (s)
  (let ((kind (source-u8 s)))
    (case kind
      (0 (source-u64 s))
      (1 (read-typed-vector s))
      (2 (let ((n (source-u64 s)))
           (let ((v (make-array n)))
             (dotimes (i n) (setf (aref v i) (read-string* s)))
             v)))
      (3 nil)
      (4 (let ((n (source-u64 s)))
           (let ((v (make-array n)))
             (dotimes (i n) (setf (aref v i) (source-u64 s)))
             v)))
      (t (error "int-snapshot: bad value kind ~a" kind)))))

;;; ---- derived index rebuilds ------------------------------------------

(defun group-ranges (major n group-fn &optional size-hint)
  "Hash GROUP -> (start . count) over MAJOR positions. Local copy of
   ichiran/memdict-int's helper so this file stays standalone. SIZE-HINT
   pre-sizes the table: it takes millions of entries, and growing from the
   default size rehashes repeatedly."
  (let ((ht (make-hash-table :test 'eql :size (or size-hint 1000))))
    (loop for pos from 0 below n
          for row = (aref major pos)
          for g = (funcall group-fn row)
          for cell = (gethash g ht)
          do (if cell
                 (setf (cdr cell) (1+ (cdr cell)))
                 (setf (gethash g ht) (cons pos 1))))
    ht))

(defun rebuild-text-index (texts)
  "TEXT -> pool index (first interning wins, which is what the loader does).
   Pre-sized: the text pools run to millions of entries."
  (let ((ht (make-hash-table :test 'equal :size (max 16 (length texts)))))
    (loop for i from 0 below (length texts)
          do (setf (gethash (aref texts i) ht) i))
    ht))

;;; ---- save / load ------------------------------------------------------

(defun table-fields (name object)
  "Field name list for NAME, checking OBJECT is the expected shape."
  (cond ((text-table-name-p name) *text-table-slots*)
        ((plist-fields name) (plist-fields name))
        (t (error "int-snapshot: unknown table ~a" name))))

(defun field-value (name object field)
  (if (text-table-name-p name)
      ;; defstruct accessor is INT-TEXT-TABLE-<SLOT>, not the bare slot name
      (let ((sym (find-symbol (format nil "INT-TEXT-TABLE-~a" (symbol-name field))
                              :ichiran/memdict-int)))
        (unless (and sym (fboundp sym))
          (error "int-snapshot: no accessor for slot ~a" field))
        (funcall (symbol-function sym) object))
      (getf object field)))

(defun int-snapshot-save (path tables)
  "Write TABLES (an alist of (name . object)) to PATH. Returns the byte size."
  (let ((fd (sb-posix:open path (logior sb-posix:o-wronly sb-posix:o-creat
                                         sb-posix:o-trunc)
                           #o644)))
    (unwind-protect
         (let ((snk (make-sink fd)))
           (sink-octets snk (sb-ext:string-to-octets *magic* :external-format :ascii))
           (sink-u8 snk *version*)
           (sink-u8 snk 1)                     ; endianness marker (1 = LE)
           (sink-u32 snk (length tables))
           (dolist (entry tables)
             (let* ((name (car entry))
                    (object (cdr entry))
                    (fields (table-fields name object)))
               (write-string* snk name)
               (sink-u32 snk (length fields))
               (dolist (field fields)
                 (write-string* snk (string-downcase (symbol-name field)))
                 (write-value snk (field-value name object field)))))
           (sink-flush snk)
           (sb-posix:lseek fd 0 sb-posix:seek-end))
      (sb-posix:close fd))))

(defun int-snapshot-file-p (path)
  "T when PATH starts with the snapshot magic, without reading it all."
  (when (probe-file path)
    (handler-case
        (let ((fd (sb-posix:open path sb-posix:o-rdonly)))
          (unwind-protect
               (let ((src (make-source fd)))
                 (equal (sb-ext:octets-to-string (source-octets src (length *magic*))
                                                 :external-format :ascii)
                        *magic*))
            (sb-posix:close fd)))
      (error () nil))))

(defun int-snapshot-load (path)
  "Read a snapshot and return an alist of (name . object) in file order."
  (let ((fd (sb-posix:open path sb-posix:o-rdonly)))
    (unwind-protect
         (let ((src (make-source fd)))
           (unless (equal (sb-ext:octets-to-string (source-octets src (length *magic*))
                                                   :external-format :ascii)
                          *magic*)
             (error "int-snapshot: ~a is not a snapshot" path))
           (let ((version (source-u8 src))
                 (endian (source-u8 src)))
             (unless (= version *version*)
               (error "int-snapshot: version ~a, expected ~a" version *version*))
             (unless (= endian 1)
               (error "int-snapshot: foreign-endian snapshot")))
           (let* ((ntables (source-u32 src))
                  (out nil))
             (dotimes (i ntables)
               (let* ((name (read-string* src))
                      (nfields (source-u32 src))
                      (fields nil)
                      (values nil))
                 (dotimes (j nfields)
                   (push (read-string* src) fields)
                   (push (read-value src) values))
                 (setf fields (nreverse fields) values (nreverse values))
                 (push (cons name (reconstruct name fields values)) out)))
             (nreverse out)))
      (sb-posix:close fd))))

(defun reconstruct (name fields values)
  "Rebuild the table object for NAME from its stored FIELDS/VALUES,
   recomputing the derived hash indexes."
  (if (text-table-name-p name)
      (let ((plist nil))
        (loop for f in fields for v in values
              do (setf (getf plist (intern (string-upcase f) :keyword)) v))
        ;; n is a slot; max-seq too. Rebuild text-index from the pool.
        (let ((texts (getf plist :texts)))
          (setf (getf plist :text-index) (rebuild-text-index texts)))
        (apply (fdefinition (find-symbol "MAKE-INT-TEXT-TABLE" :ichiran/memdict-int))
               plist))
      (let ((plist nil))
        (loop for f in fields for v in values
              do (setf (getf plist (intern (string-upcase f) :keyword)) v))
        (let ((n (getf plist :n))
              (major (getf plist :major)))
          (cond ((equal name "conjugation")
                 ;; by-seq groups MAJOR (sorted by seq); by-from must group
                 ;; MAJOR-FROM (sorted by "from"). Grouping by "from" over the
                 ;; seq-ordered permutation gives non-contiguous, wrong ranges.
                 (setf (getf plist :by-seq)
                       (group-ranges major n (lambda (r) (aref (getf plist :seqs) r)) n)
                       (getf plist :by-from)
                       (group-ranges (getf plist :major-from) n
                                     (lambda (r) (aref (getf plist :froms) r)) n)))
                ((member name '("conj_prop" "conj_source_reading") :test #'equal)
                 (setf (getf plist :by-conj)
                       (group-ranges major n
                                     (lambda (r) (aref (getf plist :conj-ids) r))
                                     n)))))
        plist)))
