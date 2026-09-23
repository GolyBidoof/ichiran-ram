;;; warm-server.lisp — a long-lived, warmed process that evaluates forms sent
;;; on stdin. Started by warm.sh; exists so that measurements do not each pay
;;; the Quicklisp + snapshot load (~10s) again.
(ql:quickload (list :ichiran :ichiran/cli :ichiran/ram) :silent t)
(in-package :cl-user)
(eval-when (:compile-toplevel :load-toplevel :execute) (require :sb-sprof))

(defun warm-boot ()
  (if ichiran/serve-parallel::*dict-baked*
      ;; Baked core: the analyzer, the integer layer and the sense layer are
      ;; already in the image, so there is nothing to read and no database to
      ;; talk to. Only the per-process caches need priming.
      (progn
        (format t "~&warm-boot: dictionary is baked into this image, skipping loads~%")
        (ichiran/serve-parallel:warm-caches))
      (ichiran/conn:with-db nil
        (ichiran/memdict-compact:memdict-load-int
         :snapshot (or (uiop:getenv "SNAPSHOT") "local-env/ichiran-int.snap"))
        (ichiran/memdict-compact:memdict-load
         :chunk 200000 :tables '("sense" "gloss" "sense_prop"))
        (setf ichiran/dict::*memdict-p* t)
        (ichiran/serve-parallel:warm-caches)
        (setf ichiran/serve-parallel::*db-available* t)))
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

(defun golden-lines ()
  "The 364 dumpable lines of data/golden-corpus.txt, the corpus the performance
   plan records its ~2.6s full-RAM baseline over."
  (with-open-file (in (asdf:system-relative-pathname :ichiran "data/golden-corpus.txt"))
    (loop for line = (read-line in nil nil)
          while line
          for text = (string-trim '(#\Space #\Tab #\Newline) line)
          unless (or (zerop (length text)) (char= (char text 0) #\#))
            collect text)))

(defun bench-corpus (&key (reps 3) (warmup t) (parallel nil) (workers 10))
  "Best-of-REPS wall time over the golden corpus. REPORTS the serial number by
   default, because that is the one the performance plan records. Warms first:
   the first pass over a corpus pays lazily built caches, and measuring without
   a warmup is how a run gets reported ~200ms slower than it is."
  (let* ((work (golden-lines))
         (n (length work))
         (f (if parallel
                (lambda () (ichiran/serve-parallel:map-lines-parallel
                            work #'ichiran/serve-parallel:romanize-safe :workers workers))
                (lambda () (map nil #'ichiran/serve-parallel:romanize-safe work)))))
    (when warmup (funcall f))
    (let ((best nil))
      (dotimes (i reps)
        (sb-ext:gc :full t)
        (let ((t0 (get-internal-real-time)))
          (funcall f)
          (let ((wall (/ (- (get-internal-real-time) t0)
                         internal-time-units-per-second)))
            (when (or (null best) (< wall best)) (setf best wall)))))
      (format nil "golden lines=~a ~:[serial~;parallel(n=~:*~a)~]-best=~ams"
              n parallel (round (* 1000 best)) workers))))

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

(defun ram-dump (&optional (out "/tmp/ram-warm.json"))
  "Dump the golden corpus through THIS warm process's RAM path, so it can be
   compared against the cached database baseline
   (data/golden-corpus-baseline.json) in seconds. The database side must never
   be regenerated for a comparison: it is the reference and it is already on
   disk."
  (with-open-file (corpus (asdf:system-relative-pathname :ichiran "data/golden-corpus.txt"))
    (with-open-file (res out :direction :output :if-exists :supersede)
      (loop for line = (read-line corpus nil nil)
            while line
            for text = (string-trim '(#\Space #\Tab #\Newline) line)
            unless (or (zerop (length text)) (char= (char text 0) #\#))
              do (princ (jsown:to-json
                         (handler-case (ichiran:romanize* text :limit 5)
                           (error (e) (list :error (princ-to-string e)))))
                        res)
                 (terpri res))))
  out)

(defun ram-order (table text)
  "First few ids and seqs the RAM path returns for TEXT, to compare against
   the database's own row order for the same query."
  (let ((rows (ichiran/memdict-compact:memdict-find table text)))
    (list :n (length rows)
          :ids (loop for r in (subseq rows 0 (min 6 (length rows)))
                     collect (funcall (if (equal table 'kana-text)
                                          'ichiran/memdict-compact:compact-kana-id
                                          'ichiran/memdict-compact:compact-kanji-id)
                                      r))
          :seqs (loop for r in (subseq rows 0 (min 6 (length rows)))
                      collect (funcall (if (equal table 'kana-text)
                                           'ichiran/memdict-compact:compact-kana-seq
                                           'ichiran/memdict-compact:compact-kanji-seq)
                                       r)))))

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
