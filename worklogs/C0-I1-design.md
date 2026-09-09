# C0 — I1 integration design (prepared while A1 runs)

Goal G1: with *use-cache-p* on, per-sentence queries drop >=3x vs baseline
(measured 139-1041). Wire A1's src/cache.lisp into calc-score's DB sites.

Hot sites in calc-score (dict.lisp:777-983), all per-candidate-word:
1. ~803  (entry (and seq (get-dao 'entry seq)))   -> (cache:ensure-entry seq)
2. ~822  prefer-kana select-dao sense-prop uk      -> (cache:ensure-uk sp-seq-set)
3. ~826  (posi ... (get-non-arch-posi seq-set))    -> (cache:ensure-posi seq-set)
4. ~806  conj-data = (word-conj-data reading)      -> wraps get-conj-data
         (dict.lisp:342) which itself does conjugation/conj-source-reading/conj-prop selects
         -> (cache:ensure-conj-data seq conj-ids)  [A1 normalizes keys]
5. ~860  get-original-text w/ conj-data -> more queries (secondary; cache if easy)
6. ~884-887 conditional query on prefer-kana sense (only when prefer-kana + kanji) -> rare-ish

Strategy:
- Add (defvar *use-cache-p* nil) + (defvar *cache-package-loaded* nil) guard in dict.lisp
  so the file still loads if src/cache.lisp isn't in the build yet (it won't be in
  ichiran.asd until I2). Integration = wrap each site:
     (if (and *use-cache-p* (find-package :ichiran/cache))
         (cache:ensure-entry seq)
         (get-dao 'entry seq))
  A macro or flet wrapper keeps it readable.
- Flag default OFF => zero behavior change; parity must stay green with flag off,
  and ALSO green with flag on (values must be identical DAOs).
- Invalidation: tests / add-errata call (cache:cache-reset). The 764-test suite
  runs add-errata? No — tests run against warmed caches; but dict-errata may
  mutate DB. Coordinator: call cache-reset at start of run-all-tests via a
  wrapper if cache ever ON during tests. Keep flag OFF for the official parity run.
- Gate G1 measurement: bench.sh with flag ON vs OFF on same sentences.
