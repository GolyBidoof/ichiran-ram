;;; bench-lines.lisp - per-line latency, cache progression, worker skew and GC.
;;;
;;; Answers the questions a mean cannot: whether blank lines take a fast path,
;;; how the tail behaves, whether the worker pool is balanced, how the score
;;; cache warms, and what the collector costs.
;;;
;;;   CORPUS=the novel-prologue sample scripts/sbcl-wrapped \
;;;     --core local-env/ichiran-serving.core --non-interactive \
;;;     --load scripts/audit-stages.lisp --load scripts/bench-lines.lisp \
;;;     --eval '(bench-all)' --eval '(sb-ext:quit)'
;;;
;;; SERIAL binds a fresh score cache, because only WITH-WORKER-STATE binds one
;;; and the serial path therefore runs uncached otherwise. The PARALLEL section
;;; calls ROMANIZE-SAFE inside WITH-WORKER-STATE, which is what production does.


(in-package :cl-user)

(defvar *join-count* 0)
(defvar *line-times* nil)
(defvar *json-errors* 0)
(defvar *err-samples* nil)

(defun lines-vec ()
  (coerce (lines-of (or (uiop:getenv "CORPUS") "the novel-prologue sample")) 'vector))

(defun ms (ticks) (/ ticks 1000.0))

(defun pct (sorted p)
  (aref sorted (min (1- (length sorted)) (floor (* p (length sorted))))))

(defun note-error (e)
  (incf *json-errors*)
  (when (< (length *err-samples*) 3)
    (push (princ-to-string e) *err-samples*))
  nil)

(defun patch-join-count ()
  (let ((orig (symbol-function 'ichiran/dict::join-substring-words)))
    (setf (symbol-function 'ichiran/dict::join-substring-words)
          (lambda (&rest a) (incf *join-count*) (apply orig a)))))

(defun safe-romanize (line)
  (handler-case (ichiran:romanize* line :limit 5)
    (error (e) (note-error e))))

(defun json-text (line)
  (handler-case (jsown:to-json (ichiran:romanize* line :limit 5))
    (error (e) (note-error e)
      (format nil "(:error)"))))

(defun time-n (n thunk)
  (let ((t0 (get-internal-real-time)))
    (dotimes (i n) (funcall thunk))
    (/ (- (get-internal-real-time) t0) (float n))))

(defun trivial-cases ()
  (let ((u3000 (string (code-char 12288))))
    (list (cons "empty" "")
          (cons "u3000-only" u3000)
          (cons "ascii-spaces" "   ")
          (cons "newline" (string #\Newline))
          (cons "u3000x3" (concatenate 'string u3000 u3000 u3000))
          (cons "mixed-ws" (concatenate 'string u3000 " " (string #\Tab))))))

(defun bench-trivial ()
  (format t "~&=== TRIVIAL SECTION~%")
  (dolist (case (trivial-cases))
    (let ((text (cdr case)))
      (setf *join-count* 0)
      (let ((us (time-n 2000 (lambda () (ichiran:romanize* text :limit 5)))))
        (format t "TRIVIAL name=~a chars=~a us/call=~,2f join-entered=~a~%"
                (car case) (length text) us *join-count*))
      (setf *join-count* 0)
      (let ((us (time-n 2000 (lambda () (json-text text)))))
        (format t "TRIVIAL-JSON name=~a us/call=~,2f join-entered=~a~%"
                (car case) us *join-count*))))
  (format t "TRIVIAL-END~%"))

(defun bench-serial (lines)
  (format t "~&=== SERIAL SECTION~%")
  (setf ichiran/dict::*gen-score-cache* (make-hash-table :test 'eql :size 8192))
  (let* ((n (length lines))
         (bh 0) (bm 0) (bb 0)
         (gc0 sb-ext:*gc-run-time*)
         (b0 (sb-ext:get-bytes-consed))
         (t0 (get-internal-real-time)))
    (setf *line-times* (make-array n))
    (loop for i from 0 below n
          do (let ((t1 (get-internal-real-time)))
               (safe-romanize (aref lines i))
               (setf (aref *line-times* i) (- (get-internal-real-time) t1)))
             (when (zerop (mod (1+ i) 50))
               (let ((h ichiran/dict::*gen-score-hits*)
                     (m ichiran/dict::*gen-score-misses*)
                     (by ichiran/dict::*gen-score-bypass*)
                     (dh (- ichiran/dict::*gen-score-hits* bh))
                     (dm (- ichiran/dict::*gen-score-misses* bm)))
                 (format t "CACHE block-end=~a hits=~a misses=~a rate=~,1f% bypass=~a entries=~a~%"
                         (1+ i) dh dm
                         (if (zerop (+ dh dm)) 0.0 (* 100.0 (/ dh (+ dh dm))))
                         (- by bb)
                         (if ichiran/dict::*gen-score-cache*
                             (hash-table-count ichiran/dict::*gen-score-cache*)
                             0))
                 (setf bh h bm m bb by))))
    (let* ((wall (- (get-internal-real-time) t0))
           (sorted (sort (copy-seq *line-times*) #'<))
           (total (reduce #'+ *line-times*))
           (gc (- sb-ext:*gc-run-time* gc0))
           (bytes (- (sb-ext:get-bytes-consed) b0)))
      (format t "SERIAL lines=~a wall=~,1fms sum=~,1fms ms-per-line=~,3f~%"
              n (ms wall) (ms total) (/ (ms wall) n))
      (format t "SERIAL min=~,3f p50=~,3f p90=~,3f p95=~,3f p99=~,3f max=~,3f~%"
              (ms (aref sorted 0)) (ms (pct sorted 0.50)) (ms (pct sorted 0.90))
              (ms (pct sorted 0.95)) (ms (pct sorted 0.99)) (ms (aref sorted (1- n))))
      (format t "GC gc-time=~,1fms consed=~,1fMB per-line=~,1fkB~%"
              (ms gc) (/ bytes 1048576.0) (/ bytes n 1024.0))
      (let ((order (sort (loop for i from 0 below n collect i) #'>
                         :key (lambda (i) (aref *line-times* i)))))
        (loop for k from 0 below 5
              for i = (nth k order)
              do (format t "SLOW rank=~a ms=~,2f chars=~a text=~s~%"
                         (1+ k) (ms (aref *line-times* i)) (length (aref lines i))
                         (subseq (aref lines i) 0 (min 46 (length (aref lines i))))))))))

(defvar *pw* nil)
(defvar *pnext* 0)
(defvar *plock* nil)
(defvar *plines* nil)
(defvar *pseq* nil)

(defun parallel-worker (w)
  (ichiran/serve-parallel::with-worker-state
    (loop for idx = (sb-thread:with-mutex (*plock*)
                      (when (< *pnext* (length *plines*))
                        (prog1 *pnext* (incf *pnext*))))
          while idx
          do (let ((t1 (get-internal-real-time)))
               (ichiran/serve-parallel:romanize-safe (aref *plines* idx))
               (let* ((d (- (get-internal-real-time) t1))
                      (k (sb-thread:thread-name sb-thread:*current-thread*))
                      (e (gethash k *pw*)))
                 (setf (aref *pseq* idx) d)
                 (setf (gethash k *pw*)
                       (if e
                           (list (+ (first e) d) (1+ (second e)) (max (third e) d))
                           (list d 1 d))))))))

(defun bench-parallel (lines)
  (format t "~&=== PARALLEL SECTION~%")
  (setf *pw* (make-hash-table :test 'equal)
        *pnext* 0
        *plock* (sb-thread:make-mutex :name "bench")
        *plines* lines
        *pseq* (make-array (length lines)))
  (let* ((nw (ichiran/serve-parallel:worker-count))
         (t0 (get-internal-real-time))
         (threads (loop for w below nw
                        collect (sb-thread:make-thread
                                 (lambda () (parallel-worker w))
                                 :name (format nil "bench-worker-~a" w)))))
    (mapc #'sb-thread:join-thread threads)
    (let* ((wall (- (get-internal-real-time) t0))
           (busy (reduce #'+ *pseq*))
           (n (length lines))
           (rows '()))
      (format t "PAR workers=~a lines=~a wall=~,1fms busy-sum=~,1fms ms-per-line=~,3f~%"
              nw n (ms wall) (ms busy) (/ (ms wall) n))
      (format t "PAR speedup=~,2fx efficiency=~,1f%~%"
              (/ (ms busy) (ms wall)) (* 100.0 (/ (ms busy) (ms wall) nw)))
      (maphash (lambda (k v) (push (list k (second v) (first v) (third v)) rows)) *pw*)
      (setf rows (sort rows #'string< :key #'first))
      (dolist (r rows)
        (format t "PAR worker=~a lines=~a busy=~,1fms max-line=~,1fms~%"
                (first r) (second r) (ms (third r)) (ms (fourth r))))
      (let ((slow (reduce #'max rows :key #'third))
            (fast (reduce #'min rows :key #'third)))
        (format t "PAR skew slowest=~,1fms fastest=~,1fms ratio=~,2fx~%"
                (ms slow) (ms fast) (/ (float slow) fast))))))

(defun bench-all ()
  (let ((lines (lines-vec)))
    (format t "~&CORPUS lines=~a~%" (length lines))
    (bench-trivial)
    (bench-serial lines)
    (bench-parallel lines)
    (format t "~&=== ERRORS~%ERRORS count=~a~%" *json-errors*)
    (dolist (s *err-samples*) (format t "ERRORS sample=~a~%" s)))
  (finish-output))
