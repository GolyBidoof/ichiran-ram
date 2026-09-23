;;; warm-server.lisp — a long-lived, warmed process that evaluates forms sent
;;; on stdin. Started by warm.sh; exists so that measurements do not each pay
;;; the Quicklisp + snapshot load (~10s) again.
(ql:quickload :ichiran :silent t)
(load "src/memdict-compact.lisp")
(load "src/memdict-int.lisp")
(load "src/memdict-compact-shims.lisp")
(load "src/int-snapshot.lisp")
(load "src/serve-parallel.lisp")
(in-package :cl-user)
(eval-when (:compile-toplevel :load-toplevel :execute) (require :sb-sprof))

(defun warm-boot ()
  (ichiran/conn:with-db nil
    (ichiran/memdict-compact:memdict-load-int
     :snapshot (or (uiop:getenv "SNAPSHOT") "local-env/ichiran-int.snap"))
    (ichiran/memdict-compact:memdict-load
     :chunk 200000 :tables '("sense" "gloss" "sense_prop"))
    (setf ichiran/dict::*memdict-p* t)
    (ichiran/serve-parallel:warm-caches)
    (setf ichiran/serve-parallel::*db-available* t))
  ;; force the suffix cache to completion so requests do not race its builder
  (ichiran:romanize "テスト")
  (sleep 2)
  t)

(defun vn-lines ()
  (with-open-file (in "the visual-novel dialogue sample")
    (loop for line = (read-line in nil nil)
          while line
          for text = (string-right-trim '(#\Newline #\Return) line)
          collect text)))

(defun vn-work (&optional (repeats 20))
  "The standard 140-line the visual novel workload as a simple-vector."
  (coerce (loop repeat repeats append (vn-lines)) 'simple-vector))

(defun bench (&key (repeats 20) (workers 10) (reps 3))
  "Best-of-REPS wall time over the the visual novel workload at WORKERS, plus serial."
  (let ((work (vn-work repeats))
        (out nil))
    (dolist (n (list 1 workers))
      (let ((best nil))
        (dotimes (i reps)
          (sb-ext:gc :full t)
          (let ((t0 (get-internal-real-time)))
            (if (= n 1)
                (map nil #'ichiran/serve-parallel:romanize-safe work)
                (ichiran/serve-parallel:map-lines-parallel
                 work #'ichiran/serve-parallel:romanize-safe :workers n))
            (let ((wall (/ (- (get-internal-real-time) t0)
                           internal-time-units-per-second)))
              (when (or (null best) (< wall best)) (setf best wall)))))
        (push (cons n (round (* 1000 best))) out)))
    (format nil "lines=~a serial=~ams parallel(n=~a)=~ams"
            (length work) (cdr (assoc 1 out)) workers (cdr (assoc workers out)))))

(defun bench-consed (&key (repeats 20) (workers 10))
  "Wall time and bytes consed, for one serial and one parallel pass."
  (let ((work (vn-work repeats)))
    (flet ((one (n)
             (sb-ext:gc :full t)
             (let ((b0 (sb-ext:get-bytes-consed))
                   (t0 (get-internal-real-time)))
               (if (= n 1)
                   (map nil #'ichiran/serve-parallel:romanize-safe work)
                   (ichiran/serve-parallel:map-lines-parallel
                    work #'ichiran/serve-parallel:romanize-safe :workers n))
               (format nil "n=~a wall=~ams consed=~,1fMB"
                       n (round (* 1000 (/ (- (get-internal-real-time) t0)
                                           internal-time-units-per-second)))
                       (/ (- (sb-ext:get-bytes-consed) b0) 1048576.0)))))
      (format nil "~a | ~a" (one 1) (one workers)))))

(format t "~&WARM-BOOTING~%") (finish-output)
(warm-boot)
(format t "~&WARM-READY~%") (finish-output)

(let ((n 0))
  (loop for form = (read *standard-input* nil :eof)
        until (eq form :eof)
        do (incf n)
           (let ((res (handler-case (eval form)
                        (error (e) (format nil "ERROR: ~a" e)))))
             ;; BEGIN/END bracketing: a long value can arrive in several
             ;; writes, and a reader must not treat a half-written line as the
             ;; finished answer.
             (format t "~&WARM-RESULT-BEGIN ~a~%~a~%WARM-RESULT-END ~a~%" n res n)
             (finish-output))))
(format t "~&WARM-EOF~%")
