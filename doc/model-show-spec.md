# simple-ai-chat.nvim: `/model` 引数なしで現在のモデルを表示する仕様

## 目的

`/model` を引数なしで実行したとき、そのセッションで実際に使われるモデル名を出力ペインに表示する。

- `/model <name>` によるセッション上書き（`state.session_model`）がある場合はその値
- 無ければ `setup()` の `opts.model`（設定デフォルト）

を表示する。あわせて「今どのモデルで次のリクエストが飛ぶか」をチャット内で確認できるようにする。

## 現状の制約

| 箇所 | 現状 | 問題 |
| --- | --- | --- |
| `lua/ai-chat/commands.lua` の `handlers.model` | `args` が空だと `[ERROR] /model requires a model name` を出力して終わる | 現在のモデルを確認する手段がない |
| 実効モデルの決定 | `chat.lua` の `M.send` / `M.run_workflow` が `state.session_model or opts.model` で決めている | 判定式が `chat.lua` 内に閉じている |
| `commands.lua` から見える情報 | ハンドラは `state` と `ctx` を受け取るが、`ctx` に `opts` が渡っていない | 設定デフォルト（`opts.model`）を参照できない |

## 変更不要な箇所

- `lua/ai-chat/job.lua` / `deno/main.ts` / `deno/api.ts`：モデル名は従来どおり payload で渡すだけで、表示は Lua 側の出力のみ。サーバ側の変更は不要。
- `/model <name>` の切り替え挙動と出力（`--- model: <name> ---`）はそのまま。
- provider 解決（`resolve_provider`、`job.start` の `--allow-net` / `env` 注入）は変更しない。モデル名から導出される結果は既存ロジックのまま。
- `/clear` の挙動（`state.messages` / `state.workflow_edit_start` のクリアのみ）は変更しない（「決定事項」参照）。
- `CLAUDE.md` のアーキテクチャ記述：ファイル構成・プロトコルに変化がないため更新不要。

## 設計

### 実効モデルの参照経路

`commands.lua` は `opts` を知らないため、`chat.lua` の `build_cmd_ctx(opts)` が作る `ctx` に取得関数を載せる。

- `ctx` に `current_model` フィールド（引数なし関数）を追加する。返り値は `state.session_model or opts.model`。
- クロージャは `chat.lua` のモジュールローカル `state` を upvalue として参照するため、`reset_state()` による `state` の差し替え（チャット再オープン）後も新しい `state` を見る。
- ハンドラ側は `ctx.current_model()` を呼ぶだけにし、`session_model or default` の判定式を `commands.lua` に複製しない（送信時と表示が必ず一致する）。
- 既存の `ctx` フィールド（`append_output_lines` / `update_winbar` / `close` / `run_workflow`）は変更しない。追加は 1 フィールドのみ。

`default_model = opts.model` を素の値として渡し、`commands.lua` 側で `state.session_model or ctx.default_model` と書く案は、判定式が 2 箇所に散るため採らない。

### 出力

- 引数なしの `/model` は `--- model: <実効モデル> ---` を出力ペインに追記する。前後に空行 1 行を入れ、既存の `--- cleared ---` / `--- system: ... ---` / 切り替え時の `--- model: ... ---` と同じ体裁にする。
- 引数ありの場合は従来どおり `state.session_model` を更新し、同じ体裁で 1 行表示する（既存挙動を維持）。
- 表示は「次回の送信で使われるモデル」と一致する。ワークフロー中各ステップの `model` 上書きはステップ定義側の都合であり、本表示の対象外。

## 実装

| ファイル | 変更内容 |
| --- | --- |
| `lua/ai-chat/chat.lua` | `build_cmd_ctx(opts)` の戻り値テーブルに `current_model`（`state.session_model or opts.model` を返す関数）を追加する。他の関数・送信経路は変更しない。 |
| `lua/ai-chat/commands.lua` | `handlers.model` の `#args == 0` 分岐を、エラー出力から `ctx.current_model()` の表示に置き換える。引数ありの分岐はそのまま。 |
| `doc/spec.md` | 「スラッシュコマンド」表の `/model <name>` 行を `/model [name]` に変更し、引数なし時は現在のモデルを表示する旨を追記。 |
| `README.md` | Slash commands 表の `/model <name>` 行を `/model [name]` に変更し、引数なしで現在のモデル（セッション上書き or 設定デフォルト）を表示する旨を追記。必要なら Features の箇条書きに「`/model` without arguments shows the current model」を 1 行追加。 |
| `test/lua/commands_test.lua` | `/model` のテストを追加。既存ファイルがあればそこに追加、無ければ新規作成（`test/lua/run.lua` が `*_test.lua` を自動で拾う）。 |

### テスト観点

`vim.api.nvim_*` に依存させず、`require("ai-chat.commands").handle(prompt, state, ctx)` を直接呼ぶ。`ctx.append_output_lines` は受け取った行をテーブルに溜めるスタブにする（パース経路も同時に検証できるため、ハンドラ直呼びよりこちらを推奨）。

- `state.session_model = nil` のとき、`ctx.current_model()` の値（= `opts.model` 相当のスタブ値）が表示される。
- `state.session_model` が設定済みのとき、その値が表示される。
- 引数ありのとき `state.session_model` が更新され、クエリ側の表示ロジックは走らない。
- 出力行の体裁が `--- model: <name> ---`（前後に空行）である。
- 未知コマンド・`/model` 以外の既存コマンドの挙動が変わらない。

## 決定事項

- 引数なしの出力は切り替え時と同じ `--- model: <name> ---` 形式にする。`(session)` / `(default)` のような由来表示は付けない（実効モデルが分かれば目的を満たし、出力体裁を増やさない）。
- provider 名（`providers` の `match` 先）は表示しない。モデル名から自明であり、表示項目を増やすと provider 解決の知識が UI 層に漏れる。
- 判定式は `chat.lua` に集約する（`ctx.current_model`）。`commands.lua` 側にモデル解決ロジックを持たせない。
- `/clear` 後に `state.session_model` が残る現状挙動は本件では変更しない。`doc/deepseek-provider-spec.md` には「`/clear` で `session_model` がリセットされる」とあるが、現行の `handlers.clear` はリセットしていない。どちらへ寄せるかは別 issue で決める。本件は表示のみであり、表示値は「実際に次回使われる値」なので実装とのズレは生じない。
- 引数なし実行時に「利用可能なモデル一覧」は出さない（スコープ外）。

## 未対応（スコープ外）

- 利用可能なモデル一覧の表示（`/model` 引数なしで候補を列挙する案）
- provider 名の表示、および provider の切り替え UI
- ワークフロー各ステップの `model` 上書きをチャット上に表示する機能
- `/clear` と `session_model` の関係の整理（別 issue）
