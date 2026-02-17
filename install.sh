#!/bin/bash
# YouTube to Obsidian インストールスクリプト
set -euo pipefail

# macOS 専用ツール
if [[ "$(uname)" != "Darwin" ]]; then
  echo "Error: This tool requires macOS" >&2
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# 色付き出力
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

info()  { echo -e "${GREEN}[✓]${NC} $1"; }
warn()  { echo -e "${YELLOW}[!]${NC} $1"; }
error() { echo -e "${RED}[✗]${NC} $1"; }

echo "=== YouTube to Obsidian Installer ==="
echo ""

# --- 1. 依存ツールの確認 ---
echo "Checking dependencies..."
MISSING=()

for cmd in yt-dlp jq claude; do
  if command -v "$cmd" &>/dev/null; then
    info "$cmd found: $(command -v "$cmd")"
  else
    error "$cmd not found"
    MISSING+=("$cmd")
  fi
done

# python3 + youtube-transcript-api
if command -v python3 &>/dev/null; then
  info "python3 found: $(command -v python3)"
  if python3 -c "import youtube_transcript_api" 2>/dev/null; then
    info "youtube-transcript-api installed"
  else
    error "youtube-transcript-api not found"
    MISSING+=("youtube-transcript-api")
  fi
else
  error "python3 not found"
  MISSING+=("python3")
fi

if [[ ${#MISSING[@]} -gt 0 ]]; then
  echo ""
  warn "Missing dependencies: ${MISSING[*]}"
  echo ""
  echo "Install them with:"
  for dep in "${MISSING[@]}"; do
    case "$dep" in
      yt-dlp)
        echo "  brew install yt-dlp"
        ;;
      jq)
        echo "  brew install jq"
        ;;
      claude)
        echo "  npm install -g @anthropic-ai/claude-code"
        ;;
      python3)
        echo "  brew install python3"
        ;;
      youtube-transcript-api)
        echo "  pip install youtube-transcript-api"
        ;;
    esac
  done
  echo ""
  read -p "Continue anyway? [y/N] " -n 1 -r
  echo ""
  if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    exit 1
  fi
fi

echo ""

# --- 2. 設定ファイルの作成 ---
CONFIG_DIR="${HOME}/.config/youtube-to-obsidian"
CONFIG_FILE="${CONFIG_DIR}/config"

if [[ -f "$CONFIG_FILE" ]]; then
  info "Config already exists: $CONFIG_FILE"
else
  mkdir -p "$CONFIG_DIR"
  cp "$SCRIPT_DIR/config.example" "$CONFIG_FILE"
  info "Config created: $CONFIG_FILE"

  echo ""
  echo "Please enter your Obsidian Vault path."

  # macOS iCloud のデフォルトパスを候補として表示
  ICLOUD_BASE="$HOME/Library/Mobile Documents/iCloud~md~obsidian/Documents"
  if [[ -d "$ICLOUD_BASE" ]]; then
    echo "Detected iCloud vaults:"
    ls -1 "$ICLOUD_BASE" 2>/dev/null | while read -r v; do
      echo "  $ICLOUD_BASE/$v"
    done
    echo ""
  fi

  read -p "VAULT_PATH: " VAULT_INPUT
  if [[ -n "$VAULT_INPUT" ]]; then
    # チルダ展開
    VAULT_INPUT="${VAULT_INPUT/#\~/$HOME}"
    sed -i '' "s|VAULT_PATH=\"/path/to/your/vault\"|VAULT_PATH=\"${VAULT_INPUT}\"|" "$CONFIG_FILE"
    info "VAULT_PATH set to: $VAULT_INPUT"
  else
    warn "VAULT_PATH not set. Edit $CONFIG_FILE manually."
  fi

  read -p "SOURCE_FOLDER (default: Sources): " SOURCE_INPUT
  if [[ -n "$SOURCE_INPUT" ]]; then
    sed -i '' "s|SOURCE_FOLDER=\"Sources\"|SOURCE_FOLDER=\"${SOURCE_INPUT}\"|" "$CONFIG_FILE"
    info "SOURCE_FOLDER set to: $SOURCE_INPUT"
  fi
fi

echo ""

# --- 3. scripts/ を ~/.claude/scripts/ にコピー ---
CLAUDE_SCRIPTS_DIR="${HOME}/.claude/scripts"
mkdir -p "$CLAUDE_SCRIPTS_DIR"

cp "$SCRIPT_DIR/scripts/youtube-to-obsidian.sh" "$CLAUDE_SCRIPTS_DIR/"
chmod +x "$CLAUDE_SCRIPTS_DIR/youtube-to-obsidian.sh"
info "Script installed: $CLAUDE_SCRIPTS_DIR/youtube-to-obsidian.sh"

cp "$SCRIPT_DIR/scripts/youtube-to-obsidian-trigger.sh" "$CLAUDE_SCRIPTS_DIR/"
chmod +x "$CLAUDE_SCRIPTS_DIR/youtube-to-obsidian-trigger.sh"
info "Trigger script installed: $CLAUDE_SCRIPTS_DIR/youtube-to-obsidian-trigger.sh"

# PopClip拡張をコピーし、スクリプトパスを実パスに埋め込む
POPCLIP_SRC="$SCRIPT_DIR/scripts/youtube-to-obsidian.popcliptxt"
POPCLIP_DST="$CLAUDE_SCRIPTS_DIR/youtube-to-obsidian.popcliptxt"
cp "$POPCLIP_SRC" "$POPCLIP_DST"

# $HOME が PopClip YAML で展開されないため、実際のパスに置換
ACTUAL_SCRIPT_PATH="$CLAUDE_SCRIPTS_DIR/youtube-to-obsidian.sh"
sed -i '' "s|\"\\\$HOME/.claude/scripts/youtube-to-obsidian.sh\"|\"${ACTUAL_SCRIPT_PATH}\"|" "$POPCLIP_DST"
info "PopClip extension installed: $POPCLIP_DST"

echo ""

# --- 4. commands/ を ~/.claude/commands/ にコピー ---
CLAUDE_COMMANDS_DIR="${HOME}/.claude/commands"
mkdir -p "$CLAUDE_COMMANDS_DIR"

cp "$SCRIPT_DIR/commands/youtube.md" "$CLAUDE_COMMANDS_DIR/"
info "Slash command installed: $CLAUDE_COMMANDS_DIR/youtube.md"

echo ""

# --- 5. templates/ を skills ディレクトリにコピー ---
SKILLS_REF_DIR="${HOME}/.claude/skills/obsidian-note-management/references"
if [[ -d "$SKILLS_REF_DIR" ]]; then
  cp "$SCRIPT_DIR/templates/youtube-summary-template.md" "$SKILLS_REF_DIR/"
  info "Template installed: $SKILLS_REF_DIR/youtube-summary-template.md"
else
  warn "Skills directory not found: $SKILLS_REF_DIR"
  echo "  Template is available at: $SCRIPT_DIR/templates/youtube-summary-template.md"
  echo "  You can manually copy it or reference it from your Claude Code setup."
fi

echo ""

# --- 6. セットアップ完了 + キーボードショートカット案内 ---
echo "=== Setup Complete ==="
echo ""
echo "=== キーボードショートカットの設定（推奨） ==="
echo ""
echo "ブラウザでYouTube動画を開いた状態でホットキー1つで実行できます。"
echo ""
echo "A. macOS ショートカット.app（推奨）:"
echo "   1. ショートカット.app を開く"
echo "   2. 新規ショートカットを作成"
echo "   3. 「シェルスクリプトを実行」アクションを追加"
echo "   4. スクリプト: $CLAUDE_SCRIPTS_DIR/youtube-to-obsidian-trigger.sh"
echo "   5. 詳細 (i) > キーボードショートカットを追加 > 任意のキー設定"
echo ""
echo "B. Automator Quick Action:"
echo "   1. Automator.app で「クイックアクション」を新規作成"
echo "   2. 「入力なし」「すべてのアプリケーション」に設定"
echo "   3. 「シェルスクリプトを実行」を追加"
echo "   4. スクリプト: $CLAUDE_SCRIPTS_DIR/youtube-to-obsidian-trigger.sh"
echo "   5. 保存後、System Settings > Keyboard > Keyboard Shortcuts > Services でショートカット割り当て"
echo ""
echo "=== その他の起動方法 ==="
echo ""
echo "PopClip extension:"
echo "  open \"$POPCLIP_DST\""
echo ""
echo "Slash Command in Claude Code:"
echo "  /youtube <YouTube URL>"
echo ""
echo "Command line:"
echo "  ~/.claude/scripts/youtube-to-obsidian.sh <YouTube URL>"
echo ""
if [[ ! -f "$CONFIG_FILE" ]] || grep -q '/path/to/your/vault' "$CONFIG_FILE" 2>/dev/null; then
  warn "Don't forget to set VAULT_PATH in $CONFIG_FILE"
fi
