#!/bin/zsh
# アクティブブラウザのURLを取得して youtube-to-obsidian.sh に渡す
# キーボードショートカット（BTT / Shortcuts.app / Automator）から呼び出す想定

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

LOG_DIR="${HOME}/Library/Logs/youtube-to-obsidian"
[[ -L "$LOG_DIR" ]] && { echo "Error: $LOG_DIR is a symlink" >&2; exit 1; }
mkdir -p "$LOG_DIR" && chmod 700 "$LOG_DIR"
LOG_FILE="${LOG_DIR}/youtube-to-obsidian.log"

log() { print -r -- "[trigger $(date +%H:%M:%S)] $*" >> "$LOG_FILE"; }

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

# ==================== ブラウザ URL 取得関数 ====================
get_url_from_browser() {
  local browser="$1"
  case "$browser" in
    Safari)
      osascript -e 'try
        tell application "Safari" to return URL of front document
      on error
        return ""
      end try' 2>/dev/null ;;
    Dia)
      osascript -e 'try
        tell application "Dia" to get URL of tab 1 of window 1
      on error
        return ""
      end try' 2>/dev/null ;;
    "Google Chrome"|Arc|Brave*|Vivaldi|"Microsoft Edge")
      /usr/bin/osascript -e 'on run argv
        set browserName to item 1 of argv
        try
          tell application browserName to return URL of active tab of front window
        on error
          return ""
        end try
      end run' -- "$browser" 2>/dev/null ;;
    *)
      echo "" ;;
  esac
}

# ==================== フロントモスト検出 ====================
BROWSER=$(osascript -e 'tell application "System Events" to get name of first application process whose frontmost is true' 2>/dev/null)

# 自動化ツールがフロントモストの場合はスキップ
case "${BROWSER:-}" in
  BetterTouchTool|Shortcuts|Raycast|Automator|"Keyboard Maestro")
    BROWSER="" ;;
esac

URL=""
if [[ -n "${BROWSER:-}" ]]; then
  for i in {1..3}; do
    URL=$(get_url_from_browser "$BROWSER")
    [[ -n "$URL" ]] && break
    sleep 0.2
  done
fi

# フォールバック: 主要ブラウザを順次探索
if [[ -z "$URL" ]]; then
  for b in Dia Safari "Google Chrome" Arc; do
    URL=$(get_url_from_browser "$b")
    [[ -n "$URL" ]] && break
  done
fi

# 最終フォールバック: クリップボード（YouTube URL のみ受け入れ）
if [[ -z "$URL" ]]; then
  clip=$(pbpaste | tr -d '\r' | head -n1)
  if [[ "$clip" =~ '^https?://(www\.)?(youtube\.com/(watch|shorts|live)|youtu\.be/)' ]]; then
    URL="$clip"
  fi
fi

log "BROWSER=${BROWSER:-<none>} URL=${URL:-<empty>}"

# ==================== URL バリデーション ====================
if [[ -z "$URL" ]]; then
  notify "YouTube→Obsidian" "ブラウザからURLを取得できませんでした" "Basso"
  exit 1
fi

if [[ ! "$URL" =~ (youtube\.com|youtu\.be) ]]; then
  notify "YouTube→Obsidian" "YouTube URLではありません" "Basso"
  exit 1
fi

# 処理開始通知
notify "YouTube→Obsidian" "処理開始"

# メインスクリプトを非同期実行
# nohup ではなく & disown を使用: Automator Quick Action 経由の nohup は
# 通知センターとのセッション接続が切れ、osascript display notification が表示されない
"$SCRIPT_DIR/youtube-to-obsidian.sh" "$URL" >> "$LOG_FILE" 2>&1 &
disown
