;; Everything that defines a package must run at TOP LEVEL, before the reader
;; reaches the forms that reference those packages. SBCL reads a file form by
;; form, so a (load ...) hidden inside a function body is too late.
(ql:quickload (list :ichiran :ichiran/cli) :silent t)
(load "src/memdict-compact.lisp")
(load "src/memdict-int.lisp")
(load "src/memdict-compact-shims.lisp")
(load "src/int-snapshot.lisp")
(in-package :cl-user)
(defvar *t-sys* (/ (get-internal-real-time) internal-time-units-per-second))
(defun now () (/ (get-internal-real-time) internal-time-units-per-second))
(defun vn-lines ()
  (with-open-file (in (or (uiop:getenv "CORPUS") "the visual-novel sample"))
    (loop for line = (read-line in nil nil)
          while line
          for text = (string-trim (list #\Space #\Tab #\Newline (code-char 12288)) line)
          unless (zerop (length text)) collect text)))
(defun run-once (work)
  (let ((t0 (now))) (dolist (l work) (ichiran:romanize l)) (- (now) t0)))
(defun main ()
  (let ((mode (or (uiop:getenv "MODE") "db")) (work nil))
    (setf work (vn-lines))
    (let ((t1 (now)))
      (ichiran/conn:with-db nil
        (when (string-equal mode "ram")
          (ichiran/memdict-compact:memdict-load-int :snapshot "local-env/ichiran-int.snap")
          (ichiran/memdict-compact:memdict-load :chunk 200000
                                                :tables '("sense" "gloss" "sense_prop"))
          (setf ichiran/dict::*memdict-p* t))
        (let ((dict-t (- (now) t1)))
          (let* ((cold (run-once work)) (best nil) (runs nil))
            (dotimes (i 3)
              (let ((elapsed (run-once work))) (push elapsed runs) (when (or (null best) (< elapsed best)) (setf best elapsed))))
            (format t "~&RESULT mode=~a lines=~a chars=~a sys=~,2fs dict=~,2fs cold-first=~,3fs best=~,3fs per-line=~,2fms~%"
                    mode (length work) (reduce #'+ work :key #'length)
                    *t-sys* dict-t cold best (/ (* 1000 best) (length work)))
            (format t "  runs=~{~,3f~^ ~}~%" (reverse runs))))))
    (finish-output) (sb-ext:quit)))
