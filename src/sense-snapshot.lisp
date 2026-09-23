;;;; src/sense-snapshot.lisp — persist the sense layer so the RAM path needs no
;;;; PostgreSQL at all.
;;;;
;;;; Why: the integer layer already comes from a snapshot, but sense, gloss and
;;;; sense_prop were still read from the database on every start, which cost
;;;; about 0.9s and, more importantly, meant the "in-RAM" path could not run
;;;; without a live server. With this, a snapshot plus the analyzer is a
;;;; complete, self-contained dictionary.
;;;;
;;;; The tables are flattened to columns and stored with the same snapshot
;;;; writer the integer layer uses, so string columns ride along as encoded
;;;; blobs rather than as one Lisp string per row.

(in-package #:ichiran/memdict-compact)

(defun %collect-rows (table id-fn)
  "Every struct in the per-key lists of TABLE, sorted by id. The lists are
   already ascending-id because memdict-normalize-order ran at load time, so
   this only has to interleave the buckets."
  (let ((rows nil))
    (maphash (lambda (key value)
               (declare (ignore key))
               (dolist (row value) (push row rows)))
             table)
    (sort rows #'< :key id-fn)))

(defun %pool-column (strings)
  "Deduplicated string pool for STRINGS as (values BLOB OFFSETS INDEXES)."
  (let ((index (make-hash-table :test 'equal))
        (pool (make-array 64 :adjustable t :fill-pointer 0))
        (ids (make-array (length strings) :element-type '(unsigned-byte 32))))
    (loop for s in strings
          for i from 0
          for p = (or (gethash s index)
                      (let ((j (fill-pointer pool)))
                        (vector-push-extend s pool)
                        (setf (gethash s index) j)
                        j))
          do (setf (aref ids i) p))
    (multiple-value-bind (blob offsets)
        (ichiran/memdict-int::pool-encode pool)
      (values blob offsets ids))))

(defun %u32-column (rows fn)
  (let ((out (make-array (length rows) :element-type '(unsigned-byte 32))))
    (loop for row in rows for i from 0
          do (setf (aref out i) (funcall fn row)))
    out))

(defun sense-layer-tables ()
  "The sense layer as snapshot objects: an alist of (name . column plist)."
  (let* ((senses (%collect-rows *sense-by-seq* #'compact-sense-id))
         (glosses (%collect-rows *gloss-by-sense* #'compact-gloss-id))
         (props (%collect-rows *prop-by-sense* #'compact-sense-prop-id)))
    (multiple-value-bind (gloss-blob gloss-off gloss-ids)
        (%pool-column (mapcar #'compact-gloss-text glosses))
      (multiple-value-bind (tag-blob tag-off tag-ids)
          (%pool-column (mapcar #'compact-sense-prop-tag props))
        (multiple-value-bind (prop-blob prop-off prop-ids)
            (%pool-column (mapcar #'compact-sense-prop-text props))
          (list
           (cons "sense"
                 (list :n (length senses)
                       :ids (%u32-column senses #'compact-sense-id)
                       :seqs (%u32-column senses #'compact-sense-seq)
                       :ords (%u32-column senses #'compact-sense-ord)))
           (cons "gloss"
                 (list :n (length glosses)
                       :ids (%u32-column glosses #'compact-gloss-id)
                       :sense-ids (%u32-column glosses #'compact-gloss-sense-id)
                       :texts gloss-blob :text-offsets gloss-off
                       :text-ids gloss-ids
                       :ords (%u32-column glosses #'compact-gloss-ord)))
           (cons "sense_prop"
                 (list :n (length props)
                       :ids (%u32-column props #'compact-sense-prop-id)
                       :sense-ids (%u32-column props #'compact-sense-prop-sense-id)
                       :tags tag-blob :tag-offsets tag-off
                       :tag-ids tag-ids
                       :texts prop-blob :text-offsets prop-off
                       :text-ids prop-ids
                       :ords (%u32-column props #'compact-sense-prop-ord)
                       :seqs (%u32-column props #'compact-sense-prop-seq)))))))))

(defun sense-layer-install (tables)
  "Replace the sense layer with the contents of TABLES (from a snapshot)."
  (clrhash *sense-by-seq*)
  (clrhash *gloss-by-sense*)
  (clrhash *prop-by-sense*)
  (setf *sense-ids-ord-0* nil)
  (let ((sense (cdr (assoc "sense" tables :test #'equal))))
    (when sense
      (loop with ids = (getf sense :ids)
            with seqs = (getf sense :seqs)
            with ords = (getf sense :ords)
            for i from 0 below (getf sense :n)
            for row = (make-compact-sense :id (aref ids i) :seq (aref seqs i)
                                          :ord (aref ords i))
            do (push row (gethash (compact-sense-seq row) *sense-by-seq*)))))
  (let ((gloss (cdr (assoc "gloss" tables :test #'equal))))
    (when gloss
      (loop with ids = (getf gloss :ids)
            with sense-ids = (getf gloss :sense-ids)
            with ords = (getf gloss :ords)
            with text-ids = (getf gloss :text-ids)
            with blob = (getf gloss :texts)
            with offsets = (getf gloss :text-offsets)
            for i from 0 below (getf gloss :n)
            for row = (make-compact-gloss :id (aref ids i)
                                          :sense-id (aref sense-ids i)
                                          :text (intern-text
                                                 (ichiran/memdict-int::pool-ref
                                                  blob offsets (aref text-ids i)))
                                          :ord (aref ords i))
            do (push row (gethash (compact-gloss-sense-id row) *gloss-by-sense*)))))
  (let ((props (cdr (assoc "sense_prop" tables :test #'equal))))
    (when props
      (loop with ids = (getf props :ids)
            with sense-ids = (getf props :sense-ids)
            with ords = (getf props :ords)
            with seqs = (getf props :seqs)
            with tag-ids = (getf props :tag-ids)
            with tag-blob = (getf props :tags)
            with tag-offsets = (getf props :tag-offsets)
            with text-ids = (getf props :text-ids)
            with text-blob = (getf props :texts)
            with text-offsets = (getf props :text-offsets)
            for i from 0 below (getf props :n)
            for row = (make-compact-sense-prop
                       :id (aref ids i)
                       :sense-id (aref sense-ids i)
                       :tag (intern-text (ichiran/memdict-int::pool-ref
                                          tag-blob tag-offsets (aref tag-ids i)))
                       :text (intern-text (ichiran/memdict-int::pool-ref
                                           text-blob text-offsets (aref text-ids i)))
                       :ord (aref ords i)
                       :seq (aref seqs i))
            do (push row (gethash (compact-sense-prop-sense-id row) *prop-by-sense*)))))
  ;; The loader pushes, so every list is reversed here; this restores ascending
  ;; id order exactly as a database load would.
  (memdict-normalize-order)
  ;; Register the tables exactly as memdict-load does. Without this,
  ;; MEMDICT-TABLE-LOADED-P is false for the sense layer and the analyzer
  ;; silently falls back to querying PostgreSQL for senses and glosses: the
  ;; answers stay correct, so the parity gate still passes, but a golden-corpus
  ;; pass went from 1.50s to 11.70s. That is the whole reason this is here.
  (setf *loaded-tables*
        (union *loaded-tables* '("sense" "gloss" "sense_prop") :test #'equal))
  t)

(defun memdict-save-sense-snapshot (path)
  "Write the sense layer to PATH. Returns the byte size."
  (ichiran/int-snapshot:int-snapshot-save path (sense-layer-tables)))

(defun memdict-load-sense-snapshot (path)
  "Load the sense layer from PATH, replacing whatever is resident."
  (sense-layer-install (ichiran/int-snapshot:int-snapshot-load path)))
