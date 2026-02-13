---
description: YouTube動画を文字起こし・要約してObsidianノートに追加
allowed-tools: Bash, Read, Write, Glob, Grep
argument-hint: <YouTube URL>
---

YouTube動画のURLから文字起こし・要約を行い、Obsidian Vaultに Source型ノートとして追加してください。

## 手順

1. **設定ファイル読み込み**: `~/.config/youtube-to-obsidian/config` から `VAULT_PATH` と `SOURCE_FOLDER` を読み込む

2. **メタデータ取得**: `yt-dlp --dump-json --no-download "$ARGUMENTS"` でタイトル、チャンネル名、公開日、長さ、言語を取得

3. **字幕取得**: 以下のPythonコードで字幕を取得（優先順位: 手動字幕(ja) → 手動字幕(en) → 自動生成字幕(ja) → 自動生成字幕(en)）

```python
from youtube_transcript_api import YouTubeTranscriptApi
api = YouTubeTranscriptApi()
transcript_list = api.list(video_id)
# 手動字幕 → 自動生成字幕の優先順位で取得
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

### 概要
{2-3文の概要}

---

### 主要ポイント
- {ポイント1} → 関連: [[既存ノート]]
- ...

---

### 詳細ノート
{深掘り内容}

---

### 発展の種
- [[候補ノート名]] — 説明（ノートタイプ）

---

### トランスクリプト
> [!note]- 全文を表示
> {トランスクリプト全文}
```

## ルール
- 動画の言語に関わらず、要約は日本語で記述
- 話者の意見と事実を区別する（「〜と主張している」vs「〜である」）
- 見出しは ### (h3) から開始
- 関連しそうな概念には [[wikilink]] を付与
- トランスクリプト全文はcallout折りたたみ内に格納
- エラー時はユーザーと相談（利用可能な字幕一覧の提示等）

対象URL: $ARGUMENTS
