# R3 — Golden Corpus Coverage Review (read-only)

Scope: coverage audit of `data/golden-corpus.txt` against the §0 parity
contract (IMPLEMENTATION-PLAN.md) + `scripts/golden-snapshot.sh` usage
(`romanize* text :limit 5`, one JSON line per input line, blank/`#` lines
skipped). Static analysis only — no Lisp runs, no builds, **no corpus
modification**. Scratch notes: `/tmp/r3-corpus-notes.md`.

## 1. File hygiene — PASS

| Check | Result |
|---|---|
| BOM | none (first bytes `e4 b8 80` = 一) |
| Newlines | LF only: 334 LF, 0 CR, 0 CRLF; file ends with newline |
| Whitespace | no leading/trailing spaces, no tabs, no U+3000, no empty lines |
| Encoding | valid UTF-8, no NUL |
| Duplicates | 334 unique lines; no exact dupes, no near-dupes after stripping terminal punctuation |
| ASCII | only inside `Wi-Fi` (L67, L309) and `QR` (L314); **zero digits** (ASCII or fullwidth) |

334 lines vs the plan's "~200" — a superset, fine. Snapshot driver skips
empty and `#`-prefixed lines; the corpus uses neither (keep that convention).

## 2. Coverage matrix

| # | Category | Verdict | Evidence |
|---|---|---|---|
| a | Counters | **PARTIAL** | 枚 L72, 回 L122, 泊 L63, 番 L172, 度 L29/189/313, 六時 L42, 一日 L122. **Missing: 杯, 匹, 個, 人 (五人分/何人), 歳, 円, X時間, 件, 台, 本-as-counter, 階-as-counter** (only 階段 L240) |
| b | Kana-only | **OK** | 31 zero-kanji lines: L10–12, 14–18, 36, 68, 78–79, 100, 114, 128–129, 137, 142, 183, 185, 212, 218–219, 238–239, 259, 264, 274, 304–305, 308 |
| c | Long run-on (no punct) | **CRITICAL GAP** | Max line length 23 (L9); only L2 (20) and L9 (23) ≥ 20; **zero lines ≥ 25, zero ≥ 60**. Plan §0 requires "long-run-on"; gate G2 targets "60+ char, no punct"; C0 bench only measured up to 12 words → the quadratic regime is untested |
| d | Conjugation | **MOSTLY OK, 6 holes** | Covered: passive L4/L5/L250; causative L49 + 見せる L57/150/323; 書かされる (caus-passive) L5; negative ない×5 + ません many + ないで L231–233; past 25+; te-iru 17; te-mo-ii 5; te-kudasai 51; te-morau/itadaku 11; ば L9/172/255/327; たら L157/251; たい 7. **Missing: ておく/とく (0), すぎる (0), らしい (0), ちゃう (0), conjectural そう (0 — only そうです L43), んです (0)**; ちゃう/てしまう thin (1: L6); ましょう 1 (L197) |
| e | Rare readings / names / loanwords | **PARTIAL** | Loanwords strong (64 katakana lines); 々 L76 (別々に); rare readings: 原本 L323 (もともと), 金庫/金曜日 (きん), 人気 L208 (にんき), 見頃 L202, 方面 L2, 処方 L120, 入 ×7, 本日 L332–333. **Missing: person names (only places 新宿/京都/東京), 〆 (U+3006), 〇 (U+3007, absent from whole file), 行方, and chars 中 / 生 / うち which appear ZERO times** |
| f | Particle clusters | **MOSTLY OK, 2 thin** | は 109, が 50, で 148, を 71, に 43, も 29, の 37 — OK. と quotative 5 (L2/43/132/190/191) + conjunctive L180 — OK-ish. **へ: 1 line only (L26). や as particle: 0 lines** (all 4 hits are in-word: L100/139/230/307) |
| g | Numbers and dates | **PARTIAL** | Date words good: 昨日 L25, 今日 L91–93/153, 明日 L43/95/333, 来週 L26, 年末年始 L276, お盆 L277, GW L278, 定休日 L145; times OK (六時 L42, 何時, 何分 L158). **Kanji numerals thin (一/六/三 only); 〇 0 lines; digits 0 lines** → `numbers.lisp` digit path entirely unpinned |
| h | Honorifics | **PARTIAL** | ご L10/11/142/334, お 24 lines, ください 58, ます 52, なさってください L104, いただきます L12. Thin on いただく-verb and ご+verb compounds |
| i | Ambiguous splits | **WEAK** | Present: 行 (11 lines, いく/ゆく), 本 (10: 日本語/本物/日本/本日/原本/本を), 金 (5: お金/金庫/料金/返金/現金), 見 (6), 入 (7), 食 (9), 手 (4: 苦手/手紙/手作り/手続き), 人 (2), 方 (2: 方面/処方), 間 (2, both 時間). **Missing: うち, 中, 生, 行方, 手前/手際 (て/た readings), 方 (direction/person), 間 (間隔/間に)**. Corpus skews heavily to polite travel/hotel/shop/hospital/tech-support QA |

Register skew: 58/334 lines end in ください; only 28 informal (plain-tai)
lines. New lines should lean informal.

## 3. Duplicates / near-duplicates / trivial lines

- **Exact dupes: none.** Near-dupes after stripping terminal punctuation:
  none.
- Substring pairs (6) — all legitimate variant tests, not redundancy:
  L18⊂L63/86/221 (いくらですか as tail), L35⊂L104, L143⊂L94, L96⊂L97,
  L282⊂L241. L56/L316 is a good intentional word-order pair (名前を書いて
  ください / 名前をここに書いてください). The もう一度 trio (L29/189/313) are
  three different sentences.
- **No trivial lines:** nothing ≤ 2 chars; the seven 4-char lines (L14 ただいま,
  L35 お大事に, L95 また明日, L101 良い夢を, L160 帰ります, L287 火事です,
  L311 圏外です) are real phrases, not waste. No 1–3 char lines: a single-char
  degenerate line (e.g. `え`) would be a cheap edge case — optional.
- Nothing needs replacing; the corpus is clean. The problem is gaps, not noise.

## 4. Proposed additional lines (worklog only — NOT added to corpus)

Append-only recommended (baseline JSON is line-aligned; appending keeps old
JSON lines byte-stable so diffs localize to new lines).

### 4.1 Long run-ons — the biggest gap (25+ chars, no punctuation; G2 regime)

| Line | Len |
|---|---|
| 電車がかなり遅れていたので予定していた会議に全く間に合わなくて仕方なく電話で事情を説明してようやく許してもらうことにした | 60 |
| 子供のころは夏になると毎年家族で海に連れて行ってもらって泳ぎを覚えたり貝殻を探したりして友達ととても楽しい思い出があった | 60 |
| 駅までの道を歩きながら昼ごはんは何にしようかなと考えていたら急に雨が降り始めた | 39 |
| 昨日の夜は遅くまで仕事をしていて家に帰ったら家族はもう寝ていて静かだった | 36 |
| この街には古い寺と新しいビルが混在していて観光客がいつも写真を撮っている | 36 |

(60-char lines hit the G2 "60+ char, no punct" target; all test multi-clause
て-chains, informal register, mixed polite/informal.)

### 4.2 Counters (a)

| Line | Len | Tests |
|---|---|---|
| 緑茶を二杯とコーヒーを一杯ください | 17 | 杯 ×2 |
| 三階の三〇二号室に猫を二匹飼っています | 19 | 階, 匹, 〇 in number |
| りんごを三個と卵を十個買いました | 16 | 個 ×2, 十 |
| 二千円分の切符を五人分買ってください | 18 | 円, 人, 二千/五人 |
| 三時間半くらい並んで待ちました | 15 | 時間, 半 |

### 4.3 Missing conjugation patterns (d)

| Line | Len | Tests |
|---|---|---|
| 鍵を忘れないようにしておいてください | 18 | ておく |
| 三時間待ちすぎた | 8 | すぎる |
| 明日は雨が降るらしいです | 12 | らしい |
| 知らないうちに電気が消えちゃった | 16 | ちゃう (colloq. してしまう) |
| これは私の財布なんです | 11 | んです (explanatory) |
| 雨が降りそうなので早く帰りましょう | 17 | conjectural そう + ましょう |

### 4.4 Particles (f)

| Line | Len | Tests |
|---|---|---|
| 紅茶や緑茶のどちらでも結構です | 15 | や as particle, どちらでも |
| 東京へ行く前に京都にも寄ってください | 18 | へ (second instance), 前に, も |

### 4.5 Numbers and dates (g)

| Line | Len | Tests |
|---|---|---|
| 2024年3月5日午前3時に会議があります | 21 | ASCII digits (pins numbers.lisp digit path — zero coverage today) |
| 二〇二四年三月五日午前十時三十分に駅に着く予定です | 25 | 〇, full kanji date, 十分 as jikan |

### 4.6 Rare readings / names / ambiguity (e, i)

| Line | Len | Tests |
|---|---|---|
| 佐藤太郎が昨日新宿まで来ました | 15 | person name (satori/saburo class readings) |
| 〆切は明日の正午です | 10 | 〆 (U+3006) |
| 行方不明の人がいると聞きました | 15 | 行方 (jukujikun ぎょうほう) |
| 手前の席はまだ空いています | 13 | 手前 (てまえ) |

### 4.7 Punctuation (broadens the L8/L16-only sample)

| Line | Len | Tests |
|---|---|---|
| 本当ですか？ | 6 | ？ (fullwidth) |
| 「すみません」を何度も言いました | 16 | 「」 corner brackets |

Caveat: the snapshot driver wraps errors as `{"error": ...}`, so if ？/「」
expose a current crash, the baseline will pin that behavior — that's a finding
for the coordinator, not a corpus defect.

**Total: 26 proposed lines** (5 + 5 + 6 + 2 + 2 + 4 + 2). All lines verified
punctuation-free in §4.1, no leading/trailing whitespace, no `#`, no ASCII
digits outside the one intentional digit line.

## 5. Notes / risks

1. The snapshot contract pins `romanize* :limit 5` **without hints**; the
   "hints" item in §0's corpus spec is not currently pinned by
   `golden-corpus-baseline.json`. If hint-dependent readings matter for parity,
   extend the snapshot driver (a second baseline file), not the corpus file.
2. Adding lines requires regenerating the baseline (`scripts/golden-snapshot.sh`)
   on a clean tree. The 60-char lines may take seconds each (query count grows
   superlinearly — expected; that's exactly what G2 measures).
3. §4.5 digit line: if `numbers.lisp` mishandles ASCII digits today, the
   baseline pins the broken behavior — review the snapshot for that line before
   accepting.
4. Nothing in this review required modifying the corpus; per task constraint
   the corpus was left untouched.

## 6. Verdict

- **Hygiene: PASS** — no BOM, LF-only, trailing newline, fully trimmed, no
  dupes/trivial lines.
- **Coverage: GOOD for** kana-only, particle volume, loanwords,
  te-form/kudasai/past/passive/negative; **WEAK for** counters,
  numbers/dates, honorifics, ambiguous splits; **CRITICAL GAP in long run-ons
  (zero lines ≥ 25 chars; G2's 60+ regime untested)** plus six zero-coverage
  conjugation patterns (ておく/すぎる/らしい/ちゃう/そう/んです), 中/生/うち
  absent, 〆/〇/digits/person-names absent, へ thin, や missing as particle.
- **Recommendation:** append the 26 lines above (minimum: §4.1's five run-ons +
  §4.2's five counters), regenerate the baseline, and re-run parity.sh on a
  clean tree before the first perf merge.
