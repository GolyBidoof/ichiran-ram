;;;; src/trie.lisp — S4: character trie for dictionary prefix search.
;;;;
;;;; Replaces O(N^2) substring probing in join-substring-words (dict.lisp:
;;;; 1071-1112): instead of testing every (start,end) window against a hash,
;;;; walk the trie from each start position and only extend while the prefix
;;;; still matches dictionary entries. Linear in matched-prefix depth.
;;;;
;;;; Pure CL — no DB, no ichiran deps. Payloads are opaque; the lattice
;;;; builder decides what to carry (e.g. (table . seq) per word).

(defpackage #:ichiran/trie
  (:use #:cl)
  (:export #:trie #:make-trie #:build-trie #:trie-prefix-matches
           #:trie-entry-count))

(in-package #:ichiran/trie)

(defstruct (trie-node
            (:constructor make-trie-node ())
            (:conc-name tn-))
  ;; char -> trie-node
  (children (make-hash-table :test 'eql))
  ;; list of payloads for words ENDING exactly here
  (payloads nil))

(defstruct (trie (:constructor %make-trie (root count)))
  (root (make-trie-node) :type trie-node)
  (count 0 :type fixnum))

(defun make-trie ()
  (%make-trie (make-trie-node) 0))

(defun build-trie (pairs)
  "Build a trie from PAIRS = list of (cons text payload). Multiple entries
   with identical TEXT all retain their payloads. Returns a trie."
  (let ((trie (make-trie)))
    (dolist (pair pairs trie)
      (let ((text (car pair))
            (payload (cdr pair)))
        (when (and text (plusp (length text)))
          (let ((node (trie-root trie)))
            (loop for ch across text
                  do (let ((child (gethash ch (tn-children node))))
                       (unless child
                         (setf child (make-trie-node)
                               (gethash ch (tn-children node)) child))
                       (setf node child)))
            (push payload (tn-payloads node))
            (incf (trie-count trie))))))
    trie))

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
         (node (trie-root trie))
         (result nil))
    (when (< start limit)
      (loop for end from (1+ start) upto limit
            for ch = (char str (1- end))
            for child = (gethash ch (tn-children node))
            while child
            do (setf node child)
               (when (tn-payloads node)
                 (push (cons end (tn-payloads node)) result))))
    (nreverse result)))
