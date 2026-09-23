;;; bench-core.lisp - benchmark a baked serving core.
;;;
;;; Run against an image built by PRESET=full-ram SYSTEM=1 build-image.sh, which
;;; already contains the analyzer and the whole dictionary, so there is nothing
;;; to quickload and nothing to load from disk:
;;;
;;;   scripts/sbcl-wrapped --core local-env/ichiran-serving.core --non-interactive \
;;;     --load scripts/bench-core.lisp --eval '(main)' --eval '(sb-ext:quit)'
;;;
;;; MODE names the run in the output, CORPUS selects the corpus. Reports the
;;; time to a first answer (which is what a user waits for) alongside the best
;;; of three warm passes, so a core can be compared against the database and
;;; snapshot paths in scripts/bench-all.sh.
;;;
;;; This file lives in the repository on purpose. It used to be written to /tmp
;;; by hand, which meant the core row of the benchmark table could not be
;;; reproduced from a fresh checkout.

(in-package :cl-user)

(defun now ()
  (/ (get-internal-real-time) internal-time-units-per-second))

(defun corpus-lines (path)
  "Dumpable lines of PATH: blank lines and # comments skipped."
  (with-open-file (in path)
    (loop for line = (read-line in nil nil)
          while line
          for text = (string-trim (list #\Space #\Tab #\Newline (code-char 12288)) line)
          unless (or (zerop (length text)) (char= (char text 0) #\#))
            collect text)))

(defun run-once (work)
  (let ((t0 (now)))
    (dolist (line work) (ichiran:romanize line))
    (- (now) t0)))

(defun main ()
  (let* ((ready (now))
         (work (corpus-lines (or (uiop:getenv "CORPUS") "data/golden-corpus.txt")))
         (cold (run-once work))
         (best nil)
         (runs nil))
    (dotimes (i 3)
      (let ((elapsed (run-once work)))
        (push elapsed runs)
        (when (or (null best) (< elapsed best)) (setf best elapsed))))
    (format t "~&CORE mode=~a lines=~a ready=~,2fs cold-first=~,3fs best=~,3fs per-line=~,2fms~%"
            (or (uiop:getenv "MODE") "core") (length work) ready cold best
            (/ (* 1000 best) (length work)))
    (format t "  runs=~{~,3f~^ ~}~%" (reverse runs))
    (finish-output)))
