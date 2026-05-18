# simple-ai-chat.nvim — 仕様書

## 概要

Neovim 上で動作する AI チャットプラグイン。  
UI・キーマップは Lua で実装し、Anthropic API との通信は Deno スクリプトが担当する。  
外部プラグイン依存なし（スタンドアロン）。

---

## アーキテクチャ

```
Neovim (Lua)
  │
  ├── UI管理（チャットウィンドウ、差分表示）
  ├── キーマップ・コマンド
  └── jobstart() で Deno プロセスを起動
          │ stdin: JSON (messages, context)
          │ stdout: SSE ストリーム (delta text)
          ▼
       Deno スクリプト
          └── Anthropic API (@anthropic-ai/sdk) でストリーミング
```

Deno プロセスはリクエストごとに起動・終了する（都度起動方式）。

---

## ディレクトリ構成

```
plugin/
  ai-chat.lua          # エントリポイント（コマンド登録）
lua/
  ai-chat/
    init.lua           # setup()
    chat.lua           # チャットウィンドウ管理
    diff.lua           # 差分適用ロジック
    context.lua        # コンテキスト収集
    job.lua            # Deno プロセス管理
deno/
  main.ts              # Deno エントリポイント
  api.ts               # Anthropic API クライアント
```

---

## 依存関係

- **Neovim** >= 0.9
- **Deno** >= 1.40（PATH に通っていること）
- **API キー**（環境変数、使うプロバイダーのみ必要）：
  - `ANTHROPIC_API_KEY` — Anthropic（Claude）
  - `OPENAI_API_KEY` — OpenAI
  - `GEMINI_API_KEY` — Google Gemini
  - `DEEPSEEK_API_KEY` — DeepSeek
- Neovim プラグイン依存：**なし**

---

## UI 仕様

### レイアウト

- 左側に縦分割でチャットウィンドウが開く（デフォルト幅: 40%）
- チャットウィンドウは上部（出力）・下部（入力）の 2 ペイン構成

```
┌──────────────────┬─────────────────┐
│  [AI Chat]       │                 │
│  > こんにちは    │   編集バッファ    │
│  ...応答...      │                 │
│──────────────────│                 │
│  入力欄          │                 │
└──────────────────┴─────────────────┘
```

- チャットウィンドウの `filetype` は `ai-chat`
- Markdown のシンタックスハイライトを適用（`set syntax=markdown`）
- `nomodifiable` バッファに出力を追記していく

---

## キーマップ

### グローバル

| キー | 動作 |
|---|---|
| `<leader>ac` | チャットを開く / フォーカス切り替え |
| `<leader>aq` | チャットを閉じる |

ビジュアル選択後に `<leader>ac` でチャットを開くと、選択範囲がコンテキストに自動追加される。

### チャットウィンドウ内（出力ペイン）

| キー | 動作 |
|---|---|
| `i` | 入力ペインにフォーカス |
| `ga` | カーソル下のコードブロックを差分適用 |
| `gA` | すべてのコードブロックを差分適用 |
| `gy` | カーソル下のコードブロックをヤンク |
| `]]` / `[[` | 次 / 前のコードブロックへジャンプ |
| `<C-c>` | ストリーミング中断 |

### チャットウィンドウ内（入力ペイン）

| キー | 動作 |
|---|---|
| `<CR>`（ノーマルモード） | 送信 |
| `<C-CR>`（インサートモード） | 送信 |
| `<C-c>` | ストリーミング中断 |
| `<Esc>` | 出力ペインにフォーカス |
| `<Up>` / `<Down>` | プロンプト履歴 |

---

## コンテキスト仕様

コンテキストはプロンプト内で `@` プレフィックスで明示指定する方式とする。  
自動挿入は行わない。

### 対応コンテキストタイプ

| 指定 | 内容 |
|---|---|
| `@buf` | 現在のバッファ全体 |
| `@bufs` | 開いているバッファをすべて渡す（`nofile` 系・不可視バッファは除外） |
| `@sel` | 直前のビジュアル選択範囲 |
| `@file:<path>` | 指定ファイルの内容 |
| `@diag` | 現在のバッファの LSP diagnostics |

### 例

```
@buf このコードをレビューして
@sel この関数の型を修正して
@file:src/main.ts このファイルのバグを探して
@diag エラーを直して
```

---

## スティッキーコンテキスト

セッション中、毎回のプロンプトに自動付与されるコンテキストを固定できる。

### UI

入力ペインの上部にスティッキーコンテキストを常時表示する。

```
┌──────────────────────────────┐
│ 📌 @buf @diag                │  ← スティッキー表示行（編集不可）
│──────────────────────────────│
│ ここに入力...                │
└──────────────────────────────┘
```

### 操作

| キー / コマンド | 動作 |
|---|---|
| `gp` （出力ペイン） | カーソル下のコンテキストタイプをスティッキーに追加 |
| `/pin @buf @diag` | 指定コンテキストタイプをスティッキーに追加 |
| `/unpin @buf` | 指定コンテキストタイプをスティッキーから除外 |
| `/unpin` | スティッキーをすべてクリア |

### 動作仕様

- スティッキーコンテキストはセッションスコープ（チャットを閉じるとリセット）
- プロンプト送信時、スティッキーのコンテキストをプロンプト先頭に自動付与する
- プロンプト内で同じコンテキストタイプを明示した場合は重複させない
- `@file:<path>` のスティッキーも可能

---

## スラッシュコマンド

入力ペインで `/` から始まるビルトインコマンドを使用可能。

| コマンド | 動作 |
|---|---|
| `/clear` | 会話履歴をクリア |
| `/quit` | チャットを閉じる |
| `/pin <context...>` | コンテキストタイプをスティッキーに追加 |
| `/unpin [context]` | スティッキーを解除（引数なしで全解除） |
| `/model <name>` | 使用モデルを切り替え |
| `/system <text>` | システムプロンプトを設定 |

---

## 差分適用仕様

レスポンス内のコードブロック（` ``` ` で囲まれた部分）を対象とする。

### コードブロックの 2 つの書式

**A. SEARCH/REPLACE 形式（推奨・部分書き換え）**

```
```<lang>:<path>
<<<<<<< SEARCH
<変更前のコード>
=======
<変更後のコード>
>>>>>>> REPLACE
```
```

- SEARCH は既存ファイル内容と**完全一致**する必要がある（空白・インデント含む）
- 1 コードブロック内に SEARCH/REPLACE ペアを複数並べてよい
- 新規ファイルは SEARCH を空にして REPLACE のみ

**B. 全文置換形式**

```
```<lang>:<path>
<ファイル全文>
```
```

SEARCH/REPLACE マーカーが含まれない場合、コードブロック内容でファイル全体を置換する。

### 適用フロー

1. `ga` でカーソル下のコードブロックを検出
2. ファイルパスをヘッダから取得（無ければ現在フォーカスしていた編集バッファを対象）
3. コードブロック内に SEARCH/REPLACE があれば各ペアを順次適用、無ければ全置換として new_content を構築
4. 現在の内容 vs new_content を `:diffthis` で新規タブの vimdiff として表示
5. 差分バッファで `<CR>` で適用、`q` でキャンセル

SEARCH 文字列がファイル内に見つからない場合は通知してタブは開かない。

### AI への指示（プラグイン組み込み）

プラグインは送信時、上記書式（特に SEARCH/REPLACE）の指示文をデフォルト system プロンプトとして自動で前置する。ユーザーが `/system` で設定した内容はその後ろに追記される。これにより AI は常に部分書き換えの SEARCH/REPLACE で変更を返すようになる。

### マルチプロバイダー対応

Anthropic（Claude）に加えて、OpenAI 互換 API を提供するプロバイダー（OpenAI / Google Gemini / DeepSeek）をサポートする。**Deno 側だけで完結**させ、Lua 側からは透過的（`/model <name>` で切り替えるだけ）。

#### ルーティング

`model` 名のプレフィックスでアダプタを振り分ける：

| プレフィックス | プロバイダー | baseURL | API キー（env） |
| --- | --- | --- | --- |
| `claude-*` | Anthropic | (SDK デフォルト) | `ANTHROPIC_API_KEY` |
| `gpt-*`, `o1*`, `o3*` | OpenAI | `https://api.openai.com/v1` | `OPENAI_API_KEY` |
| `gemini-*` | Google Gemini | `https://generativelanguage.googleapis.com/v1beta/openai/` | `GEMINI_API_KEY` |
| `deepseek-*` | DeepSeek | `https://api.deepseek.com/v1` | `DEEPSEEK_API_KEY` |

#### 実装方針

- **Anthropic 経路**：`@anthropic-ai/sdk` を使う。`system` は top-level 引数、`messages` の途中に `cache_control: { type: "ephemeral" }` を入れてプロンプトキャッシュ有効。
- **OpenAI 互換経路**：`npm:openai` SDK を `baseURL` 切り替えで利用。`system` は `messages` 配列の先頭に `{ role: "system", content: "..." }` として挿入。`cache_control` は付けない（各プロバイダーが自動キャッシュを行う前提）。
- stdin で受け取る JSON 構造（`model` / `system` / `messages` / `max_tokens`）は変えない。
- usage はプロバイダーごとに形式が違うが、統一しない。各経路で**人間可読な 1 行文字列**にしてから `USAGE: ...` として stderr に書く（前述「stderr の用途」参照）。

#### 採用しない選択肢

- OpenRouter / LiteLLM のような統合プロキシ経由は採用しない（各プロバイダーを直叩き、コスト最優先）。
- モデル一覧の自動取得・補完は行わない（`/model <name>` を手動指定する前提）。

---

### プロジェクト指示の自動読み込み（CLAUDE.md）

送信時、Neovim の cwd 配下に以下のファイルがあれば自動で内容を読み込み、system プロンプトに連結する：

1. `<cwd>/CLAUDE.md`
2. `<cwd>/.claude/CLAUDE.md`

最初に見つかった 1 つを使用する。`CLAUDE.md` は Claude Code（claude.ai/code）のプロジェクト指示ファイルとして広く使われる慣習に従う。送信ごとに読み直すので、編集後は次の送信から即反映される。

最終的な system プロンプトの構造：

```
<プラグイン組み込みの SEARCH/REPLACE 指示>

<CLAUDE.md の内容（存在すれば）>

<ユーザーが /system で設定した内容（存在すれば）>
```

---

## Deno スクリプト仕様

### 入力（stdin, JSON）

```json
{
  "model": "claude-sonnet-4-6",
  "system": "...",
  "messages": [
    { "role": "user", "content": "..." },
    { "role": "assistant", "content": "..." }
  ],
  "max_tokens": 8096
}
```

Lua 側は **プロバイダーを意識しない**。Deno 側が `model` プレフィックスでプロバイダーを判定する（後述「マルチプロバイダー対応」）。

### 出力（stdout）

ストリーミングデルタをテキストとして逐次 stdout に書き出す。終了時に `\n[DONE]\n` を出力する。

### stderr の用途

stderr は次の 2 種類の出力に使う。Lua 側は行頭で振り分ける。

- `USAGE: <human-readable line>` — 1 件のリクエストの usage 情報。Lua 側は `USAGE: ` 以降の文字列をそのまま出力ペインに追記する（パース・整形しない）。Deno 側でプロバイダーごとに人間可読な形に整形してから書き出す。
- それ以外 — エラーメッセージ。Lua 側は `on_stderr` で受け取りチャットウィンドウにエラー表示する。

usage の例：

```
USAGE: input=42 cached_read=2071 cached_write=0 output=128
```

usage のフィールドはプロバイダーごとに異なってよい（Anthropic と OpenAI 互換で形が違うが、それぞれの形を保ったまま 1 行文字列にする）。

---

## セットアップ

```lua
require('ai-chat').setup({
  model = "claude-sonnet-4-6", -- デフォルトモデル
  window = {
    width = 0.4,         -- チャットウィンドウ幅（エディタ幅に対する割合）
    side = "left",       -- チャットウィンドウの位置
  },
  deno_script = nil,     -- nil の場合、プラグインディレクトリの deno/main.ts を使用
})
```

---

## 実装ステップ

開発はこの順で進める。各ステップは spec.md の該当章を満たすことを完了条件とし、前ステップが終わるまで次に進まない。先回り実装はしない。

### Step 1: Deno ↔ Lua の通信・ストリーミング表示

**スコープ**

- `deno/main.ts` / `deno/api.ts`：stdin から JSON 受領 → Anthropic SDK でストリーミング → stdout に delta、終端 `\n[DONE]\n`、エラーは stderr
- `lua/ai-chat/job.lua`：`jobstart()` で起動、`on_stdout` / `on_stderr` / `on_exit` ハンドラ
- UI はこの段階では最小（単一バッファに追記でも可）

**完了条件**

- ハードコードしたメッセージで API を叩き、応答がストリーミングでバッファに追加される
- ジョブを kill できる（`<C-c>` 相当）

### Step 2: ウィンドウ・バッファ管理

**スコープ**

- 出力／入力 2 ペイン構成、左側縦分割、`filetype=ai-chat`、Markdown ハイライト、出力ペインは `nomodifiable` + 追記
- `<leader>ac` / `<leader>aq` / ペイン間フォーカス切替（`i` / `<Esc>`）
- 入力ペインからの送信（`<CR>` / `<C-CR>`）
- プロンプト履歴（`<Up>` / `<Down>`）

**完了条件**

- spec.md「UI 仕様」「キーマップ」のうち、出力ペインのコードブロック系キー（`ga` / `gA` / `gy` / `]]` / `[[`）とスティッキー表示行を除く要素が動作する

### Step 3: コンテキスト収集（`@` プレフィックス）

**スコープ**

- プロンプトをパースし `@buf` / `@bufs` / `@sel` / `@file:<path>` / `@diag` を実コンテンツに展開
- 各収集ロジック：現在バッファ、開いている可視バッファ、直前ビジュアル選択、ファイル読み込み、LSP diagnostics
- ビジュアル選択中に `<leader>ac` でチャットを開いた場合、`@sel` を自動付与

**完了条件**

- 5 種すべて単独・組み合わせで動き、Anthropic に渡る `messages` に正しく含まれる

### Step 4: スティッキーコンテキスト・スラッシュコマンド

**スコープ**

- セッションスコープのスティッキー保持（チャットクローズでリセット）
- 入力ペイン上部のスティッキー表示行（編集不可）
- `gp`（出力ペイン）、`/pin` / `/unpin`
- 他のスラッシュコマンド：`/clear` / `/quit` / `/model` / `/system`
- プロンプト送信時、スティッキーを先頭に自動付与（本文での明示指定とは重複させない）

**完了条件**

- spec.md「スティッキーコンテキスト」「スラッシュコマンド」が全て動作する

### Step 5: 差分適用

**スコープ**

- コードブロック検出（` ``` ` で囲まれた範囲）
- ヘッダから言語・パスを抽出（` ```lua:lua/foo.lua ` 形式）。パス無し時は直前フォーカスバッファを対象
- `vim.diff()` で差分生成、新規タブで差分バッファ表示、`<CR>` 適用 / `q` キャンセル
- `ga` / `gA` / `gy` / `]]` / `[[`

**完了条件**

- spec.md「差分適用仕様」とコードブロック系キーマップが全て動作する

### Step 6: マルチプロバイダー対応

**スコープ**

- `deno/api.ts` に OpenAI 互換アダプタ `streamTextOpenAICompat()` を追加（既存の Anthropic 経路 `streamText()` はそのまま残す）
- `deno/main.ts` で `model` プレフィックスを判定して呼び分け（`claude-*` → Anthropic、`gpt-*`/`o1*`/`o3*` → OpenAI、`gemini-*` → Gemini、`deepseek-*` → DeepSeek）
- `deno/deno.json` の `imports` に `npm:openai` を追加
- OpenAI 互換経路では `system` を `messages` 先頭に `role: "system"` で挿入、`cache_control` は付けない
- 環境変数：`OPENAI_API_KEY` / `GEMINI_API_KEY` / `DEEPSEEK_API_KEY` を各経路で個別に読む
- usage は各プロバイダーの形式のまま、Deno 側で人間可読な 1 行に整形して `USAGE: ...` を stderr に書く
- Lua 側は変更なし

**完了条件**

- `/model gpt-4o`、`/model gemini-2.5-flash`、`/model deepseek-chat`、`/model claude-sonnet-4-6` のいずれを指定しても応答が返り、出力ペインに usage 行が表示される
- 環境変数が未設定のプロバイダーを使うとエラーが stderr に出てチャットに表示される

---

## 未対応（スコープ外）

- telescope / fzf-lua との連携
- セッション保存・復元
- ビジュアルモードでのインライン編集
- OpenRouter / LiteLLM 等の統合プロキシ経由（直叩き方式を維持）
