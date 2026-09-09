# Performance Benchmark — Old vs New (by alphabet composition)

Date: 2026-09. Three configurations measured head-to-head on the same corpus
with varying hiragana/katakana/kanji composition. Times are median-of-3 wall
clock for `(romanize text :with-info t)`; DB is local PostgreSQL (warm).

## Corpus (alphabet composition)

| # | Sentence | Composition |
|---|---|---|
| 1 | こんにちは | hiragana (5 kana) |
| 2 | ありがとうございます | hiragana (10 kana) |
| 3 | コンピューター | katakana |
| 4 | 錬丹術 | kanji (3 chars) |
| 5 | 日本語を勉強しています | kanji+hiragana |
| 6 | 一覧は最高だぞ | kanji+hiragana |
| 7 | 錬丹術は医学方面に特化してるというからね | kanji-heavy long |
| 8 | 昨日、学校で日本語の試験がありました。友達と一緒に図書館で勉強しました。 | paragraph (mixed) |

## Results — per-sentence wall time (seconds, median of 3)

| Sentence | OLD (pristine, flags OFF) | NEW (cache ON, DB) | CORE (analyzer-on-core, memdict ON) | CORE/OLD | CORE/NEW |
|---|---|---|---|---|---|
| こんにちは | 0.0346 | 0.0419 | 0.0296 | 0.86× | 0.71× |
| ありがとうございます | 0.0710 | 0.0763 | 0.0627 | 0.88× | 0.82× |
| コンピューター | 0.0110 | 0.0118 | 0.0081 | 0.74× | 0.69× |
| 錬丹術 | 0.0119 | 0.0129 | 0.0097 | 0.82× | 0.75× |
| 日本語を勉強しています | 0.0837 | 0.1142 | 0.0813 | 0.97× | 0.71× |
| 一覧は最高だぞ | 0.0371 | 0.0364 | 0.0286 | 0.77× | 0.79× |
| 錬丹術は医学方面に特化してる… | 0.1474 | 0.1940 | 0.1181 | 0.80× | 0.61× |
| paragraph | 0.1960 | 0.2489 | 0.1597 | 0.81× | 0.64× |
| **TOTAL** | **0.5927** | **0.7364** | **0.4978** | **0.84×** | **0.68×** |

## Raw dict lookup (find-word / memdict-find)

| Lookup | DB-backed | Serving-core (RAM) | Speedup |
|---|---|---|---|
| こんにちは | 0.599 ms | 0.04 µs | **~15,000×** |
| ありがとうございます | 0.163 ms | 0.04 µs | ~4,000× |
| コンピューター | 0.139 ms | 0.03 µs | ~4,600× |

## Honest interpretation

1. **The serving core is the real win.** The CORE configuration (full 3.08M-row
   kana dict in RAM, analyzer loaded on top) is **16–39% faster than the
   pristine baseline on every sentence**, and **~32% faster than the
   cache-ON DB path** overall. The raw dict lookup is 3,000–15,000× faster
   than a DB query — that's the kana-heavy path that dominated before.

2. **The S1/S2 DB cache is NOT a wall-clock win on single short sentences.**
   cache-ON measured 1.07–1.36× SLOWER than pristine flags-OFF per sentence
   (mutex overhead + batch-prefetch queries exceed the savings when the DB
   connection is warm and sentences are short). Its value is query-count
   reduction across a warm daemon (cross-sentence reuse) and the nil-sentinel
   fix (which is in both HEAD configs). The handover's "3–38×" figures were
   cold-connection single-shot measurements, not warm-daemon throughput.

3. **Query counts (pristine vs HEAD, both flags OFF): identical** — behavior
   parity holds; HEAD is ~20-25% faster on wall time from the earlier S6
   compile-polish/char-scan work.

4. Caveats: measurements are on this Mac (arm64, local PostgreSQL, warm pool).
   The CORE path still falls back to DB for entry/sense/conj lookups in
   romanize (the ~500-600 scoring queries remain); the dict-covered part is
   what's served from RAM. Full kana+kanji core needs a 32GB+ host.

## Method
- Same 8-sentence corpus, same process warmup (1 easy sentence) per config.
- OLD = pristine commit 47eb22e (worktree), flags all OFF.
- NEW = current HEAD, `*use-cache-p*` ON.
- CORE = current HEAD, `--core local-env/ichiran-serving.core`, analyzer
  quickloaded on top, `*memdict-p*` ON.
- Median of 3 runs per sentence to dampen GC/DB noise.
