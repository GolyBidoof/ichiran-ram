;;;; ichiran.asd

(in-package :asdf)

(defsystem #:ichiran
  :serial t
  :description "Ichiran means list in Japanese"
  :author "Timofei Shatrov <timofei.shatrov@example.com>"
  :license "MIT"
  :depends-on (#:cl-ppcre
               #:alexandria
               #:split-sequence
               #:postmodern
               #:cxml
               #:cl-unicode
               #:cl-csv
               #:lisp-unit
               #:bordeaux-threads
               #:jsown
               #:lparallel
               #:diff
               #:cl+ssl
               )
  :components ((:file "package")
               (:file "characters")
               (:file "numbers")
               (:file "conn")
               (:file "dict-errata")
               (:file "dict")
               (:file "dict-grammar")
               (:file "dict-split")
               (:file "dict-counters")
               (:file "dict-load")
               (:file "romanize")
               (:file "dict-custom")
               (:file "deromanize")
               (:file "kanji")
               (:file "ichiran")
               (:file "tests"))
  :perform (test-op
            (o s)
            (uiop:symbol-call :ichiran/test :run-all-tests)))


(defsystem #:ichiran/cli
  :serial t
  :description "Command line interface for Ichiran"
  :author "Timofei Shatrov <timofei.shatrov@example.com>"
  :license "MIT"
  :depends-on (#:ichiran
               #:unix-opts
               )
  :build-operation "program-op"
  :build-pathname "ichiran-cli"
  :entry-point "ichiran/cli::main"
  :components ((:file "cli")))


(defsystem #:ichiran/ram
  :description "Ichiran fork: in-RAM dictionary and zero-DB serving cores"
  :license "MIT"
  :depends-on (#:ichiran #:postmodern)
  :serial t
  :components ((:file "src/trie")
               (:file "src/memdict-compact")
               (:file "src/memdict-int")
               (:file "src/memdict-compact-shims")
               ;; Thread-parallel serving. Loads last: it specialises on the
               ;; analyzer's caches and calls ichiran:romanize.
               (:file "src/serve-parallel")))


#+sb-core-compression
(defmethod asdf:perform ((o asdf:image-op) (c asdf:system))
  (uiop:dump-image (asdf:output-file o c) :executable t :compression t))


(defsystem #:ichiran/ram
  :serial t
  :description "In-RAM dictionary layer and parallel serving for ichiran"
  :author "Timofei Shatrov <timofei.shatrov@example.com> (upstream ichiran);
             RAM layer by GolyBidoof"
  :license "MIT"
  :depends-on (#:ichiran)
  ;; These were loaded as loose source files, so every process start RECOMPILED
  ;; them. As system components ASDF compiles them once into fasls and later
  ;; starts just load, which is most of the difference between a slow boot and
  ;; a fast one. Order is the load order they already required.
  :components ((:file "src/memdict-compact")
               (:file "src/memdict-int")
               (:file "src/memdict-compact-shims")
               (:file "src/int-snapshot")
               (:file "src/serve-parallel")))
