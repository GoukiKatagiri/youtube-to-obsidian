---
description: YouTube動画を文字起こし・要約してObsidianノートに追加
allowed-tools: Bash, Read, Write, Glob, Grep, AskUserQuestion
argument-hint: <YouTube URL>
---

YouTube動画のURLから文字起こし・要約を行い、Obsidian Vaultに Source型ノートとして追加してください。

## ファーストラン検出

**最初に `~/.config/youtube-to-obsidian/config` の存在を確認してください。**

### config が存在しない場合 → セットアップガイド

以下の手順でユーザーを対話的にガイドしてください:

1. **VAULT_PATH の設定**
   - `~/Library/Mobile Documents/iCloud~md~obsidian/Documents/` を確認し、iCloud Vault を自動検出
   - 検出結果を提案し、ユーザーに確認
   - 見つからない場合はパスの手動入力を求める

2. **SOURCE_FOLDER の決定**
   - デフォルト: `Sources`
   - カスタマイズしたい場合は Vault ルートからの相対パスを入力

3. **ノートテンプレートの確認**
   - リポジトリ内のデフォルトテンプレート (`templates/youtube-summary-template.md`) を使用するか確認
   - カスタマイズしたい場合: テンプレートをコピーして編集 → config の `TEMPLATE_FILE` にパスを設定

4. **config ファイルを生成・保存**
   - `~/.config/youtube-to-obsidian/config` に書き込み
   - VAULT_PATH、SOURCE_FOLDER、TEMPLATE_FILE、EXTRA_PATH を設定

セットアップ完了後、そのまま引数の URL があれば処理を続行。

### config が存在する場合 → 通常の動画処理フロー

## 手順

1. **設定ファイル読み込み**: `~/.config/youtube-to-obsidian/config` から `VAULT_PATH` と `SOURCE_FOLDER` を読み込む

2. **メタデータ取得**: `yt-dlp --dump-json --no-download "$ARGUMENTS"` でタイトル、チャンネル名、公開日、長さ、言語を取得

3. **字幕取得**: 以下のPythonコードで字幕を取得（優先順位: 手動字幕(ja) → 手動字幕(en) → 自動生成字幕(ja) → 自動生成字幕(en)）

```python
from youtube_transcript_api import YouTubeTranscriptApi
api = YouTubeTranscriptApi()
transcript_list = api.list(video_id)
# 手動字幕 → 自動生成字幕の優先順位で取得
# snippet.start からタイムスタンプを取得し [MM:SS] 形式で付与
```

字幕取得に失敗した場合は、利用可能な字幕の一覧をユーザーに提示して相談する。

4. **要約生成**: `~/.claude/skills/obsidian-note-management/references/youtube-summary-template.md` があればそれに従う。なければリポジトリの `templates/youtube-summary-template.md` を参照。

5. **ノート作成**: Source型テンプレートに従い、以下のパスにノートを作成:
   - 保存先: `{VAULT_PATH}/{SOURCE_FOLDER}/{動画タイトル}.md`
   - ファイル名の不正文字（`/\:*?"<>|`）は除去

6. **報告**: 作成したノートのパスとタイプを報告

## Source型ノートフォーマット

```
- Source
---
{YouTube URL}

---

### メタデータ
- **タイトル**: {動画タイトル}
- **チャンネル**: {チャンネル名}
- **公開日**: {YYYY-MM-DD}
- **長さ**: {HH:MM:SS}
- **言語**: {ja/en/...}
- **文字起こし**: {手動字幕/自動字幕}
- **要約日**: {YYYY-MM-DD}

---

### キーワード
`keyword1` `keyword2` `keyword3` ...

---

### 概要
{2-3文の概要}

---

### タイムライン
- [MM:SS](https://youtu.be/{video_id}?t={seconds}) **見出し** — 内容の説明
- [MM:SS](https://youtu.be/{video_id}?t={seconds}) **見出し** — 内容の説明
- ...

---

### 詳細ノート
{深掘り内容}

---

### 発展の種
- **候補ノート名** — 説明（ノートタイプ）

---

### トランスクリプト
> [!note]- 全文を表示
> [00:00] テキスト
> [00:15] テキスト
> ...
```

## テンプレートのカスタマイズ

テンプレートは7つのセクションで構成されています:

1. **メタデータ** — タイトル、チャンネル、公開日等
2. **キーワード** — 主要な概念・用語のインラインコード
3. **概要** — 2-3文の要約
4. **タイムライン** — YouTubeリンク付きタイムスタンプ
5. **詳細ノート** — 深掘りが必要な内容
6. **発展の種** — 派生ノート候補
7. **トランスクリプト** — 全文を折りたたみ callout で格納

カスタマイズ手順:
1. `templates/youtube-summary-template.md` をコピーして編集
2. `~/.config/youtube-to-obsidian/config` の `TEMPLATE_FILE` にカスタムテンプレートのパスを設定

## ルール
- 動画の言語に関わらず、要約は日本語で記述
- 話者の意見と事実を区別する（「〜と主張している」vs「〜である」）
- 見出しは ### (h3) から開始
- [[wikilink]] は新設しない。重要な概念・用語は **太字** で表現する
- トランスクリプト全文はcallout折りたたみ内に格納（タイムスタンプ付き）
- キーワードセクション: 動画の主要なキーワード・重要概念をインラインコード形式で列挙
- タイムラインセクション: 時系列順で主要ポイントを整理。各タイムスタンプは `[MM:SS](https://youtu.be/{video_id}?t={seconds})` 形式のYouTubeリンク
- タイムスタンプの秒数計算: [MM:SS] → t=MM*60+SS（例: [02:15] → t=135）
- エラー時はユーザーと相談（利用可能な字幕一覧の提示等）

対象URL: $ARGUMENTS
