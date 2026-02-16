#!/bin/zsh
# アクティブブラウザのURLを取得して youtube-to-obsidian.sh に渡す
# キーボードショートカット（BTT / Shortcuts.app / Automator）から呼び出す想定

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

log() { print -r -- "[trigger $(date +%H:%M:%S)] $*" >> /tmp/youtube-to-obsidian.log; }

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
      osascript -e "try
        tell application \"$browser\" to return URL of active tab of front window
      on error
        return \"\"
      end try" 2>/dev/null ;;
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
  if [[ "$clip" =~ (youtube\.com|youtu\.be) ]]; then
    URL="$clip"
  fi
fi

log "BROWSER=${BROWSER:-<none>} URL=${URL:-<empty>}"

# ==================== URL バリデーション ====================
if [[ -z "$URL" ]]; then
  osascript -e 'display notification "ブラウザからURLを取得できませんでした" with title "YouTube→Obsidian" sound name "Basso"'
  exit 1
fi

if [[ ! "$URL" =~ (youtube\.com|youtu\.be) ]]; then
  osascript -e 'display notification "YouTube URLではありません" with title "YouTube→Obsidian" sound name "Basso"'
  exit 1
fi

# 処理開始通知
osascript -e "display notification \"処理開始: ${URL}\" with title \"YouTube→Obsidian\""

# メインスクリプトを非同期実行
# nohup ではなく & disown を使用: Automator Quick Action 経由の nohup は
# 通知センターとのセッション接続が切れ、osascript display notification が表示されない
"$SCRIPT_DIR/youtube-to-obsidian.sh" "$URL" >> /tmp/youtube-to-obsidian.log 2>&1 &
disown
