# simple-ai-chat.nvim: DeepSeek（Anthropic互換エンドポイント）対応仕様

## 目的

モデル名に応じて API の接続先を切り替え、同じセッション内の `/model` で Claude（Anthropic）と DeepSeek を行き来できるようにする。

## 現状の制約

| 箇所 | 現状 | DeepSeek 利用時の問題 |
| --- | --- | --- |
| `lua/ai-chat/job.lua` | Deno を `--allow-net=api.anthropic.com` で起動 | `api.deepseek.com` への通信が Deno の権限で拒否される |
| `deno/main.ts` | `ANTHROPIC_API_KEY` が未設定だと終了 | DeepSeek のキーを別名で持つと起動できない |
| 環境変数 | Neovim の環境をそのまま Deno に継承 | 接続先・キーをモデルごとに切り替える手段がない |
| `deno.json` `tasks.run` | `--allow-net=api.anthropic.com` | `deno task run` での手動テスト時も同様に拒否される |

Claude Code 側の `settings.json`（`env`）は Claude Code の中だけで有効なため、本プラグインには影響しない。

## 変更不要な箇所

- `deno/api.ts`：Anthropic SDK（`@anthropic-ai/sdk`）は環境変数 `ANTHROPIC_BASE_URL` / `ANTHROPIC_API_KEY` を自動で読むため、そのままで接続先を差し替えられる。
- `cache_control`（system と直前 assistant に付与）：DeepSeek 側では無視されるだけで、エラーにはならない。

## 設計

### 設定オプション `providers`

`setup()` に `providers` を追加する。各要素は次のフィールドを持つ。

| フィールド | 型 | 説明 |
| --- | --- | --- |
| `match` | string（Lua パターン） | モデル名にマッチしたらこの接続先を使う |
| `base_url` | string | Anthropic 互換エンドポイントの URL |
| `api_key_env` | string | API キーを読む環境変数名 |

- 配列の先頭から評価し、最初にマッチした要素を採用する。
- どれにもマッチしない場合は従来どおり Anthropic（`api.anthropic.com`）に接続する。
- デフォルトは空配列（既存の挙動は変わらない）。

### 処理の流れ

1. 送信時、`chat.lua` が現在のモデル名（`/model` で変更されたものを含む）で `providers` を検索する。
2. マッチした provider を `job.start()` に渡す。
3. `job.lua` は provider がある場合、
   - `base_url` からホスト名を取り出して `--allow-net=<host>` にする。
   - `jobstart()` の `env` で `ANTHROPIC_BASE_URL` と `ANTHROPIC_API_KEY`（`api_key_env` の値）を渡す。`env` は現在の環境変数にマージされる。
   - `api_key_env` の環境変数が未設定（nil / 空文字）の場合は Deno を起動せず、`on_error("<api_key_env> is not set")` を呼んで中断する。
     - `env` に nil を渡すとキーが除外され、継承された本物の `ANTHROPIC_API_KEY` が DeepSeek に送信されてしまうため。
4. Deno 側は従来どおり Anthropic SDK でストリーミングする。

## 決定事項

- キー未設定時はエラーで中断する（Anthropic キーへのフォールバックはしない）。
- `--- usage: ... ---` 表示は DeepSeek でも現行ロジックのまま出す（cache 系フィールドが無ければ省略される）。
- `/clear` で `session_model` がリセットされ、デフォルトモデル（`opts.model`）に戻る挙動は既存仕様のまま。provider もそのモデルに従って決まる。
- `deno/main.ts` は変更しない（provider 利用時は `ANTHROPIC_API_KEY` が注入済みで、未設定のケースは Lua 側で先に弾く）。

## 実装

### `lua/ai-chat/init.lua`

```lua
local default_opts = {
  model = "claude-sonnet-4-6",
  max_tokens = 8096,
  deno_script = nil,
  -- model 名が match にマッチしたら、その接続先を使う（どれにもマッチしなければ Anthropic）
  providers = {},
  window = {
    width = 0.4,
    input_height = 5,
    side = "left",
  },
}
```

### `lua/ai-chat/chat.lua`

```lua
local function resolve_provider(providers, model)
  for _, p in ipairs(providers or {}) do
    if model:match(p.match) then return p end
  end
  return nil
end

-- （中略）

  state.job_id = job.start({
    deno_script = opts.deno_script,
    provider = resolve_provider(opts.providers, model),
    payload = {
      model = model,
      system = build_system(state.system),
      messages = vim.deepcopy(state.messages),
      max_tokens = opts.max_tokens,
    },
    on_text = on_text,
    on_done = on_done,
    on_error = on_error,
    on_usage = on_usage,
  })
```

### `lua/ai-chat/job.lua`

```lua
function M.start(opts)
  local stdout_buf = ""
  local done_emitted = false

  local host = "api.anthropic.com"
  local env = nil
  if opts.provider then
    local key = vim.env[opts.provider.api_key_env]
    if not key or key == "" then
      opts.on_error(opts.provider.api_key_env .. " is not set")
      return -1
    end
    host = opts.provider.base_url:match("^https?://([^/]+)")
    env = {
      ANTHROPIC_BASE_URL = opts.provider.base_url,
      ANTHROPIC_API_KEY = key,
    }
  end

  local job_id = vim.fn.jobstart({
    "deno",
    "run",
    "--allow-net=" .. host,
    "--allow-env",
    opts.deno_script,
  }, {
    env = env, -- 現在の環境変数にマージされる
    on_stdout = function(_, data, _)
      -- （以下既存のまま）
```

### `deno/deno.json`（手動テスト用）

```json
"run": "deno run --allow-net=api.anthropic.com,api.deepseek.com --allow-env main.ts"
```

## 設定例

```lua
require("ai-chat").setup({
  model = "claude-sonnet-4-6",
  providers = {
    {
      match = "^deepseek",
      base_url = "https://api.deepseek.com/anthropic",
      api_key_env = "DEEPSEEK_API_KEY",
    },
  },
})
```

```bash
# ~/.zshrc など
export ANTHROPIC_API_KEY=<AnthropicのAPIキー>
export DEEPSEEK_API_KEY=<DeepSeekのAPIキー>
```

## 使い方

```text
/model deepseek-flash
/model deepseek-v4-pro
/model claude-sonnet-4-6   ← Anthropic に戻る
```

## Claude Code との使い分け

本仕様の変更だけを入れた場合、ローカルの Claude Code は Anthropic、本プラグインは DeepSeek、という使い分けができる。

- Claude Code：Claude Code 側に DeepSeek 用の設定（`settings.json` の `env` やエイリアス）を入れなければ、従来どおり Anthropic に接続する。`DEEPSEEK_API_KEY` は Claude Code では使われないため影響しない。
- 本プラグイン：モデル名が `providers` の `match` にマッチしたときだけ DeepSeek に接続する。

プラグインを常に DeepSeek で使う場合は、デフォルトのモデルを DeepSeek にする（`/model` での切り替えは不要）。

```lua
require("ai-chat").setup({
  model = "deepseek-flash",
  providers = {
    {
      match = "^deepseek",
      base_url = "https://api.deepseek.com/anthropic",
      api_key_env = "DEEPSEEK_API_KEY",
    },
  },
})
```

### 注意

- シェルの環境変数で `ANTHROPIC_BASE_URL` を DeepSeek に向けると、Claude Code も DeepSeek に接続してしまう。
- DeepSeek の接続先は本プラグインの `providers` にだけ書き、シェルには `DEEPSEEK_API_KEY` だけを置く。

## DeepSeek Anthropic 互換エンドポイントの仕様（本プラグインに関係する部分）

- base_url：`https://api.deepseek.com/anthropic`
- 認証：`x-api-key` に対応（SDK の `ANTHROPIC_API_KEY` で送られる）
- モデル名：`deepseek-flash` / `deepseek-v4-pro`
- モデル名のマッピング：`claude-opus*` は `deepseek-v4-pro`、それ以外の `claude*` は `deepseek-flash` にマッピングされる。`claude` で始まらない未対応のモデル名は 400 エラー。
  - 本仕様では `claude*` のモデル名は Anthropic に送られるため、このマッピングは使わない。
- `stream` / `system` / `max_tokens`：対応
- `cache_control`：無視（エラーにはならない）
- `anthropic-version` ヘッダ：無視
- `temperature`：0.0〜2.0
- `top_k`：無視

## 参考

- [Using the Anthropic API | DeepSeek API Docs](https://api-docs.deepseek.com/guides/anthropic_api)
- [h10hUI/simple-ai-chat.nvim](https://github.com/h10hUI/simple-ai-chat.nvim)
