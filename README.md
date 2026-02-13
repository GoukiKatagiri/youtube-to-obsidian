# YouTube to Obsidian

YouTube動画をAIで分析し、Obsidian Vaultに**知識ノート**として自動保存するツール。単なる要約ではなく、キーワード抽出・タイムライン・発展の種（派生ノート候補）を含む、PKMに統合可能なSource型ノートを生成する。

キーボードショートカット / PopClip / Claude Code Slash Command / シェルから起動できる。

## なぜこのツール？

YouTube動画の「要約ツール」は多数存在するが、このツールは**知識管理（PKM）への統合**を前提に設計されている:

| 観点 | 一般的な要約ツール | YouTube to Obsidian |
|---|---|---|
| 出力先 | ブラウザ上 / クリップボード | Obsidian Vault に直接保存 |
| 構造 | 箇条書きの要約 | メタデータ・キーワード・タイムライン・発展の種を含むSource型ノート |
| リンク | なし | `[[wikilink]]` で既存ノートと接続 |
| タイムライン | なし or テキスト | YouTubeリンク付きタイムスタンプで動画の該当箇所に直接ジャンプ |
| 発展性 | 見て終わり | 「発展の種」が次のノート作成を促す |
| 実行環境 | クラウド（データ送信） | ローカル実行（Claude Code） |
| 起動方法 | ブラウザ拡張 | ホットキー1つで全自動 |

## アーキテクチャ

```
YouTube URL
    │
    ├── キーボードショートカット ──┐
    ├── PopClip                  │
    ├── /youtube URL             │
    └── シェル直接実行            │
                                 ▼
┌──────────────────────────────────────────┐
│  youtube-to-obsidian-trigger.sh          │
│  (ブラウザからURL自動取得)                │
└──────────────┬───────────────────────────┘
               ▼
┌──────────────────────────────────────────┐
│  youtube-to-obsidian.sh                  │
│                                          │
│  1. yt-dlp      → メタデータ             │
│  2. transcript  → タイムスタンプ付き字幕  │
│  3. claude -p   → 要約生成               │
│  4. Write       → ノート作成             │
└──────────────────────────────────────────┘
               ▼
Obsidian Vault
└── {SOURCE_FOLDER}/
    └── {動画タイトル}.md
```

## デモ

生成されるノートのサンプル:

```markdown
- Source
---
https://www.youtube.com/watch?v=example

---

### メタデータ
- **タイトル**: Example Video Title
- **チャンネル**: Example Channel
- **公開日**: 2025-01-15
- **長さ**: 12:34
- **言語**: ja
- **文字起こし**: 手動字幕
- **要約日**: 2025-01-20

---

### キーワード
`キーワード1` `キーワード2` `キーワード3`

---

### 概要
この動画は〜について解説し、〜という結論を示している。

---

### タイムライン
- [00:00](https://youtu.be/example?t=0) **導入** — 動画の目的と背景を説明
- [02:15](https://youtu.be/example?t=135) **ポイント1** — 内容の説明 → [[関連ノート]]
- [05:30](https://youtu.be/example?t=330) **ポイント2** — 内容の説明
- ...

---

### 詳細ノート
...

---

### 発展の種
- [[候補ノート名]] — 説明（Concept型）

---

### トランスクリプト
> [!note]- 全文を表示
> [00:00] トランスクリプト全文がここに格納される
> [00:15] タイムスタンプ付きで表示
> ...
```

## 導入方法

### A. Claude Code で導入（推奨）

Claude Code に以下のプロンプトを貼るだけで導入できます:

```
このリポジトリのYouTube→Obsidianツールを自分の環境に導入してください:
https://github.com/GoukiKatagiri/youtube-to-obsidian

1. リポジトリをクローンして install.sh を実行
2. 設定ファイルの VAULT_PATH を自分のVaultに設定
3. 導入結果を報告
```

### B. install.sh で導入

```bash
# 1. リポジトリをクローン
gh repo clone GoukiKatagiri/youtube-to-obsidian /tmp/youtube-to-obsidian

# 2. インストールスクリプトを実行
/tmp/youtube-to-obsidian/install.sh

# 3. クリーンアップ
rm -rf /tmp/youtube-to-obsidian
```

### C. 手動導入

```bash
# 1. リポジトリをクローン
gh repo clone GoukiKatagiri/youtube-to-obsidian /tmp/youtube-to-obsidian

# 2. 設定ファイルを配置
mkdir -p ~/.config/youtube-to-obsidian
cp /tmp/youtube-to-obsidian/config.example ~/.config/youtube-to-obsidian/config
# config を編集して VAULT_PATH を設定

# 3. スクリプトをコピー
mkdir -p ~/.claude/scripts
cp /tmp/youtube-to-obsidian/scripts/youtube-to-obsidian.sh ~/.claude/scripts/
cp /tmp/youtube-to-obsidian/scripts/youtube-to-obsidian-trigger.sh ~/.claude/scripts/
chmod +x ~/.claude/scripts/youtube-to-obsidian.sh
chmod +x ~/.claude/scripts/youtube-to-obsidian-trigger.sh

# 4. PopClip拡張をコピー（PopClip使用時のみ）
cp /tmp/youtube-to-obsidian/scripts/youtube-to-obsidian.popcliptxt ~/.claude/scripts/
# PopClip拡張内のスクリプトパスを自分の環境に合わせて編集

# 5. Slash Commandをコピー（Claude Code使用時のみ）
mkdir -p ~/.claude/commands
cp /tmp/youtube-to-obsidian/commands/youtube.md ~/.claude/commands/

# 6. テンプレートをコピー（任意）
# obsidian-note-management スキルを使っている場合:
cp /tmp/youtube-to-obsidian/templates/youtube-summary-template.md \
   ~/.claude/skills/obsidian-note-management/references/

# 7. クリーンアップ
rm -rf /tmp/youtube-to-obsidian
```

## 設定

設定ファイル: `~/.config/youtube-to-obsidian/config`

```bash
# Obsidian Vault のルートパス
VAULT_PATH="/path/to/your/vault"

# Source型ノートの保存先（Vaultルートからの相対パス）
SOURCE_FOLDER="Sources"

# 追加のPATH（pyenvやHomebrewのパスなど）
EXTRA_PATH="/opt/homebrew/bin"
```

| 変数 | 説明 | 必須 |
|---|---|---|
| `VAULT_PATH` | Obsidian Vaultのルートパス | Yes |
| `SOURCE_FOLDER` | ノート保存先のサブフォルダ（デフォルト: `Sources`） | No |
| `EXTRA_PATH` | 非対話シェルで必要な追加PATH | No |

## 使い方

### キーボードショートカットから（推奨）

ブラウザでYouTube動画を開いた状態で、設定したショートカットキーを押すだけ。URL取得からノート作成まで自動で実行される。

設定方法は下記「キーボードショートカットの設定」を参照。

### `/youtube` Slash Command から

Claude Code 内で:

```
/youtube https://www.youtube.com/watch?v=xxxxx
```

対話的に実行されるため、エラー時に字幕の選択肢を相談できる。

### PopClip から

1. ブラウザでYouTube URLを選択
2. PopClipメニューから「YouTube→Obsidian」をクリック
3. macOS通知で完了が報告される

### シェルから直接実行

```bash
~/.claude/scripts/youtube-to-obsidian.sh "https://www.youtube.com/watch?v=xxxxx"
```

## キーボードショートカットの設定

### A. macOS ショートカット.app（推奨）

1. **ショートカット.app** を開く
2. **新規ショートカット** を作成
3. **「シェルスクリプトを実行」** アクションを追加
4. スクリプトに以下を入力:
   ```
   ~/.claude/scripts/youtube-to-obsidian-trigger.sh
   ```
5. 右上の **詳細 (i)** > **キーボードショートカットを追加** > 任意のキーを設定

### B. Automator Quick Action

1. **Automator.app** で「クイックアクション」を新規作成
2. ワークフローが受け取る現在の項目: **入力なし**、検索対象: **すべてのアプリケーション**
3. **「シェルスクリプトを実行」** アクションを追加
4. スクリプトに以下を入力:
   ```
   ~/.claude/scripts/youtube-to-obsidian-trigger.sh
   ```
5. 名前を付けて保存（例: `YouTube to Obsidian`）
6. **System Settings** > **Keyboard** > **Keyboard Shortcuts** > **Services** でショートカットを割り当て

### 対応ブラウザ

| ブラウザ | 対応状況 |
|---|---|
| Safari | OK |
| Google Chrome | OK |
| Arc | OK |
| Dia | OK |
| Brave | OK |
| Vivaldi | OK |
| Microsoft Edge | OK |

## 生成されるノートの構造

| セクション | 内容 |
|---|---|
| メタデータ | タイトル、チャンネル、公開日、長さ、言語、字幕種別、要約日 |
| キーワード | 主要なキーワード・重要概念（インラインコード形式） |
| 概要 | 2-3文の要約 |
| タイムライン | 時系列順の主要ポイント（YouTubeリンク付きタイムスタンプ） |
| 詳細ノート | 深掘りが必要な内容（任意） |
| 発展の種 | 派生ノート候補 2-3個 |
| トランスクリプト | 折りたたみ内にタイムスタンプ付き全文格納 |

ノートタイプは `Source`、Obsidian Vaultの `{SOURCE_FOLDER}/` に保存される。

## 依存ツール

| ツール | 用途 | インストール |
|---|---|---|
| [yt-dlp](https://github.com/yt-dlp/yt-dlp) | メタデータ取得 | `brew install yt-dlp` |
| [youtube-transcript-api](https://github.com/jdepoix/youtube-transcript-api) | 字幕取得 | `pip install youtube-transcript-api` |
| [jq](https://jqlang.github.io/jq/) | JSON処理 | `brew install jq` |
| [Claude Code](https://docs.anthropic.com/en/docs/claude-code) | AI要約生成 | `npm install -g @anthropic-ai/claude-code` |
| [PopClip](https://www.popclip.app/) | ワンクリック起動（任意） | App Store |

## トラブルシューティング

### `command not found: yt-dlp` / `claude`

PopClipやキーボードショートカットなど非対話シェルからの起動時に PATH が不足する場合がある。`config` の `EXTRA_PATH` に必要なパスを追加する:

```bash
# 例: pyenv + Homebrew + Claude Code
EXTRA_PATH="/opt/homebrew/bin:$HOME/.pyenv/shims:$HOME/.local/bin"
```

### 字幕が取得できない

- 動画に字幕が存在しない（ライブ配信直後など）
- 地域制限で字幕にアクセスできない
- `youtube-transcript-api` のバージョンが古い → `pip install -U youtube-transcript-api`

### 設定ファイルが見つからない

```
Error: Config file not found: ~/.config/youtube-to-obsidian/config
```

`install.sh` を実行するか、`config.example` を手動コピーする:

```bash
mkdir -p ~/.config/youtube-to-obsidian
cp config.example ~/.config/youtube-to-obsidian/config
```

### PopClip拡張でスクリプトパスが通らない

PopClipのYAMLでは `$HOME` 等の変数展開が行われない。`install.sh` はインストール時に実パスを埋め込むが、手動導入の場合は `.popcliptxt` 内のパスを直接編集する:

```yaml
shell script: |
  nohup /Users/yourname/.claude/scripts/youtube-to-obsidian.sh "$POPCLIP_TEXT" > /tmp/youtube-to-obsidian.log 2>&1 &
  exit 0
```

### 未対応ブラウザでショートカットが動作しない

`youtube-to-obsidian-trigger.sh` がサポートしていないブラウザの場合、macOS通知で「未対応ブラウザ」と表示される。スクリプト内の `case` 文にブラウザを追加して対応可能。

### Claude Code の認証エラー

`claude` コマンドの初回起動時に認証が必要。事前に `claude` を一度実行してログインしておく。

## License

MIT
