# Glossary — Japanese (ja)

Terms chosen for `ja.json`, used consistently. Sentences use polite です/ます; buttons,
titles and labels use short noun forms. iOS system terms follow Apple's Japanese wording
(設定, キャンセル, 完了, 削除, 共有, 保存, OK, ファイル, 写真, サーバ, ユーザ — no trailing
long vowel, Apple style). Full-width punctuation inside Japanese sentences (。、（）：),
app and screen names in 「 」. No space between Japanese text and a number or counter
(`%lldページ`, `%lld件`); a space around Latin units and symbols (`A = 440 Hz`, `♩ = 60`).
Japanese has one plural category, so every value is a plain string.

| English | ja | Notes |
|---|---|---|
| audition (the event) | オーディション | Auditions tab = オーディション; my auditions = 自分のオーディション |
| open auditions / the feed | 募集中のオーディション / 募集情報 | "No open cello auditions right now" = 現在募集中のチェロのオーディションはありません |
| audition day | オーディション日 | |
| application deadline / deadline | 応募締切 / 締切 | |
| excerpt | オケスタ | the term Japanese orchestral players use (オーケストラ・スタディ); excerpt page = オケスタのページ; counter 曲 ("Excerpt 2 of 6" = 6曲中2曲目) |
| orchestral excerpts (list category) | オケスタ | |
| part (sheet music) | パート譜 | My parts = 自分のパート譜; Scan my part = パート譜をスキャン |
| list (audition repertoire list) | リスト | counter 件; "list"/"lists" both リスト; official list = 公式リスト |
| repertoire | 課題曲 | Repertoire header = 課題曲; excerpt lists = 課題曲リスト |
| catalogue (the app's excerpt catalogue) | カタログ | match to catalogue = カタログと照合; link = リンク |
| chair / position | ポジション | Which chair? = ポジションは？; Include all chairs = すべてのポジションを含める; ", all chairs" = 、全ポジション |
| principal / assistant principal | 首席 / 副首席 | |
| section (player) | セクション | |
| lists phrase (`lists.phrase.allChairs` / `lists.phrase.chair`) | この楽器のリスト / このポジションのリスト | the key text carries no `%@`, so `merge_translations.py` rejects a value with placeholders; these fixed labels pass and the evidence lines are built as 「label：収集した9件中7件に掲載、全ポジション（2022–2026）」. If the checker is taught to compare against the Swift `defaultValue`, prefer `%@の%@` / `%@%@の%@` (チェロのリスト, セクションチェロのリスト) |
| second (chair) | 2番 | |
| utility | ユーティリティ | |
| high / low (horn) | 上吹き / 下吹き | |
| concertmaster | コンサートマスター | |
| any (chair) | 指定なし | |
| round | 審査段階 | preliminary = 一次審査, semi-final = 二次審査, final = 最終審査 |
| readiness | 準備状況 | not started = 未着手, learning the notes = 譜読み中, under tempo = テンポ未達, nearly there = もう少し, audition-ready = 本番OK |
| reference audio | 参考音源 | "Reference" (segment) = 参考音源 |
| recording / take | 録音 / テイク | "Record" (button) = 録音; my recordings = 自分の録音; a take is always テイク (このテイクについて, 無題のテイク) |
| mock audition | 模擬オーディション | behind the screen = ブラインド審査; run = 回 |
| count-in | カウントイン | |
| drone | ドローン | |
| metronome / tap tempo | メトロノーム / タップテンポ | |
| tempo | テンポ | typical tempo = 一般的なテンポ; tempo marking = 速度記号; composer's metronome = 作曲者のメトロノーム指定 |
| beat / beats per bar | 拍 / 1小節の拍数 | beat unit = 拍の単位; subdivision = 細分化 |
| bar | 小節 | bar N = 第N小節 |
| meter / key / clef | 拍子 / 調 / 音部記号 | |
| tuning (A = 440) | チューニング | Tuning (A4) = チューニング（A4）; pitch = ピッチ |
| note lengths | 全音符, 2分音符, 4分音符, 8分音符, 16分音符, 32分音符 | dotted quarter = 付点4分音符 |
| sharp / flat / natural | シャープ / フラット / ナチュラル | accidental = 臨時記号 |
| tie / dot / rest | タイ / 付点 / 休符 | |
| scan | スキャン | |
| read the notes (OMR) | 音符を読み取る | Read from your scan = スキャンから読み取り |
| fix notes | 音符を修正 | corrected = 修正済み |
| mark start / mark end | 開始をマーク / 終了をマーク | |
| mark the excerpt (crop) | オケスタの範囲を指定 | |
| loop | ループ | |
| checked / verified | 確認済み | "Check the official list" (unverified value) = 公式リストを確認 |
| remind me (toggle) | 通知を受け取る | reminders = 通知 |
| draft | 下書き | |
| curated (prose) | 人が執筆 | AI-generated = AI生成 |
| notes (free text, all senses) | ノート | the excerpt commentary as feedback topic = オケスタの解説 |
| tier: core / common / occasional | 定番 / 頻出 / 時々 | share = 割合; tier = ランク |
| popular / very popular | 人気 / 大人気 |
| server | サーバ | Settings → Server = 「設定」→「サーバ」 |
| account / sign in / sign out | アカウント / サインイン / サインアウト | Sign in with Apple = Appleでサインイン |
| scrambled (code) | 判読できない形に変換した | plain words for hashed; says no more than the English. Only where the English itself adds "can't be turned back into the number" (trends privacy text) write 元の番号に戻せない形に変換した |
| region | 地域 | |
| instrument | 楽器 | ヴァイオリン, ヴィオラ, チェロ, コントラバス, ファゴット, テューバ… |
| player (musician) | 奏者 | |
| orchestra | オーケストラ | |
| feedback | フィードバック | Send feedback = フィードバックを送信; Report an error = 誤りを報告 |
