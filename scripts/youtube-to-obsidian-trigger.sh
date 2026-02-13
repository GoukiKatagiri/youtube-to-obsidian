#!/bin/zsh
# アクティブブラウザのURLを取得して youtube-to-obsidian.sh に渡す
# キーボードショートカット（Shortcuts.app / Automator）から呼び出す想定

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BROWSER=$(osascript -e 'tell application "System Events" to get name of first application process whose frontmost is true')

case "$BROWSER" in
  Safari)
    URL=$(osascript -e 'tell application "Safari" to return URL of front document')
    ;;
  Dia)
    # Dia は Chromium ベースだが AppleScript の構文が独自
    URL=$(osascript -e 'tell application "Dia" to get URL of tab 1 of window 1')
    ;;
  "Google Chrome"|Arc|Brave*|Vivaldi|"Microsoft Edge")
    URL=$(osascript -e "tell application \"$BROWSER\" to return URL of active tab of front window")
    ;;
  *)
    osascript -e "display notification \"未対応ブラウザ: $BROWSER\" with title \"YouTube→Obsidian\" sound name \"Basso\""
    exit 1
    ;;
esac

# YouTube URL チェック
if [[ ! "$URL" =~ (youtube\.com|youtu\.be) ]]; then
  osascript -e "display notification \"YouTube URLではありません\" with title \"YouTube→Obsidian\" sound name \"Basso\""
  exit 1
fi

# メインスクリプトを非同期実行
nohup "$SCRIPT_DIR/youtube-to-obsidian.sh" "$URL" > /tmp/youtube-to-obsidian.log 2>&1 &
