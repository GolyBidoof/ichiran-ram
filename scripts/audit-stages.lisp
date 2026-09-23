;;; audit-stages.lisp - where the time actually goes inside one romanize call.
;;;
;;; Why: the hotpath audit counted calls and allocation, which is not the same
;;; as time. This times the real stages over a real corpus, and reports
;;; allocation alongside, because a stage can be allocation-heavy and cheap
;;; (memcpy-shaped) or allocation-light and expensive (hash lookups, scoring).
;;;
;;; Run against a baked core (fastest, no database):
;;;   scripts/sbcl-wrapped --core local-env/ichiran-serving.core --non-interactive \
;;;     --load scripts/audit-stages.lisp --eval '(main)' --eval '(sb-ext:quit)'
;;;
;;; word-info-gloss-json and jsown:to-json are split because jsown:to-json on a
;;; WORD-INFO delegates to the former, and the two have very different fixes.
;;;
;;; CORPUS selects the corpus. Stages mirror dict.lisp's DICT-SEGMENT:
;;;   join-substring-words  candidate generation, segfilters, scoring helpers
;;;   find-best-path        the lattice search over candidate segment lists
;;;   fill-segment-path     building WORD-INFO objects, including sense lookup
;;;   romanize              the plain-text path end to end
;;;   romanize* + json      the serving path, including serialization

(in-package :cl-user)

(defun now () (/ (get-internal-real-time) internal-time-units-per-second))

(defun consed () (sb-ext:get-bytes-consed))

(defun lines-of (path)
  (with-open-file (in path)
    (loop for line = (read-line in nil nil)
          while line
          for text = (string-trim (list #\Space #\Tab #\Newline (code-char 12288)) line)
          unless (or (zerop (length text)) (char= (char text 0) #\#))
            collect text)))

(defmacro stage (name &body body)
  "Run BODY, adding its wall time and allocation to the named accumulator."
  (let ((t-var (intern (format nil "T-~a" name)))
        (b-var (intern (format nil "B-~a" name))))
    `(let ((t0 (now)) (c0 (consed)))
       (prog1 (progn ,@body)
         (incf ,t-var (- (now) t0))
         (incf ,b-var (- (consed) c0))))))

(defun ensure-word-info-json-method ()
  "The SYSTEM=1 core bakes :ichiran but not :ichiran/cli, and the method that
   serializes a WORD-INFO into JSON lives in cli.lisp:52. Without it a baked
   core cannot produce the JSON the daemon produces, and (jsown:to-json info)
   signals NO-APPLICABLE-METHOD. Define it when absent so this audit can
   measure the real serving path on the core as well as on the RAM path."
  ;; FINAL argument is errorp; passing NIL makes FIND-METHOD return NIL rather
  ;; than signal, so check the value. An earlier version wrapped this in
  ;; HANDLER-CASE with errorp NIL and therefore never defined anything.
  (unless (find-method #'jsown:to-json nil
                       (list (find-class 'ichiran/dict:word-info)) nil)
    (defmethod jsown:to-json ((wi ichiran/dict:word-info))
      (jsown:to-json (ichiran/dict::word-info-gloss-json wi)))))

(defun collect-wis (x)
  "Every WORD-INFO reachable from a ROMANIZE* result. Entries are triples for
   words but bare strings for gaps and punctuation, and compound words nest, so
   this walks the structure instead of assuming a shape."
  (cond ((typep x 'ichiran/dict:word-info) (list x))
        ((consp x) (append (collect-wis (car x)) (collect-wis (cdr x))))
        (t nil)))

(defun main ()
  (ensure-word-info-json-method)
  (let* ((path (or (uiop:getenv "CORPUS") "data/golden-corpus.txt"))
         (work (lines-of path))
         (n (length work)))
    (let ((t-join 0) (t-path 0) (t-fill 0) (t-rom 0) (t-info 0) (t-gjson 0) (t-json 0)
          (b-join 0) (b-path 0) (b-fill 0) (b-rom 0) (b-info 0) (b-gjson 0) (b-json 0))
      (declare (special t-join t-path t-fill t-rom t-info t-gjson t-json
                        b-join b-path b-fill b-rom b-info b-gjson b-json))
      ;; Warm every stage first: the first pass pays lazily built caches and is
      ;; not representative of serving.
      (dolist (line work)
        (ichiran/dict::dict-segment line :limit 5)
        (ichiran:romanize line)
        (jsown:to-json (ichiran:romanize* line :limit 5)))
      (sb-ext:gc :full t)
      (dolist (line work)
        (stage join
          (let ((joined (ichiran/dict::join-substring-words line)))
            (stage path
              (let ((paths (ichiran/dict::find-best-path joined (length line) :limit 5)))
                (stage fill
                  (dolist (p paths)
                    (ichiran/dict::fill-segment-path line (car p))))))))
        (stage rom (ichiran:romanize line))
        (let ((info nil))
          ;; ROMANIZE* returns (romanization word-info) pairs; TO-JSON walks
          ;; them and dispatches on each WORD-INFO. Timing the gloss tree on its
          ;; own gives the split: emission is t-json minus t-gjson.
          (stage info (setf info (ichiran:romanize* line :limit 5)))
          ;; Collect first, outside the timed body: an earlier version looked
          ;; only at (second entry) and silently matched nothing, so this stage
          ;; reported zero and hid the real cost.
          (let ((wis (collect-wis info)))
            (stage gjson
              (dolist (wi wis)
                (ichiran/dict::word-info-gloss-json wi))))
          (stage json (jsown:to-json info))))
      (flet ((row (label t-acc b-acc)
               (format t "  ~24a ~8,1f ms  ~7,3f ms/line  ~8,1f MB  ~7,1f kB/line~%"
                       label (* 1000 t-acc) (/ (* 1000 t-acc) n)
                       (/ b-acc 1048576.0) (/ b-acc n 1024.0))))
        (format t "~&STAGES corpus=~a lines=~a chars=~a~%" path n
                (reduce #'+ work :key #'length))
        (row "join-substring-words" t-join b-join)
        (row "find-best-path" t-path b-path)
        (row "fill-segment-path" t-fill b-fill)
        (format t "  ~24a ~8,1f ms  ~7,3f ms/line~%" "  (three above, summed)"
                (* 1000 (+ t-join t-path t-fill)) (/ (* 1000 (+ t-join t-path t-fill)) n))
        (row "romanize (plain)" t-rom b-rom)
        (row "romanize* (analysis)" t-info b-info)
        (row "word-info-gloss-json" t-gjson b-gjson)
        (row "jsown:to-json" t-json b-json)
        (format t "  ~24a ~8,1f ms  ~7,3f ms/line~%" "  json emission (to-json less tree)"
                (* 1000 (- t-json t-gjson)) (/ (* 1000 (- t-json t-gjson)) n))
        (format t "  serving path romanize* + gloss-json + to-json = ~,1f ms, ~7,3f ms/line~%"
                (* 1000 (+ t-info t-json)) (/ (* 1000 (+ t-info t-json)) n))
        (format t "  analysis share of serving: ~,1f%~%"
                (* 100.0 (/ t-info (+ t-info t-json)))))
      (finish-output))))
