#!/bin/zsh
# YouTube → Obsidian 自動化パイプライン
# Usage: youtube-to-obsidian.sh <YouTube URL>
#
# PopClip拡張またはClaude Code Slash Commandから呼び出される。
# 1. URLからvideo_idを抽出
# 2. yt-dlp でメタデータ取得
# 3. youtube-transcript-api で字幕取得（手動字幕優先）
# 4. claude -p で要約生成 + Source型ノート作成
# 5. macOS通知で完了報告

set -euo pipefail

# --- 設定ファイル読み込み ---
CONFIG_FILE="${HOME}/.config/youtube-to-obsidian/config"

if [[ ! -f "$CONFIG_FILE" ]]; then
  echo "Error: Config file not found: $CONFIG_FILE" >&2
  echo "Run install.sh or copy config.example to $CONFIG_FILE" >&2
  osascript -e 'display notification "設定ファイルが見つかりません。install.sh を実行してください。" with title "YouTube→Obsidian" sound name "Basso"' 2>/dev/null || true
  exit 1
fi

source "$CONFIG_FILE"

# 必須設定の検証
if [[ -z "${VAULT_PATH:-}" || "$VAULT_PATH" == "/path/to/your/vault" ]]; then
  echo "Error: VAULT_PATH is not configured in $CONFIG_FILE" >&2
  osascript -e 'display notification "VAULT_PATH が未設定です。config を編集してください。" with title "YouTube→Obsidian" sound name "Basso"' 2>/dev/null || true
  exit 1
fi

if [[ ! -d "$VAULT_PATH" ]]; then
  echo "Error: VAULT_PATH does not exist: $VAULT_PATH" >&2
  osascript -e "display notification \"Vault が見つかりません: ${VAULT_PATH}\" with title \"YouTube→Obsidian\" sound name \"Basso\"" 2>/dev/null || true
  exit 1
fi

# デフォルト値
SOURCE_FOLDER="${SOURCE_FOLDER:-Sources}"

# PopClipなど非対話シェルからの起動時にPATHが不足するため明示的に追加
if [[ -n "${EXTRA_PATH:-}" ]]; then
  export PATH="${EXTRA_PATH}:$PATH"
fi
export USER="${USER:-$(whoami)}"
export HOME="${HOME:-$(eval echo ~$USER)}"

URL="$1"

if [[ -z "$URL" ]]; then
  echo "Usage: $0 <YouTube URL>" >&2
  exit 1
fi

# --- video_id 抽出 ---
extract_video_id() {
  local url="$1"
  if [[ "$url" =~ 'youtu\.be/([a-zA-Z0-9_-]{11})' ]]; then
    echo "${match[1]}"
  elif [[ "$url" =~ '[?&]v=([a-zA-Z0-9_-]{11})' ]]; then
    echo "${match[1]}"
  elif [[ "$url" =~ 'shorts/([a-zA-Z0-9_-]{11})' ]]; then
    echo "${match[1]}"
  elif [[ "$url" =~ 'live/([a-zA-Z0-9_-]{11})' ]]; then
    echo "${match[1]}"
  else
    echo ""
  fi
}

VIDEO_ID=$(extract_video_id "$URL")
if [[ -z "$VIDEO_ID" ]]; then
  osascript -e 'display notification "無効なYouTube URLです" with title "YouTube→Obsidian" sound name "Basso"'
  echo "Error: Could not extract video_id from URL: $URL" >&2
  exit 1
fi

TMPDIR_WORK=$(mktemp -d /tmp/youtube-to-obsidian.XXXXXX)
trap 'rm -rf "$TMPDIR_WORK"' EXIT

# --- メタデータ取得 ---
echo "Fetching metadata for $VIDEO_ID..."
if ! yt-dlp --dump-json --no-download "$URL" 2>/dev/null > "$TMPDIR_WORK/raw_meta.json"; then
  osascript -e 'display notification "メタデータ取得に失敗しました" with title "YouTube→Obsidian" sound name "Basso"'
  echo "Error: yt-dlp failed for URL: $URL" >&2
  exit 1
fi

TITLE=$(jq -r '.title // "Unknown"' "$TMPDIR_WORK/raw_meta.json")
CHANNEL=$(jq -r '.channel // .uploader // "Unknown"' "$TMPDIR_WORK/raw_meta.json")
UPLOAD_DATE=$(jq -r '.upload_date // ""' "$TMPDIR_WORK/raw_meta.json")
DURATION_STRING=$(jq -r '.duration_string // ""' "$TMPDIR_WORK/raw_meta.json")
LANGUAGE=$(jq -r '.language // "unknown"' "$TMPDIR_WORK/raw_meta.json")

# upload_date を YYYY-MM-DD に整形
if [[ -n "$UPLOAD_DATE" && "$UPLOAD_DATE" != "null" ]]; then
  UPLOAD_DATE_FMT="${UPLOAD_DATE:0:4}-${UPLOAD_DATE:4:2}-${UPLOAD_DATE:6:2}"
else
  UPLOAD_DATE_FMT="不明"
fi

echo "Title: $TITLE"
echo "Channel: $CHANNEL"

# --- 字幕取得 ---
echo "Fetching transcript..."
python3 - "$VIDEO_ID" "$TMPDIR_WORK" << 'PYTHON_SCRIPT'
import sys
import json
from youtube_transcript_api import YouTubeTranscriptApi

video_id = sys.argv[1]
tmpdir = sys.argv[2]

api = YouTubeTranscriptApi()
result = {"transcript": "", "method": "", "language": "", "error": ""}

try:
    transcript_list = api.list(video_id)

    # 優先順位: 手動字幕(ja) → 手動字幕(en) → 自動生成字幕(ja) → 自動生成字幕(en)
    manual = []
    generated = []
    for t in transcript_list:
        if t.is_generated:
            generated.append(t)
        else:
            manual.append(t)

    selected = None
    method = ""

    # 手動字幕から探す
    for lang in ["ja", "en"]:
        for t in manual:
            if t.language_code == lang or t.language_code.startswith(lang + "-"):
                selected = t
                method = "手動字幕"
                break
        if selected:
            break

    # 自動生成字幕から探す
    if not selected:
        for lang in ["ja", "en"]:
            for t in generated:
                if t.language_code == lang or t.language_code.startswith(lang + "-"):
                    selected = t
                    method = "自動字幕"
                    break
            if selected:
                break

    # それでも見つからない場合、最初の利用可能な字幕を使う
    if not selected:
        all_transcripts = manual + generated
        if all_transcripts:
            selected = all_transcripts[0]
            method = "手動字幕" if not selected.is_generated else "自動字幕"

    if selected:
        fetched = selected.fetch()
        # タイムスタンプ付きトランスクリプト
        timestamped_parts = []
        for snippet in fetched:
            minutes = int(snippet.start // 60)
            seconds = int(snippet.start % 60)
            timestamp = f"[{minutes:02d}:{seconds:02d}]"
            timestamped_parts.append(f"{timestamp} {snippet.text}")
        result["transcript"] = "\n".join(timestamped_parts)
        result["method"] = method
        result["language"] = selected.language_code
    else:
        result["error"] = "字幕が見つかりませんでした"

except Exception as e:
    result["error"] = str(e)

with open(f"{tmpdir}/transcript.json", "w", encoding="utf-8") as f:
    json.dump(result, f, ensure_ascii=False, indent=2)
PYTHON_SCRIPT

TRANSCRIPT_ERROR=$(jq -r '.error // ""' "$TMPDIR_WORK/transcript.json")
if [[ -n "$TRANSCRIPT_ERROR" && "$TRANSCRIPT_ERROR" != "" ]]; then
  # 通知メッセージは短く切り詰め、特殊文字を除去
  NOTIFY_ERR=$(echo "$TRANSCRIPT_ERROR" | head -1 | cut -c1-80 | sed "s/[\"'\\\\]//g")
  osascript -e "display notification \"字幕取得失敗: ${NOTIFY_ERR}\" with title \"YouTube→Obsidian\" sound name \"Basso\""
  echo "Error: Transcript fetch failed: $TRANSCRIPT_ERROR" >&2
  exit 1
fi

TRANSCRIPT_METHOD=$(jq -r '.method' "$TMPDIR_WORK/transcript.json")
TRANSCRIPT_LANG=$(jq -r '.language' "$TMPDIR_WORK/transcript.json")
TRANSCRIPT_TEXT=$(jq -r '.transcript' "$TMPDIR_WORK/transcript.json")

echo "Transcript: $TRANSCRIPT_LANG ($TRANSCRIPT_METHOD), ${#TRANSCRIPT_TEXT} chars"

# --- claude -p に渡すデータJSON作成 ---
TODAY=$(date +%Y-%m-%d)

jq -n \
  --arg url "$URL" \
  --arg video_id "$VIDEO_ID" \
  --arg title "$TITLE" \
  --arg channel "$CHANNEL" \
  --arg upload_date "$UPLOAD_DATE_FMT" \
  --arg duration "$DURATION_STRING" \
  --arg language "$TRANSCRIPT_LANG" \
  --arg method "$TRANSCRIPT_METHOD" \
  --arg today "$TODAY" \
  --arg transcript "$TRANSCRIPT_TEXT" \
  '{
    url: $url,
    video_id: $video_id,
    title: $title,
    channel: $channel,
    upload_date: $upload_date,
    duration: $duration,
    transcript_language: $language,
    transcript_method: $method,
    today: $today,
    transcript: $transcript
  }' > "$TMPDIR_WORK/youtube-data.json"

# --- claude -p で要約生成 + ノート作成 ---
echo "Generating summary with Claude..."
SAFE_TITLE=$(echo "$TITLE" | sed 's/[\/\\:*?"<>|]//g' | sed 's/　/ /g' | sed 's/  */ /g' | sed 's/^ //;s/ $//')
NOTE_PATH="${VAULT_PATH}/${SOURCE_FOLDER}/${SAFE_TITLE}.md"

CLAUDECODE= claude -p "あなたはObsidian Vaultのノート作成アシスタントです。以下のYouTube動画データからSource型ノートを作成してください。

## 指示
1. 添付のJSONデータを読み込む
2. youtube-summary-templateに従って要約を生成する
3. 以下のフォーマットでノートを作成する（必ずこの形式を厳守）

## ノートフォーマット（厳守）

\`\`\`
- Source
---
{url}

---

### メタデータ
- **タイトル**: {title}
- **チャンネル**: {channel}
- **公開日**: {upload_date}
- **長さ**: {duration}
- **言語**: {transcript_language}
- **文字起こし**: {transcript_method}
- **要約日**: {today}

---

### キーワード
\`keyword1\` \`keyword2\` \`keyword3\` ...

---

### 概要
{2-3文の概要}

---

### タイムライン
- [MM:SS](https://youtu.be/{video_id}?t={seconds}) **見出し** — 内容の説明
- [MM:SS](https://youtu.be/{video_id}?t={seconds}) **見出し** — 内容の説明 → [[関連ノート]]
- ...

---

### 詳細ノート
{深掘りが必要な内容。不要なら省略可}

---

### 発展の種
- [[候補ノート名]] — 説明（ノートタイプ）
- ...

---

### トランスクリプト
> [!note]- 全文を表示
> [00:00] テキスト
> [00:15] テキスト
> ...

\`\`\`

## ルール
- 動画の言語に関わらず、要約は日本語で記述
- 話者の意見と事実を区別する（「〜と主張している」vs「〜である」）
- 見出しは ### (h3) から開始
- 関連しそうな概念には [[wikilink]] を付与
- トランスクリプト全文はObsidianのcallout折りたたみ内に格納（タイムスタンプ付き）
- キーワードセクション: 動画の主要なキーワード・重要概念をインラインコード形式で列挙
- タイムラインセクション: トランスクリプトのタイムスタンプ [MM:SS] を参考に、時系列順で主要ポイントを整理。各タイムスタンプは https://youtu.be/{video_id}?t={seconds} 形式のYouTubeリンクにする。video_id は動画データの video_id フィールドを使用
- タイムスタンプの秒数計算: [MM:SS] → t=MM*60+SS （例: [02:15] → t=135）

## 保存先
${NOTE_PATH}

## 動画データ
$(cat "$TMPDIR_WORK/youtube-data.json")
" --permission-mode acceptEdits --allowedTools "Write" --output-format text 2>/dev/null

# --- 結果確認 + 通知 ---
if [[ -f "$NOTE_PATH" ]]; then
  osascript -e "display notification \"${SAFE_TITLE}\" with title \"YouTube→Obsidian ✓\" sound name \"Glass\""
  echo "Success: Note created at $NOTE_PATH"
else
  osascript -e 'display notification "ノート作成に失敗しました" with title "YouTube→Obsidian" sound name "Basso"'
  echo "Error: Note was not created at expected path: $NOTE_PATH" >&2
  exit 1
fi
