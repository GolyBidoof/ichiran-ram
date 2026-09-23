;;;; src/memdict-compact-shims.lisp — analyzer shims for the compact dict.
;;;;
;;;; This file is ONLY loaded in the full-ichiran context (after quickload
;;;; :ichiran), where the ichiran/dict generics exist. It defines defmethods
;;;; so the compact structs (from src/memdict-compact.lisp) work transparently
;;;; as readings in the existing analyzer code. It is deliberately separate
;;;; from memdict-compact.lisp so that file can load BARE (postmodern only)
;;;; for the R4 zero-DB serving core.

(in-package #:ichiran/memdict-compact)

;; ---- word-conj-data (needs get-conj-data from ichiran/dict) ----

(defmethod ichiran/dict::word-conj-data ((obj compact-kana))
  (ichiran/dict::get-conj-data (compact-kana-seq obj)
                               (compact-kana-conjugations obj)
                               (compact-kana-text obj)))

(defmethod ichiran/dict::word-conj-data ((obj compact-kanji))
  (ichiran/dict::get-conj-data (compact-kanji-seq obj)
                               (compact-kanji-conjugations obj)
                               (compact-kanji-text obj)))

;; ---- get-original-text (needs get-original-text* + select-dao) ----

(defmethod ichiran/dict::get-original-text ((reading compact-kana) &key conj-data)
  (let ((orig-texts (ichiran/dict::get-original-text* (or conj-data (ichiran/dict::word-conj-data reading))
                                                      (compact-kana-text reading)))
        (table 'ichiran/dict::kana-text))
    (loop for (txt seq) in orig-texts
          ;; R6: seq+text probe from RAM when kana_text is loaded.
          nconc (if (ichiran/dict::memdict-table-loaded-p "kana_text")
                    (memdict-find-by-seq-text table seq txt)
                    (ichiran/dict::select-dao table (:and (:= 'seq seq) (:= 'text txt)))))))

(defmethod ichiran/dict::get-original-text ((reading compact-kanji) &key conj-data)
  (let ((orig-texts (ichiran/dict::get-original-text* (or conj-data (ichiran/dict::word-conj-data reading))
                                                      (compact-kanji-text reading)))
        (table 'ichiran/dict::kanji-text))
    (loop for (txt seq) in orig-texts
          ;; R6: seq+text probe from RAM when kanji_text is loaded.
          nconc (if (ichiran/dict::memdict-table-loaded-p "kanji_text")
                    (memdict-find-by-seq-text table seq txt)
                    (ichiran/dict::select-dao table (:and (:= 'seq seq) (:= 'text txt)))))))

;; ---- simple-text interface shims ----

(defmethod ichiran/dict::word-conjugations ((obj compact-kana))
  (compact-kana-conjugations obj))
(defmethod (setf ichiran/dict::word-conjugations) (v (obj compact-kana))
  (setf (compact-kana-conjugations obj) v))
(defmethod ichiran/dict::hintedp ((obj compact-kana))
  (compact-kana-hintedp obj))
(defmethod ichiran/dict::true-text ((obj compact-kana))
  (compact-kana-text obj))
(defmethod ichiran/dict::get-text ((obj compact-kana))
  (compact-kana-text obj))
(defmethod ichiran/dict::get-kana ((obj compact-kana))
  ;; mirror simple-text get-kana :around: apply hints unless disabled/hinted
  (or (unless (or ichiran/dict::*disable-hints* (compact-kana-hintedp obj))
        (let ((ichiran/dict::*disable-hints* t))
          (ichiran/dict::get-hint obj)))
      (compact-kana-text obj)))
(defmethod ichiran/dict::word-type ((obj compact-kana))
  :kana)

(defmethod ichiran/dict::word-conjugations ((obj compact-kanji))
  (compact-kanji-conjugations obj))
(defmethod (setf ichiran/dict::word-conjugations) (v (obj compact-kanji))
  (setf (compact-kanji-conjugations obj) v))
(defmethod ichiran/dict::true-text ((obj compact-kanji))
  (compact-kanji-text obj))
(defmethod ichiran/dict::get-text ((obj compact-kanji))
  (compact-kanji-text obj))
(defmethod ichiran/dict::get-kana ((obj compact-kanji))
  ;; Mirror the kanji-text method exactly: conjugation-aware best kana first
  ;; (best-kana-conj walks to the parent entry via query-parents-kanji, which
  ;; is RAM-served when the conjugation trio is loaded), then the
  ;; kana_text regex fallback.
  (let ((bk (ichiran/dict::best-kana-conj obj)))
    (if (eql bk :null)
        (ichiran/dict::get-kanji-kana-old obj)
        bk)))
(defmethod ichiran/dict::word-type ((obj compact-kanji))
  :kanji)

;; ---- generic accessor shims ----

(defmethod ichiran/dict::text ((obj compact-kana)) (compact-kana-text obj))
(defmethod ichiran/dict::seq ((obj compact-kana)) (compact-kana-seq obj))
(defmethod ichiran/dict::ord ((obj compact-kana)) (compact-kana-ord obj))
(defmethod ichiran/dict::common ((obj compact-kana)) (compact-kana-common obj))
(defmethod ichiran/dict::common-tags ((obj compact-kana)) (compact-kana-common-tags obj))
(defmethod ichiran/dict::conjugate-p ((obj compact-kana)) (compact-kana-conjugate-p obj))
(defmethod ichiran/dict::nokanji ((obj compact-kana)) (compact-kana-nokanji obj))
(defmethod ichiran/dict::best-kana ((obj compact-kana)) (compact-kana-best-kana obj))
(defmethod ichiran/dict::best-kanji ((obj compact-kana)) (compact-kana-best-kanji obj))
(defmethod ichiran/dict::get-kanji ((obj compact-kana))
  ;; Mirror the kana-text method: conjugation-aware best kanji, else NIL.
  (let ((bk (ichiran/dict::best-kanji-conj obj)))
    (unless (eql bk :null) bk)))
(defmethod ichiran/dict::id ((obj compact-kana)) (compact-kana-id obj))

(defmethod ichiran/dict::text ((obj compact-kanji)) (compact-kanji-text obj))
(defmethod ichiran/dict::seq ((obj compact-kanji)) (compact-kanji-seq obj))
(defmethod ichiran/dict::ord ((obj compact-kanji)) (compact-kanji-ord obj))
(defmethod ichiran/dict::common ((obj compact-kanji)) (compact-kanji-common obj))
(defmethod ichiran/dict::common-tags ((obj compact-kanji)) (compact-kanji-common-tags obj))
(defmethod ichiran/dict::conjugate-p ((obj compact-kanji)) (compact-kanji-conjugate-p obj))
(defmethod ichiran/dict::nokanji ((obj compact-kanji)) (compact-kanji-nokanji obj))
(defmethod ichiran/dict::best-kana ((obj compact-kanji)) (compact-kanji-best-kana obj))
(defmethod ichiran/dict::id ((obj compact-kanji)) (compact-kanji-id obj))

;; ---- reading-str ----
;; reading-str has methods for simple-text and integer. kanji-text and
;; kana-text inherit the simple-text one, but compact rows are structs, not
;; simple-text subclasses, so they need their own or the RAM path signals
;; NO-APPLICABLE-METHOD where the database path succeeds. Found by
;; scripts/ram-parity.sh, which compares the whole golden corpus between the
;; two paths -- it reached this on a conjugated reading of 覧る, a case the
;; unit tests do not cover.
(defmethod ichiran/dict::get-kanji ((obj compact-kanji))
  ;; Mirror kanji-text: for a kanji row the text IS the kanji form.
  (compact-kanji-text obj))

(defmethod ichiran/dict::reading-str ((obj compact-kana))
  (ichiran/dict::reading-str* (ichiran/dict::get-kanji obj)
                              (ichiran/dict::get-kana obj)))

(defmethod ichiran/dict::reading-str ((obj compact-kanji))
  (ichiran/dict::reading-str* (ichiran/dict::get-kanji obj)
                              (ichiran/dict::get-kana obj)))

(defmethod ichiran/dict::seq ((obj compact-conj)) (compact-conj-seq obj))
(defmethod ichiran/dict::seq-from ((obj compact-conj)) (compact-conj-from obj))
(defmethod ichiran/dict::seq-via ((obj compact-conj)) (compact-conj-via obj))
(defmethod ichiran/dict::id ((obj compact-conj)) (compact-conj-id obj))

;; ---- adjoin-word (compound-word building) ----
;; The analyzer builds compound words by adjoining readings. compact-kana /
;; compact-kanji are structurally simple-text-like (get-text/get-kana/seq/
;; word-conjugations all shimmed above), so mirror the simple-text adjoin:
;; make a compound-text with the compact struct as primary.

(defmethod ichiran/dict::adjoin-word ((word1 compact-kana) (word2 ichiran/dict::simple-text)
                                      &key text kana score-mod score-base)
  (ichiran/dict::make-instance 'ichiran/dict::compound-text
                               :text text :kana kana :primary word1
                               :words (list word1 word2)
                               :score-mod score-mod :score-base score-base))

(defmethod ichiran/dict::adjoin-word ((word1 compact-kanji) (word2 ichiran/dict::simple-text)
                                      &key text kana score-mod score-base)
  (ichiran/dict::make-instance 'ichiran/dict::compound-text
                               :text text :kana kana :primary word1
                               :words (list word1 word2)
                               :score-mod score-mod :score-base score-base))

(defmethod ichiran/dict::adjoin-word ((word1 compact-kana) (word2 compact-kana)
                                      &key text kana score-mod score-base)
  (ichiran/dict::make-instance 'ichiran/dict::compound-text
                               :text text :kana kana :primary word1
                               :words (list word1 word2)
                               :score-mod score-mod :score-base score-base))

(defmethod ichiran/dict::adjoin-word ((word1 compact-kanji) (word2 compact-kanji)
                                      &key text kana score-mod score-base)
  (ichiran/dict::make-instance 'ichiran/dict::compound-text
                               :text text :kana kana :primary word1
                               :words (list word1 word2)
                               :score-mod score-mod :score-base score-base))

(defmethod ichiran/dict::adjoin-word ((word1 compact-kana) (word2 compact-kanji)
                                      &key text kana score-mod score-base)
  (ichiran/dict::make-instance 'ichiran/dict::compound-text
                               :text text :kana kana :primary word1
                               :words (list word1 word2)
                               :score-mod score-mod :score-base score-base))

(defmethod ichiran/dict::adjoin-word ((word1 compact-kanji) (word2 compact-kana)
                                      &key text kana score-mod score-base)
  (ichiran/dict::make-instance 'ichiran/dict::compound-text
                               :text text :kana kana :primary word1
                               :words (list word1 word2)
                               :score-mod score-mod :score-base score-base))

;; ---- R5: compact-entry analyzer shims (root-p, n-kanji, ...) ----
;; calc-score calls (root-p entry), (n-kanji entry), (primary-nokanji entry)
;; on the entry object; route those generics to the compact struct slots.

(defmethod ichiran/dict::root-p ((obj compact-entry))
  (compact-entry-root-p obj))
(defmethod ichiran/dict::n-kanji ((obj compact-entry))
  (compact-entry-n-kanji obj))
(defmethod ichiran/dict::n-kana ((obj compact-entry))
  (compact-entry-n-kana obj))
(defmethod ichiran/dict::primary-nokanji ((obj compact-entry))
  (compact-entry-primary-nokanji obj))
(defmethod ichiran/dict::seq ((obj compact-entry))
  (compact-entry-seq obj))
(defmethod ichiran/dict::content ((obj compact-entry))
  (compact-entry-content obj))

;; ---- R5: compact-sense-prop shims (uk path uses sense-id) ----
(defmethod ichiran/dict::sense-id ((obj compact-sense-prop))
  (compact-sense-prop-sense-id obj))
(defmethod ichiran/dict::text ((obj compact-sense-prop))
  (compact-sense-prop-text obj))
(defmethod ichiran/dict::seq ((obj compact-sense-prop))
  (compact-sense-prop-seq obj))

;; ---- R5: compact-conj-prop analyzer shims ----
(defmethod ichiran/dict::id ((obj compact-conj-prop))
  (compact-conj-prop-id obj))
(defmethod ichiran/dict::conj-id ((obj compact-conj-prop))
  (compact-conj-prop-conj-id obj))
(defmethod ichiran/dict::conj-type ((obj compact-conj-prop))
  (compact-conj-prop-conj-type obj))
(defmethod ichiran/dict::pos ((obj compact-conj-prop))
  (compact-conj-prop-pos obj))
(defmethod ichiran/dict::conj-neg ((obj compact-conj-prop))
  (compact-conj-prop-neg obj))
(defmethod ichiran/dict::conj-fml ((obj compact-conj-prop))
  (compact-conj-prop-fml obj))

;; ---- adjoin-word shims (suffix machinery makes compounds from readings) ----
;; The DAO methods specialise on simple-text, but RAM lookups (find-word-with-pos,
;; memdict-find, ...) return compact structs. Without these, building a compound
;; from a RAM row signals no-primary-method. Bodies mirror the simple-text ones.

(defun ram-adjoin-simple (word1 word2 text kana score-mod score-base)
  (make-instance 'ichiran/dict::compound-text
                 :text text :kana kana :primary word1 :words (list word1 word2)
                 :score-mod score-mod :score-base score-base))

(defun ram-adjoin-compound (word1 word2 text kana score-mod)
  ;; Slot names must be qualified: with-slots interns them in this package
  ;; otherwise, and compound-text's slots live in ichiran/dict.
  (with-slots ((s-text ichiran/dict::text)
               (s-kana ichiran/dict::kana)
               (s-words ichiran/dict::words)
               (s-score-mod ichiran/dict::score-mod))
      word1
    (setf s-text text s-kana kana
          s-words (append s-words (list word2))
          s-score-mod (funcall (if (listp s-score-mod) 'cons 'list) score-mod s-score-mod)))
  word1)

(macrolet ((def-ram-adjoin-simple (t1 t2)
             `(defmethod ichiran/dict::adjoin-word ((w1 ,t1) (w2 ,t2)
                                                    &key text kana score-mod score-base)
                (ram-adjoin-simple w1 w2 text kana score-mod score-base)))
           (def-ram-adjoin-compound (t2)
             `(defmethod ichiran/dict::adjoin-word ((w1 ichiran/dict::compound-text) (w2 ,t2)
                                                    &key text kana score-mod &allow-other-keys)
                (ram-adjoin-compound w1 w2 text kana score-mod))))
  (def-ram-adjoin-simple compact-kana compact-kana)
  (def-ram-adjoin-simple compact-kana compact-kanji)
  (def-ram-adjoin-simple compact-kanji compact-kana)
  (def-ram-adjoin-simple compact-kanji compact-kanji)
  (def-ram-adjoin-simple compact-kana ichiran/dict::simple-text)
  (def-ram-adjoin-simple ichiran/dict::simple-text compact-kana)
  (def-ram-adjoin-simple compact-kanji ichiran/dict::simple-text)
  (def-ram-adjoin-simple ichiran/dict::simple-text compact-kanji)
  (def-ram-adjoin-compound compact-kana)
  (def-ram-adjoin-compound compact-kanji))
