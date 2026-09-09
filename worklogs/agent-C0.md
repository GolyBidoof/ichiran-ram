# C0 — Coordinator worklog

## Environment (done)
- SBCL 2.6.8 (brew), PostgreSQL 16.15, quicklisp, all deps loaded
- DB: ichiran-260118.pgdump restored → 2,512,557 entries in `jmdict`
- add-errata ran; caches + suffix init done
- Postgres data dir migrated INTO workspace `local-env/pgdata/` (workspace-write only now)
- quicklisp symlink: ~/quicklisp/local-projects/ichiran → workspace (reads from here)

## Git
- 47eb22e baseline (as provided, + analysis + implementation docs)
- 640e421 C0: local env + parity.sh + golden corpus v1 + env-check
- next: seams.md + bench tooling

## Gates so far
- parity.sh: 764/764 assertions PASSED (1 benign execution error: missing optional
  jmdict-data/conj.csv fixture — not engine-related; assertions all pass)
- add-errata + romanize probe: OK ("ichiran wa saikō da zo")
- bench.sh: baseline measurements running → record below

## Bench baseline (fill from bench output)

## Bench baseline (measured 2026-09)
cold first call: 一覧は最高だぞ 1.23s/189MB (first-run warmup; excludes)
warm:
- こんにちは (1w):   249 queries  0.048s   7.4MB
- 学校で勉強しています (4w): 607 q 0.069s 12.3MB
- 日本語を勉強しています (4w): 1041 q 0.135s 23.7MB
- 錬丹術…(9w):           922 q 0.161s 26MB
- これさえあれば…(12w):   605 q 0.136s 17MB
=> 139-1041 queries PER SENTENCE. This is the metric to kill.

## Environment fix (critical for agents)
- Root cause of 4 dead agents: sandbox (workspace-write) blocked SBCL/quicklisp
  writes to ~/.cache and ~/quicklisp (unix-opts fetch). Every agent fresh-quickload died.
- Fix: scripts/sbcl-wrapped forces XDG_CACHE_HOME + QUICKLISP_HOME into
  local-env/, --no-userinit (suppresses ~/.sbclrc old-home load), and correct
  SBCL runtime-option ordering (--dynamic-space-size first).
- Copied ~/quicklisp -> local-env/quicklisp (workspace-contained). unix-opts
  now fetches into workspace. Verified: scripts/sbcl-wrapped ... CLI_LOAD_OK,
  AGENT_SMOKE_OK.
- All scripts (bench/parity/golden) now use scripts/sbcl-wrapped.

## Item 4 (S4 trie) — verified mechanism, memory-blocked deployment
- trie.lisp unit-tested vs brute force (S4_OK earlier).
- Integration in dict.lisp join-substring-words* behind *trie-p* is present.
- Full-dictionary trie (8.7M texts) as hash-nodes FATALS SBCL memory (12GB heap).
- Kana-only (3.3M) builds but kanji words missing -> segmentation breaks.
- Verdict: correct mechanism, needs compact double-array encoding to deploy;
  flag default OFF, harmless. Documented as future work.
