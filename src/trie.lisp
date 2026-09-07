;;;; src/trie.lisp — S4/R3: compact character trie for dictionary prefix search.
;;;;
;;;; Replaces O(N^2) substring probing in join-substring-words (dict.lisp):
;;;; instead of testing every (start,end) window against the DB, walk the trie
;;;; from each start position and only extend while the prefix still matches
;;;; dictionary entries. Linear in matched-prefix depth.
;;;;
;;;; R3 COMPACT ENCODING (why the old one fatals at full-dict scale):
;;;; The old trie-node used an SBCL hash-table per node (char -> child). Each
;;;; hash-table carries ~4KB of fixed allocation regardless of size, and the
;;;; full dictionary has millions of distinct prefixes — that alone is tens of
;;;; GB. This encoding stores:
;;;;   - ALL edges in ONE fixnum-keyed hash: key = (logior (ash node-id 21)
;;;;     (char-code ch)) — node-id < 2^43, char-code < 2^21, both fit a fixnum
;;;;     on 64-bit SBCL with no consing.
;;;;   - nodes as payload lists in ONE adjustable vector (index = node-id).
;;;; Per-node overhead drops from ~4KB (hash-table) to a single vector slot.
;;;;
;;;; Pure CL — no DB, no ichiran deps. Payloads are opaque; the lattice
;;;; builder decides what to carry (e.g. (table . seq) per word).

(defpackage #:ichiran/trie
  (:use #:cl)
  (:export #:trie #:make-trie #:build-trie #:trie-prefix-matches
           #:trie-entry-count #:trie-node-count #:trie-edge-count))

(in-package #:ichiran/trie)

(defstruct (trie (:constructor %make-trie (edges nodes count)))
  ;; fixnum key -> child node-id
  (edges (make-hash-table :test 'eql) :type hash-table)
  ;; node-id -> payload list (index 0 = root, payloads nil)
  (nodes (make-array 64 :adjustable t :fill-pointer 1) :type (vector t))
  ;; number of distinct texts inserted
  (count 0 :type fixnum))

(declaim (inline edge-key))
(defun edge-key (node-id char-code)
  "Compact fixnum key for the edge (NODE-ID --char-code--> child).
   char-code < 2^21 (max SBCL char #x10FFFF = 1114111 < 2097152) and
   node-id < 2^43, so the combined fixnum is lossless and cons-free."
  (logior (ash node-id 21) char-code))

(defun make-trie ()
  (%make-trie (make-hash-table :test 'eql)
              (make-array 64 :adjustable t :fill-pointer 1)
              0))

(defun trie-node-count (trie)
  "Number of nodes (distinct prefixes + root)."
  (fill-pointer (trie-nodes trie)))

(defun trie-edge-count (trie)
  "Number of edges (distinct (prefix,char) transitions)."
  (hash-table-count (trie-edges trie)))

(defun trie-ensure-node (trie node-id ch)
  "Return the child node-id for (NODE-ID, CH), creating it if absent."
  (let ((key (edge-key node-id (char-code ch))))
    (multiple-value-bind (child found) (gethash key (trie-edges trie))
      (if found
          child
          (let ((new-id (fill-pointer (trie-nodes trie))))
            (vector-push-extend nil (trie-nodes trie))
            (setf (gethash key (trie-edges trie)) new-id)
            new-id)))))

(defun build-trie (pairs)
  "Build a trie from PAIRS = list of (cons text payload). Multiple entries
   with identical TEXT all retain their payloads. Returns a trie."
  (let ((trie (make-trie)))
    (dolist (pair pairs trie)
      (let ((text (car pair))
            (payload (cdr pair)))
        (when (and text (plusp (length text)))
          (let ((node-id 0))
            (loop for ch across text
                  do (setf node-id (trie-ensure-node trie node-id ch)))
            (let ((pl (aref (trie-nodes trie) node-id)))
              (setf (aref (trie-nodes trie) node-id) (cons payload pl)))
            (incf (trie-count trie))))))))

(defun trie-entry-count (trie)
  "Number of distinct texts inserted."
  (trie-count trie))

(defun trie-prefix-matches (trie str start &key (max-len 50))
  "Return a list of (end . payloads) for every dictionary word in TRIE that
   matches STR starting at START. END is the exclusive end index of the match
   (start < end <= (min (length str) (+ start max-len))). PAYLOADS is the full
   list stored at that end node. Empty if no word starts at START."
  (let* ((len (length str))
         (limit (min len (+ start max-len)))
         (edges (trie-edges trie))
         (nodes (trie-nodes trie))
         (node-id 0)
         (result nil))
    (when (< start limit)
      (loop for end from (1+ start) upto limit
            for ch = (char str (1- end))
            for child = (gethash (edge-key node-id (char-code ch)) edges)
            while child
            do (setf node-id child)
               (let ((pl (aref nodes node-id)))
                 (when pl
                   (push (cons end pl) result)))))
    (nreverse result)))
