# simple-ai-chat.nvim: CLAUDE.md の `@import` 展開とユーザーグローバル読み込み 仕様

## 目的

現状の CLAUDE.md 読み込み（`<cwd>/CLAUDE.md` または `<cwd>/.claude/CLAUDE.md` の最初の 1 つ）を、Claude Code の慣習に近づける。

- `~/.claude/CLAUDE.md`（ユーザーグローバル）も読み込む。
- CLAUDE.md 内の `@path` による `@import` を展開する。`.claude/**` 配下のその他のファイル（`rules/*.md` など）は、`@import` で参照されたときだけ読み込む（ディレクトリの一括スキャンはしない）。

親ディレクトリの CLAUDE.md は読み込まない（従来どおり cwd のみ）。

## 変更不要な箇所

- `deno/*`：system は従来どおり文字列として stdin JSON の `system` に載せるだけ。
- `@` コンテキスト（`@buf` / `@file:` など）：CLAUDE.md 内の `@import` とは別機構。`context.lua` は触らない。
- システムプロンプトの連結順（`BASE_SYSTEM` → CLAUDE.md → persona → `/system` → notice）。CLAUDE.md の部分だけが「ユーザーグローバル + プロジェクト」に置き換わる。

## 設計

### 読み込み対象と順序

次の順に、存在するものを `\n\n` で連結して 1 つの CLAUDE.md 部分とする。

1. `~/.claude/CLAUDE.md`（ユーザーグローバル）
2. プロジェクト：`<cwd>/CLAUDE.md`、なければ `<cwd>/.claude/CLAUDE.md`（最初に見つかった 1 つ。従来どおり）

空ファイル・読み込み失敗は無視する。送信ごとに読み直す（従来どおり）。

### `@import` 記法

CLAUDE.md の本文中の `@<path>` を、そのファイルの内容で置き換える。

- トークンは空白区切りで、`@` で始まり、`/` `~` `.` のいずれかを含むものだけをパスとして扱う（`@buf` のような単語や `@user` 風の文字列を誤展開しないため）。
- パスの解決：
  - `~/` で始まる場合は `$HOME` 基準。
  - 絶対パスはそのまま。
  - 相対パスは**そのトークンを含むファイルのあるディレクトリ**基準（cwd 基準ではない）。
- インラインコード（`` `...` ``）とフェンス付きコードブロック（` ``` `）内の `@...` は展開しない。
- 展開は再帰的に行い、深さは最大 5。超過分は展開せず原文のまま残す。
- 循環参照は、展開中のファイルのスタックで検出し、該当トークンを原文のまま残す。
- ファイルが存在しない・読めない場合は、トークンを原文のまま残す（エラーにしない）。
- トークン末尾の句読点（`.` `,` `)` `、` `。`）は、パスの一部ではないものとして除いて解決する。
- 展開形式：トークンを、対象ファイルの内容（末尾の改行は除去）でそのまま置き換える。見出しやラッパーは付けない。

例（`CLAUDE.md`）：

```text
@.claude/rules/lua.md
個人設定は @~/.claude/my-style.md を参照。
```

### 例外

- `@import` は CLAUDE.md（および再帰的に展開されたファイル）の中でのみ有効。チャット入力の `@` トークンには影響しない。
- 展開後の合計サイズの上限は設けない（CLAUDE.md を書く側の責任）。

## 実装

### `lua/ai-chat/chat.lua`

- `read_claude_md()` を置き換える。
  - `expand_imports(text, dir, stack, depth)`：上記規則で `@path` を展開する。
  - `read_file(path)`：`filereadable` + `readfile` + `pcall`。失敗時は `nil`。
  - `read_claude_md()`：ユーザーグローバル → プロジェクトの順に読み、各ファイルを `expand_imports` に通して `\n\n` で連結して返す。
- `build_system` は `read_claude_md()` の戻り値を使う形のまま変更しない（戻り値の 2 つ目 `path` は未使用なら削除）。

### テスト

- `test/lua/` に `claude_md_test.lua` を追加する（`nvim --headless -u NONE -l test/lua/run.lua`）。
  - 相対 / `~/` / 絶対パスの解決、コードスパン・コードブロック内の非展開、深さ制限、循環参照、存在しないファイル、末尾句読点。
- テストしやすいよう、`expand_imports` は純関数として切り出す（`HOME` は `vim.env.HOME` 経由で差し替え可能にする）。

### ドキュメント

- `doc/spec.md`「プロジェクト指示の自動読み込み（CLAUDE.md）」を更新する（読み込み対象・`@import`）。
- `README.md` の「CLAUDE.md auto-loading」節と機能一覧を更新する。
- `.claude/CLAUDE.md` の「アーキテクチャの肝」などに影響があれば追記する。

## 決定事項

- 読み込み対象は `~/.claude/CLAUDE.md` + プロジェクト（`<cwd>/CLAUDE.md` or `<cwd>/.claude/CLAUDE.md`）。親ディレクトリの CLAUDE.md は読まない。
- `.claude/**` のその他のファイルは `@import` で参照されたときのみ読み込む。ディレクトリスキャンはしない。
- `@import` は再帰（最大深さ 5）、循環・不在は原文のまま残す。
- `CLAUDE.local.md` / `settings.json` / `agents/` / `commands/` / `skills/` は対象外。
