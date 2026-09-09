# Table-by-Table Marginal Benchmark — Full In-RAM Dictionary

Date: 2026-09. Method: `bench-config.lisp`, each table-configuration in its
own SBCL process (fresh connection, S1 cache OFF, `*memdict-p*` ON), 8
sentences covering hiragana / katakana / kana+kanji / kanji-heavy /
paragraph. Metric: total DB queries (with-log) + wall time for
`romanize :with-info t`.

## Headline: query totals per configuration

| Config (tables in RAM) | Total q | vs DB-only | Hiragana | Katakana | Kana+kanji | Kanji-heavy | Paragraph |
|---|---|---|---|---|---|---|---|
| DB-only (memdict OFF) | **5919** | — | 814 | 27 | 731 | 1620 | 2727 |
| +kana_text | 4871 | **−17.7%** | 732 | 27 | 767 | 1467 | 1878 |
| +kanji_text | 4302 | −27.3% | 581 | 24 | 641 | 1261 | 1795 |
| +entry | 4302 | −27.3% | 581 | 24 | 641 | 1261 | 1795 |
| **+sense+gloss+sense_prop** | **2135** | **−63.9%** | 275 | 13 | 332 | 628 | 887 |
| +conjugation (alone) | 3132 | −47.1% | 448 | 26 | 380 | 838 | 1440 |
| +conj_prop (no csr) | 4899 | −17.2% | 746 | 21 | 551 | 1240 | 2341 |
| +conj_source_reading (full) | — (16GB heap wall; 64GB host ok) | | | | | | |

## Marginal impact per table (queries cut per GB of RAM)

| Table | MB | Marginal q cut | Impact/GB |
|---|---|---|---|
| sense | 38 | (part of senses trio) | very high |
| sense_prop | 287 | (part of senses trio) | very high |
| gloss | 256 | (part of senses trio) | high |
| kana_text | 2,683 | −1048 | medium |
| kanji_text | 4,325 | −569 | low-medium |
| entry | 633 | ~0 (on top of kanji) | low |
| conjugation | 340 | **negative when alone** | must load with conj_prop+csr |
| conj_prop | 287 | negative when alone | must load with conjugation+csr |
| conj_source_reading | 3,929 | (needs full trio) | only worth it as the last trio |

## Per-sentence-type winners (which tables matter for which text)

- **Hiragana-heavy** (こんにちは 251→64, ありがとう 563→211): driven by
  **kana_text + senses**. kana_text serves the candidate lookups; senses
  eliminate the gloss/posi/uk queries.
- **Katakana** (27→13): senses + kana_text (katakana is kana-class).
- **Kana+kanji mixed** (日本語を勉強しています 594→275): kanji_text + senses.
- **Kanji-heavy** (錬丹術… 850→331, 学校で… 770→297): kanji_text + senses;
  the biggest absolute wins (kanji chars' entry/posi/uk lookups).
- **Paragraph** (2727→887): all three groups compound — kana_text for the
  kana runs, kanji_text for the kanji, senses for every word's gloss.

## Key findings (why the naive load order is wrong)

1. **The senses trio (sense + gloss + sense_prop) is the single biggest
   win: −63.9% total queries** for only ~0.6 GB. It should be loaded FIRST
   among the "secondary" tables.
2. **Loading conjugation without conj_prop + conj_source_reading is
   counterproductive** — the analyzer gets the conj rows from RAM but still
   fires per-conj DB queries for props/csr, MORE than the DB's batched path.
   The three conjugation tables are a package deal.
3. **entry adds little on top of kanji_text** in this measurement — the
   entry lookups are already cheap/rare per sentence; its 633 MB is lower
   priority than the senses trio.
4. **kana_text then kanji_text** are the foundation (candidate generation);
   load them first, then senses, then (only as a full trio) conjugation.

## Recommended load order for the GitHub repo (impact-per-GB)

1. `kana_text` (2.7 GB) — foundation, −18%
2. `kanji_text` (4.3 GB) — foundation, −27%
3. `sense` + `gloss` + `sense_prop` (0.6 GB) — **the big win, −64%**
4. `entry` (0.6 GB) — cheap, small extra
5. `conjugation` + `conj_prop` + `conj_source_reading` (4.6 GB) — as a trio,
   last (needs the most RAM for the least marginal gain; on 64GB fine)

This differs from the alphabetical/naive order and prioritizes the
senses trio ahead of the large conj_source_reading table.

## Honest caveats

- Separate-process runs have connection-warmup noise (±10% on some rows);
  the totals and the −17/−27/−64% pattern are consistent across runs.
- The full 9-table config exceeded this Mac's 16 GB heap (conj_source_reading
  is 3.9 GB alone) — not a code defect; the 64 GB host loads everything.
- Wall time broadly tracks query count (DB is localhost); on a remote DB the
  query-count reduction matters even more.

## Addendum — page-length validation (R6)

Whole golden corpus as 19 paragraphs (4.3K chars), DB-only vs lite
(kana_text+sense+gloss+sense_prop, R6 residual wiring included):

| | DB | Lite | Δ |
|---|---|---|---|
| Total queries | 180,985 | 89,335 | **−51%** |
| Wall time (localhost) | 19.8s | 10.3s | **−48%** |
| Failed paragraphs | 0 | 0 | — |
| Byte-identical paras | — | 14/19 | (5 = tiebreak variants, cf. R6-REPORT §6) |

Per-paragraph queries roughly halve throughout (e.g. 10028→4853,
17324→8731). The speed story holds up at page scale.
