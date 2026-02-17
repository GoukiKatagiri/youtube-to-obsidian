#!/bin/zsh
# YouTube → Obsidian 自動化パイプライン v2
# Usage: youtube-to-obsidian.sh <YouTube URL>
#
# キーボードショートカット / PopClip / Claude Code Slash Command / シェルから呼び出される。
# 1. URLからvideo_idを抽出
# 2. yt-dlp でメタデータ取得
# 3. youtube-transcript-api で字幕取得（手動字幕優先）+ 前処理（重複/ノイズ除去）
# 4. claude -p + --json-schema で構造化要約生成
# 5. {{TRANSCRIPT}} placeholder を後処理で全文注入
# 6. テンプレートバリデーション + 修復パス
# 7. macOS通知で完了報告

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# ==================== ログ機構 ====================
LOG_DIR="${HOME}/Library/Logs/youtube-to-obsidian"
LOG_FILE="${LOG_DIR}/youtube-to-obsidian.log"

# ログディレクトリ作成 + symlink 攻撃防止
if [[ -L "$LOG_DIR" ]]; then
  echo "Error: $LOG_DIR is a symlink (possible attack)" >&2
  exit 1
fi
mkdir -p "$LOG_DIR"
chmod 700 "$LOG_DIR"

# ログローテーション（1MB超で .old にリネーム）
if [[ -f "$LOG_FILE" ]] && (( $(stat -f%z "$LOG_FILE" 2>/dev/null || echo 0) > 1048576 )); then
  mv "$LOG_FILE" "${LOG_FILE}.old"
fi

log() { print -r -- "[$(date +%H:%M:%S)] $*" >> "$LOG_FILE"; }

# ==================== 通知（osascript argv 方式） ====================
notify() {
  local title="$1" msg="$2" sound="${3:-Glass}"
  title=${title//$'\r'/ } ; title=${title//$'\n'/ }
  msg=${msg//$'\r'/ }     ; msg=${msg//$'\n'/ }
  /usr/bin/osascript -e 'on run argv
    set theTitle to item 1 of argv
    set theMsg to item 2 of argv
    set theSound to item 3 of argv
    display notification theMsg with title theTitle sound name theSound
  end run' -- "$title" "$msg" "$sound" >/dev/null 2>&1 || true
}

# ==================== 設定読み込み ====================
CONFIG_FILE="${HOME}/.config/youtube-to-obsidian/config"

if [[ ! -f "$CONFIG_FILE" ]]; then
  echo "Error: Config file not found: $CONFIG_FILE" >&2
  echo "Run install.sh or copy config.example to $CONFIG_FILE" >&2
  notify "YouTube→Obsidian" "設定ファイルが見つかりません。install.sh を実行してください。" "Basso"
  exit 1
fi

# Config ファイルの安全性検証（symlink + パーミッション）
if [[ -L "$CONFIG_FILE" ]]; then
  echo "Error: Config file must not be a symlink: $CONFIG_FILE" >&2
  exit 1
fi
local_perms=$(stat -f %Lp "$CONFIG_FILE" 2>/dev/null || echo "000")
if (( local_perms & 002 )); then
  echo "Error: Config file is world-writable (unsafe): $CONFIG_FILE" >&2
  exit 1
fi

source "$CONFIG_FILE"

# テンプレートファイル解決（config > リポジトリ相対）
if [[ -z "${TEMPLATE_FILE:-}" ]]; then
  TEMPLATE_FILE="$SCRIPT_DIR/../templates/youtube-summary-template.md"
fi

if [[ ! -f "$TEMPLATE_FILE" ]]; then
  echo "Error: Template file not found: $TEMPLATE_FILE" >&2
  exit 1
fi

# 必須設定の検証
if [[ -z "${VAULT_PATH:-}" || "$VAULT_PATH" == "/path/to/your/vault" ]]; then
  echo "Error: VAULT_PATH is not configured in $CONFIG_FILE" >&2
  notify "YouTube→Obsidian" "VAULT_PATH が未設定です。config を編集してください。" "Basso"
  exit 1
fi

if [[ ! -d "$VAULT_PATH" ]]; then
  echo "Error: VAULT_PATH does not exist: $VAULT_PATH" >&2
  notify "YouTube→Obsidian" "Vault が見つかりません" "Basso"
  exit 1
fi

SOURCE_FOLDER="${SOURCE_FOLDER:-Sources}"

# SOURCE_FOLDER のパストラバーサル防止
if [[ "$SOURCE_FOLDER" == *".."* ]]; then
  echo "Error: SOURCE_FOLDER must not contain '..': $SOURCE_FOLDER" >&2
  exit 1
fi

# PopClipなど非対話シェルからの起動時にPATHが不足するため明示的に追加
if [[ -n "${EXTRA_PATH:-}" ]]; then
  export PATH="${EXTRA_PATH}:$PATH"
fi
export USER="${USER:-$(whoami)}"
if [[ -z "${HOME:-}" ]]; then
  HOME=$(dscl . -read "/Users/$USER" NFSHomeDirectory 2>/dev/null | awk '{print $2}') || true
  [[ -z "$HOME" ]] && { echo "Error: HOME not set and cannot be resolved" >&2; exit 1; }
  export HOME
fi

# ==================== ユーティリティ ====================

# ファイル名サニタイズ（パストラバーサル防止）
sanitize_title() {
  local raw="$1" clean
  clean=$(printf '%s' "$raw" \
    | tr -d '\000' \
    | tr '\r\n' '  ' \
    | sed -E 's/[\/\\:*?"<>|]/ /g; s/[[:cntrl:]]//g; s/^[[:space:]]+|[[:space:]]+$//g; s/[[:space:]]+/ /g; s/\.\.//g')
  clean=${clean#.}
  [[ -z "$clean" || "$clean" == "." || "$clean" == ".." ]] && clean="youtube-${VIDEO_ID:-unknown}"
  printf '%s' "$clean"
}

# ノートパスが Vault 内に収まることを検証
validate_note_path() {
  local note_path="$1"
  local resolved
  resolved=$(cd "$(dirname "$note_path")" 2>/dev/null && pwd -P)/$(basename "$note_path")
  [[ "$resolved" == "${VAULT_PATH}"/* ]] || { log "ERROR: path escape detected: $resolved"; exit 1; }
}

# symlink を辿らない安全な書き込み
safe_write_note() {
  local src="$1" dst="$2"
  validate_note_path "$dst"
  if [[ -L "$dst" ]]; then
    log "ERROR: Refuse to write to symlink: $dst"
    exit 1
  fi
  cp "$src" "$dst"
}

is_youtube_url() {
  [[ "$1" =~ '^https?://(www\.)?(youtube\.com|youtu\.be)/' ]] || return 1
}

extract_video_id() {
  local url="$1"
  is_youtube_url "$url" || { echo ""; return; }
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

calc_timeout() {
  local n=$1
  local t=$((180 + n / 200))
  (( t < 180 )) && t=180
  (( t > 900 )) && t=900
  echo $t
}

validate_note() {
  local f="$1"
  local -a req=("### メタデータ" "### キーワード" "### 概要" "### タイムライン"
                 "### 詳細ノート" "### 発展の種" "### トランスクリプト")
  for h in "${req[@]}"; do
    grep -q "$h" "$f" || return 1
  done
}

create_skeleton() {
  mkdir -p "$(dirname "$NOTE_PATH")"
  local SKEL="$TMPDIR_WORK/skeleton.md"
  cat > "$SKEL" << SKELETON
- Source
---
${URL}

---

### メタデータ
- **タイトル**: ${TITLE}
- **チャンネル**: ${CHANNEL}
- **公開日**: ${UPLOAD_DATE_FMT}
- **長さ**: ${DURATION_STRING}
- **言語**: ${TRANSCRIPT_LANG}
- **文字起こし**: ${TRANSCRIPT_METHOD}
- **要約日**: ${TODAY}

---

### キーワード
\`未生成\`

---

### 概要
> [!warning] Claude による要約が失敗しました。\`/youtube ${URL}\` で再生成してください。

---

### タイムライン
> [!warning] 未生成

---

### 詳細ノート
> [!warning] 未生成

---

### 発展の種
> [!warning] 未生成

---

### トランスクリプト
> [!note]- 全文を表示
$(cat "$TMPDIR_WORK/transcript.cleaned.txt" 2>/dev/null | sed 's/^/> /' || echo "> 字幕なし")

SKELETON
  safe_write_note "$SKEL" "$NOTE_PATH"
  notify "YouTube→Obsidian" "スケルトンノートを作成しました" "Basso"
  log "Skeleton note created at $NOTE_PATH"
}

# ==================== ステージ: fetch ====================
stage_fetch() {
  log "Stage: fetch"

  # メタデータ取得
  log "Fetching metadata for $VIDEO_ID"
  if ! yt-dlp --dump-json --no-download "$URL" 2>/dev/null > "$TMPDIR_WORK/raw_meta.json"; then
    notify "YouTube→Obsidian" "メタデータ取得に失敗しました" "Basso"
    log "ERROR: yt-dlp failed for URL: $URL"
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

  log "Title: $TITLE | Channel: $CHANNEL"

  # 字幕取得 + 前処理（重複除去・ノイズ除去）
  log "Fetching transcript"
  python3 - "$VIDEO_ID" "$TMPDIR_WORK" << 'PYTHON_SCRIPT'
import sys
import json
import re
from youtube_transcript_api import YouTubeTranscriptApi

video_id = sys.argv[1]
tmpdir = sys.argv[2]

api = YouTubeTranscriptApi()
result = {"transcript": "", "method": "", "language": "", "error": ""}

try:
    transcript_list = api.list(video_id)

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

        # タイムスタンプ付きトランスクリプト構築
        raw_parts = []
        for snippet in fetched:
            minutes = int(snippet.start // 60)
            seconds = int(snippet.start % 60)
            timestamp = f"[{minutes:02d}:{seconds:02d}]"
            raw_parts.append(f"{timestamp} {snippet.text}")

        raw_text = "\n".join(raw_parts)
        result["transcript"] = raw_text
        result["method"] = method
        result["language"] = selected.language_code

        # --- 前処理: 重複除去 + ノイズ除去 ---
        noise_pattern = re.compile(
            r'^\[\d{2}:\d{2}\]\s*[\[\(]?\s*'
            r'(music|applause|laughter|silence|cheering|inaudible'
            r'|音楽|拍手|笑い|笑|沈黙)\s*[\]\)]?\s*$',
            re.IGNORECASE
        )

        lines = raw_text.split("\n")
        cleaned = []
        prev_text = None
        for line in lines:
            # タイムスタンプ部分を除いたテキストを取得
            text_match = re.match(r'\[\d{2}:\d{2}\]\s*(.*)', line)
            text = text_match.group(1).strip() if text_match else line.strip()

            # ノイズ行を除去
            if noise_pattern.match(line):
                continue

            # 完全重複行を除去（連続する同一テキスト）
            if text == prev_text:
                continue

            prev_text = text
            cleaned.append(line)

        # 前処理で全行除去された場合は元データにフォールバック
        if not cleaned:
            cleaned = lines

        cleaned_text = "\n".join(cleaned)

        with open(f"{tmpdir}/transcript.cleaned.txt", "w", encoding="utf-8") as f:
            f.write(cleaned_text)
    else:
        result["error"] = "字幕が見つかりませんでした"

except Exception as e:
    result["error"] = str(e)

with open(f"{tmpdir}/transcript.json", "w", encoding="utf-8") as f:
    json.dump(result, f, ensure_ascii=False, indent=2)
PYTHON_SCRIPT

  TRANSCRIPT_ERROR=$(jq -r '.error // ""' "$TMPDIR_WORK/transcript.json")
  if [[ -n "$TRANSCRIPT_ERROR" ]]; then
    NOTIFY_ERR=$(echo "$TRANSCRIPT_ERROR" | head -1 | cut -c1-80 | sed "s/[\"'\\\\]//g")
    notify "YouTube→Obsidian" "字幕取得失敗: ${NOTIFY_ERR}" "Basso"
    log "ERROR: Transcript fetch failed: $TRANSCRIPT_ERROR"
    exit 1
  fi

  TRANSCRIPT_METHOD=$(jq -r '.method' "$TMPDIR_WORK/transcript.json")
  TRANSCRIPT_LANG=$(jq -r '.language' "$TMPDIR_WORK/transcript.json")

  log "Transcript: $TRANSCRIPT_LANG ($TRANSCRIPT_METHOD), $(wc -c < "$TMPDIR_WORK/transcript.cleaned.txt" | tr -d ' ') bytes"

  # youtube-data.json 作成（transcript は含めない — 別ファイルで管理）
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
    '{
      url: $url,
      video_id: $video_id,
      title: $title,
      channel: $channel,
      upload_date: $upload_date,
      duration: $duration,
      transcript_language: $language,
      transcript_method: $method,
      today: $today
    }' > "$TMPDIR_WORK/youtube-data.json"
}

# ==================== ステージ: process ====================
stage_process() {
  log "Stage: process"

  local FULL_TRANSCRIPT="$TMPDIR_WORK/transcript.cleaned.txt"
  local INLINE_TRANSCRIPT="$TMPDIR_WORK/transcript.inline.txt"
  local MAX_INLINE=25000

  # ハイブリッド字幕戦略
  local tx_size
  tx_size=$(wc -c < "$FULL_TRANSCRIPT" | tr -d ' ')
  if (( tx_size > MAX_INLINE )); then
    head -c "$MAX_INLINE" "$FULL_TRANSCRIPT" > "$INLINE_TRANSCRIPT"
    log "Transcript: hybrid mode (${tx_size} bytes, inline: ${MAX_INLINE})"
  else
    cp "$FULL_TRANSCRIPT" "$INLINE_TRANSCRIPT"
    log "Transcript: inline mode (${tx_size} bytes)"
  fi

  # プロンプトファイル構築
  PROMPT_FILE="$TMPDIR_WORK/prompt.txt"
  {
    cat << 'PROMPT_HEADER'
あなたはObsidian Sourceノート作成アシスタントです。

## 指示
- 動画データとトランスクリプトを読み、テンプレート通りのMarkdownノートを生成してください
- トランスクリプトセクションには `{{TRANSCRIPT}}` プレースホルダーのみ出力してください（後処理で全文を挿入します）
- 出力はJSONの "note" フィールドにMarkdown本文のみを格納してください
- 動画の言語に関わらず、要約は日本語で記述
- 話者の意見と事実を区別する（「〜と主張している」vs「〜である」）
- 見出しは ### (h3) から開始
- [[wikilink]] は新設しない。重要な概念・用語は **太字** で表現する
- キーワードセクション: 動画の主要なキーワード・重要概念をインラインコード形式で列挙
- タイムラインセクション: 各項目は ##### 見出し（h5）でトピックタイトル + タイムスタンプリンク、次行に要約
  - タイムスタンプは [MM:SS](https://youtu.be/{video_id}?t={seconds}) 形式のYouTubeリンク
  - 秒数計算: MM*60+SS（例: [02:15] → t=135）
  - video_id は動画データの video_id フィールドを使用
- 発展の種セクション: アイデア出し・記事ネタ転用向け。太字キーワード + 端的な要素説明（3-5個）

PROMPT_HEADER

    echo "## テンプレート"
    cat "$TEMPLATE_FILE"

    echo ""
    echo "## 動画データ"
    cat "$TMPDIR_WORK/youtube-data.json"

    echo ""
    echo "## トランスクリプト（要約用）"
    cat "$INLINE_TRANSCRIPT"

    # 長い字幕の場合、Read参照を促す
    if (( tx_size > MAX_INLINE )); then
      echo ""
      echo "（注意: トランスクリプトは先頭${MAX_INLINE}文字のみです。全文が必要な場合は $FULL_TRANSCRIPT を Read ツールで参照してください）"
    fi
  } > "$PROMPT_FILE"

  log "Prompt file: $(wc -c < "$PROMPT_FILE" | tr -d ' ') bytes"

  # タイムアウト計算（動的: 字幕長に応じて 180-900 秒）
  CLAUDE_TIMEOUT=$(calc_timeout "$tx_size")
  log "Timeout: ${CLAUDE_TIMEOUT}s"
}

# ==================== ステージ: generate ====================
stage_generate() {
  log "Stage: generate"

  local CLAUDE_RAW="$TMPDIR_WORK/claude_output.raw"
  local FULL_TRANSCRIPT="$TMPDIR_WORK/transcript.cleaned.txt"
  local DRAFT="$TMPDIR_WORK/note.draft.md"
  local FINAL="$TMPDIR_WORK/note.final.md"
  local SCHEMA='{"type":"object","properties":{"note":{"type":"string"}},"required":["note"]}'

  # claude -p 実行（バックグラウンド + watchdog）
  set +e
  (
    CLAUDECODE= claude -p < "$PROMPT_FILE" \
      --output-format json \
      --json-schema "$SCHEMA" \
      --tools "Read" \
      --add-dir "$TMPDIR_WORK" \
      > "$CLAUDE_RAW" 2>> "$LOG_FILE"
  ) &
  local CLAUDE_PID=$!

  (
    sleep "$CLAUDE_TIMEOUT"
    if kill -0 "$CLAUDE_PID" 2>/dev/null; then
      log "TIMEOUT: killing claude (PID $CLAUDE_PID) after ${CLAUDE_TIMEOUT}s"
      kill "$CLAUDE_PID" 2>/dev/null
      sleep 5
      kill -0 "$CLAUDE_PID" 2>/dev/null && kill -9 "$CLAUDE_PID" 2>/dev/null
    fi
  ) &
  local WATCHDOG_PID=$!

  wait "$CLAUDE_PID" 2>/dev/null
  local CLAUDE_EXIT=$?

  kill "$WATCHDOG_PID" 2>/dev/null
  wait "$WATCHDOG_PID" 2>/dev/null
  set -e

  if [[ $CLAUDE_EXIT -ne 0 ]]; then
    log "WARN: claude -p exited with code $CLAUDE_EXIT"
  fi

  # デバッグ出力（DEBUG=1 でのみ保存、7日で自動削除）
  if [[ "${DEBUG:-}" == "1" ]]; then
    local DEBUG_DIR="${HOME}/.config/youtube-to-obsidian/debug"
    mkdir -p "$DEBUG_DIR"
    cp "$CLAUDE_RAW" "$DEBUG_DIR/${RUN_ID}.raw" 2>/dev/null || true
    jq -r 'keys' "$CLAUDE_RAW" >> "$LOG_FILE" 2>/dev/null || true
    # 7日以上前のデバッグファイルを削除
    find "$DEBUG_DIR" -name "*.raw" -mtime +7 -delete 2>/dev/null || true
  fi

  # JSON からノート本文を抽出（multi-path jq）
  local note=""
  local EXTRACT_OK=false

  if [[ -f "$CLAUDE_RAW" ]] && [[ -s "$CLAUDE_RAW" ]]; then
    # multi-path jq: structured_output のネスト変動に対応
    note=$(jq -r '
      [
        .note?,
        (.result | if type=="object" then .note? else empty end),
        (.structured_output | if type=="object" then .note? else empty end),
        (.result | if type=="object" then (.structured_output | if type=="object" then .note? else empty end) else empty end),
        (.structured_output | if type=="string" then . else empty end),
        (.result | if type=="object" then (.structured_output | if type=="string" then . else empty end) else empty end)
      ] | map(select(type=="string" and length>0)) | .[0] // empty
    ' "$CLAUDE_RAW" 2>/dev/null) || true

    if [[ -n "${note:-}" ]]; then
      echo "$note" > "$DRAFT"
      EXTRACT_OK=true
      log "Extract: multi-path jq OK"
    fi

    # テキスト fallback: raw output に見出し構造が含まれるか確認
    if [[ "$EXTRACT_OK" != true ]]; then
      if grep -q "### メタデータ" "$CLAUDE_RAW" 2>/dev/null; then
        cp "$CLAUDE_RAW" "$DRAFT"
        EXTRACT_OK=true
        log "Extract: raw text heading fallback"
      fi
    fi
  fi

  if [[ "$EXTRACT_OK" != true ]]; then
    log "ERROR: Failed to extract note from claude output"
    return 1
  fi

  # テンプレートバリデーション（placeholder 差し込み前）
  if validate_note "$DRAFT"; then
    log "Validation: PASS (7 sections)"
  else
    log "WARN: Validation failed on draft, running repair pass"

    local REPAIR_PROMPT="$TMPDIR_WORK/repair_prompt.txt"
    {
      cat << 'REPAIR_HEADER'
以下のObsidianノートにはテンプレートの必須セクションが不足しています。
不足セクションを追加して、完全なノートをJSONの "note" フィールドに出力してください。
トランスクリプトセクションには {{TRANSCRIPT}} プレースホルダーを維持してください。

必須セクション: ### メタデータ, ### キーワード, ### 概要, ### タイムライン, ### 詳細ノート, ### 発展の種, ### トランスクリプト

現在のノート:
REPAIR_HEADER
      cat "$DRAFT"
    } > "$REPAIR_PROMPT"

    local REPAIR_RAW="$TMPDIR_WORK/repair_output.raw"

    set +e
    CLAUDECODE= claude -p < "$REPAIR_PROMPT" \
      --output-format json \
      --json-schema "$SCHEMA" \
      > "$REPAIR_RAW" 2>> "$LOG_FILE"
    set -e

    # 修復出力からも multi-path jq で抽出
    local repair_note=""
    repair_note=$(jq -r '
      [
        .note?,
        (.result | if type=="object" then .note? else empty end),
        (.structured_output | if type=="object" then .note? else empty end),
        (.result | if type=="object" then (.structured_output | if type=="object" then .note? else empty end) else empty end),
        (.structured_output | if type=="string" then . else empty end),
        (.result | if type=="object" then (.structured_output | if type=="string" then . else empty end) else empty end)
      ] | map(select(type=="string" and length>0)) | .[0] // empty
    ' "$REPAIR_RAW" 2>/dev/null) || true

    if [[ -n "${repair_note:-}" ]]; then
      echo "$repair_note" > "$DRAFT"
      if validate_note "$DRAFT"; then
        log "Repair: PASS"
      else
        log "WARN: Repair validation still failed, proceeding with best effort"
      fi
    else
      log "WARN: Repair claude call failed, proceeding with original draft"
    fi
  fi

  # {{TRANSCRIPT}} placeholder 差し込み
  python3 - "$DRAFT" "$FULL_TRANSCRIPT" "$FINAL" << 'TRANSCRIPT_PY'
import sys

note = open(sys.argv[1], encoding="utf-8").read()
tx = open(sys.argv[2], encoding="utf-8").read().splitlines()

callout_lines = ["> [!note]- 全文を表示"]
callout_lines.extend(["> " + line for line in tx])
block = "\n".join(callout_lines)

if "{{TRANSCRIPT}}" in note:
    result = note.replace("{{TRANSCRIPT}}", block)
elif "### トランスクリプト" in note:
    # placeholder が無いがセクションはある → セクション末尾にcalloutを追加
    idx = note.find("### トランスクリプト")
    end_of_line = note.find("\n", idx)
    if end_of_line == -1:
        end_of_line = len(note)
    result = note[:end_of_line + 1] + block + "\n"
    # セクション後の残りがあれば付加
    rest = note[end_of_line + 1:].lstrip("\n")
    if rest:
        result += "\n" + rest
else:
    # セクション自体が無い → 末尾に追加
    result = note.rstrip() + "\n\n---\n\n### トランスクリプト\n" + block + "\n"

open(sys.argv[3], "w", encoding="utf-8").write(result)
TRANSCRIPT_PY

  log "Transcript placeholder: replaced ($(wc -c < "$FINAL" | tr -d ' ') bytes)"
}

# ==================== ステージ: save ====================
stage_save() {
  log "Stage: save"

  local FINAL="$TMPDIR_WORK/note.final.md"

  if [[ -f "$FINAL" ]] && [[ -s "$FINAL" ]]; then
    mkdir -p "$(dirname "$NOTE_PATH")"
    safe_write_note "$FINAL" "$NOTE_PATH"
    local safe_msg
    safe_msg=$(echo "$SAFE_TITLE" | head -c 60 | sed "s/[\"'\\\\]//g")
    notify "YouTube→Obsidian ✓" "$safe_msg"
    log "SUCCESS: Note saved to $NOTE_PATH"
  else
    log "WARN: No valid note generated, creating skeleton"
    create_skeleton
  fi
}

# ==================== メイン ====================
main() {
  URL="${1:-}"

  if [[ -z "$URL" ]]; then
    echo "Usage: $0 <YouTube URL>" >&2
    exit 1
  fi

  VIDEO_ID=$(extract_video_id "$URL")
  if [[ -z "$VIDEO_ID" ]]; then
    notify "YouTube→Obsidian" "無効なYouTube URLです" "Basso"
    echo "Error: Could not extract video_id from URL: $URL" >&2
    exit 1
  fi

  RUN_ID="$(date +%Y%m%d-%H%M%S)-$VIDEO_ID"
  log "========== START: $URL (run: $RUN_ID) =========="

  TMPDIR_WORK=$(mktemp -d /tmp/youtube-to-obsidian.XXXXXX)
  trap 'rm -rf "$TMPDIR_WORK"' EXIT

  # 開始通知
  notify "YouTube→Obsidian" "処理開始: $VIDEO_ID"

  # --- fetch ---
  stage_fetch

  # ノートパス準備
  SAFE_TITLE=$(sanitize_title "$TITLE")
  NOTE_PATH="${VAULT_PATH}/${SOURCE_FOLDER}/${SAFE_TITLE}.md"
  mkdir -p "$(dirname "$NOTE_PATH")"
  validate_note_path "$NOTE_PATH"

  # 既存ノートチェック
  if [[ -f "$NOTE_PATH" ]]; then
    notify "YouTube→Obsidian" "既にノートが存在します" "Basso"
    log "SKIP: Note already exists at $NOTE_PATH"
    exit 0
  fi

  # --- process ---
  stage_process

  # --- generate（失敗時はスケルトンで救済）---
  if ! stage_generate; then
    log "WARN: stage_generate failed, falling back to skeleton"
    create_skeleton
    log "========== END: $URL (run: $RUN_ID) [skeleton] =========="
    exit 0
  fi

  # --- save ---
  stage_save

  log "========== END: $URL (run: $RUN_ID) =========="
}

main "$@"
