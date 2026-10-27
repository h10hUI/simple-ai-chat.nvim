# simple-ai-chat.nvim: workflow 実行機能 仕様

Issue: [#9](https://github.com/h10hUI/simple-ai-chat.nvim/issues/9)

## 目的

複数のペルソナ（planner / coder / reviewer など）に「計画 → 実装 → レビュー → 修正」のループを順に実行させる `/workflow` コマンドを追加する。[TAKT](https://zenn.dev/nrs/articles/c6842288a526d7) の考え方（step の遷移を AI の裁量に任せず、仕組みとして強制する）をプラグイン内に取り込む。takt 本体（Node）には依存しない。

## 変更不要な箇所

- `deno/main.ts` / `deno/api.ts`：1 リクエスト = 1 回の Deno 起動のまま。workflow は Lua 側が Deno を複数回起動して実現する。プロトコル（stdin JSON / stdout delta + `[DONE]` / stderr）も変えない。
- `lua/ai-chat/job.lua`：`providers` による接続先切り替えも含め、そのまま使う。ただし Deno プロセスの終了を呼び出し側に通知する `on_exit` コールバック（任意）だけ追加する（usage の表示まで済んだ後で次の step に進むため）。
- `lua/ai-chat/diff.lua`：差分適用（`ga` / `gA`）はユーザー確認つきのまま。workflow がファイルを直接書き換えることはしない。`find_all_blocks` に開始行の引数を足すだけ（後述）。
- `@cmd` の実行は Lua 側のみ。AI の応答に含まれるコマンドの自動実行はしない。

## 設計

### 概念

| 用語 | 説明 |
| --- | --- |
| workflow | step の集まり。名前で識別する |
| step | 1 回の API リクエスト。ペルソナ・指示文・モデル・遷移ルールを持つ |
| persona | step の `system` に付与するテキスト |
| rules | step の出力末尾のマーカーに応じて次の step を決める定義 |

### 設定オプション `workflows`

`setup()` に `workflows`（名前 → workflow のテーブル）を追加する。ビルトインの `default` を持ち、同名キーで上書きできる。

### 設定の置き場所（グローバル / ローカル）

workflow 定義は 2 か所に置ける。どちらも `workflows` と同じ形（名前 → workflow のテーブル）で書く。

| 種別 | 場所 | 用途 |
| --- | --- | --- |
| グローバル | `setup({ workflows = ... })` | 全プロジェクト共通の workflow |
| ローカル | `<cwd>/.ai-chat/workflows.lua` | そのプロジェクト専用の workflow |

- `<cwd>` は `vim.fn.getcwd()`（`CLAUDE.md` の読み込みと同じ基準）。
- ローカルファイルはテーブルを `return` する Lua ファイル。

  ```lua
  -- <project>/.ai-chat/workflows.lua
  return {
    review = {
      steps = {
        { name = "review", persona = "...", instruction = "{task}" },
      },
    },
  }
  ```

#### マージ規則

- 優先順位は ビルトイン `default` < グローバル < ローカル。
- 同名の workflow は、より優先度の高い定義が**丸ごと置き換える**（step 単位のマージはしない）。
- 名前が異なる workflow は共存する。

#### 読み込みと trust

- ローカルファイルは `/workflow` を実行するたびに読み直す（キャッシュしない）。編集がすぐ反映される。
- 読み込みは `vim.secure.read()` 経由で行い、Neovim の `exrc` と同じ trust 確認を通す。初回（および内容変更後）にユーザーの許可を求め、拒否された場合は無視してグローバル設定とビルトインだけで動く。clone しただけのリポジトリのコードが無確認で実行されることを防ぐ。
- 読み込んだ内容は `loadstring` で評価し、構文エラー・実行時エラー・戻り値がテーブルでない場合は出力ペインに `[ERROR]` を表示して、そのローカル定義だけを無視する（グローバル / ビルトインは使える）。

```lua
workflows = {
  default = {
    max_steps = 10,
    steps = {
      { name = "plan", persona = "...", instruction = "..." },
      { name = "implement", persona = "...", instruction = "...", model = "claude-sonnet-4-6", edits = true },
      {
        name = "review",
        persona = "...",
        instruction = "...",
        rules = {
          { marker = "APPROVE", next = "COMPLETE" },
          { marker = "REJECT", next = "fix" },
        },
      },
      { name = "fix", persona = "...", instruction = "...", next = "review", edits = true },
    },
  },
}
```

#### workflow のフィールド

| フィールド | 型 | 説明 |
| --- | --- | --- |
| `max_steps` | number | 実行する step 数の上限。デフォルト 10 |
| `steps` | list | step の配列。先頭から開始する |

#### step のフィールド

| フィールド | 型 | 必須 | 説明 |
| --- | --- | --- | --- |
| `name` | string | ○ | step 名（workflow 内で一意） |
| `persona` | string | ○ | `system` に付与するテキスト |
| `instruction` | string | ○ | user メッセージの本文（テンプレート変数が使える） |
| `model` | string | | この step で使うモデル。省略時はセッションのモデル（`/model` 反映後） |
| `rules` | list | | 出力末尾のマーカーによる分岐。`{ marker = "<NAME>", next = "<step名>" }` |
| `next` | string | | `rules` が無い step の遷移先。省略時は配列の次の step。最後の step で省略すると `COMPLETE` |
| `edits` | boolean | | `true` の step は SEARCH/REPLACE で変更を出す step とみなし、出力開始行を `gA` の対象範囲の起点として記録する。デフォルト `false` |

- `next` の予約語：`COMPLETE`（正常終了）/ `ABORT`（中断）。
- モデルごとの接続先は、既存の `providers` を step の `model` で解決する。

#### テンプレート変数（`instruction` 内）

| 変数 | 展開内容 |
| --- | --- |
| `{task}` | `/workflow` に渡されたタスク本文（`@` コンテキスト展開済み） |
| `{previous_response}` | 直前の step の出力全文（マーカー行を除く） |
| `{last_edit}` | 直近の `edits = true` の step の出力全文（マーカー行を除く）。まだ実行されていなければ空文字 |
| `{iteration}` | 現在までに実行した step 数（1 始まり） |

未知の変数はそのまま残す（エラーにしない）。

### 遷移の判定

- `rules` を持つ step には、Lua が `instruction` の末尾に次の指示を自動で追記する。

  ```text
  最後の行に、次のいずれか 1 つだけを単独の行として出力してください：
  [APPROVE] / [REJECT]
  ```

- 出力の**最後に現れた** `^\[(%u[%u_]*)\]$` の単独行を採用し、`rules` の `marker` と照合する。
- マッチしない（マーカーが無い／未定義のマーカー）場合は `ABORT`。出力ペインにエラーを表示する。
- `rules` を持たない step は、出力内容に関係なく `next`（または配列の次）へ進む。
- 遷移の判断を AI に委ねない：AI はマーカーを出力するだけで、次の step は Lua が決める。

### 実行モデル

- 各 step は**独立したリクエスト**。`messages` は `instruction` 展開後の user 1 件のみで、チャットの `state.messages` は参照も更新もしない。step 間の受け渡しは `{task}` / `{previous_response}` / `{last_edit}` だけ。
- `system` は `BASE_SYSTEM` + `CLAUDE.md` + step の `persona`（+ `/system` で設定されたテキスト）+ workflow 共通の注意書き。
- workflow 共通の注意書き：`BASE_SYSTEM` は情報不足のときにユーザーへ `` @cmd:`...` `` の実行を依頼するよう AI に指示しているが、workflow の途中ではそれを受け取る人がいない。そこで各 step の `system` の末尾に「この workflow 中はコマンドを実行できず、実行の依頼もしない。与えられた情報だけで判断し、足りない情報があれば出力にその旨を明記する」という指示を自動で追加する。必要なコマンド出力は、ユーザーが task に `@cmd` で先に含めておく。
- `@` コンテキスト（`@buf` / `@file` / `@cmd` など）は `/workflow` 実行時に**1 回だけ**展開して `{task}` に埋め込む。`@cmd` が step ごとに再実行されることはない。スティッキーも開始時に 1 回だけ付与する。
- step の実行中は通常のチャット送信と二重の `/workflow` を拒否する（`state.job_id` と同様のガード）。
- `<C-c>`（`stop_job`）で実行中の step を停止し、workflow 全体を中断する。
- 実行 step 数が `max_steps` に達したら `ABORT` する。

### UI

- 出力ペインに step の見出しを出す。

  ```text
  --- workflow: default ---

  ### [1/10] plan (claude-opus-4-7)

  （ストリーミング出力）

  --- usage: ... ---

  ### [2/10] implement (claude-sonnet-4-6)
  ...
  --- workflow: COMPLETE (4 steps) ---
  ```

- usage 表示は step ごとに既存のロジックで出す。
- スピナーのラベルは step 名を含める（例：`review: 生成中...`）。
- 終了時は `--- workflow: COMPLETE|ABORT (<n> steps) ---` を出す。`ABORT` のときは理由（マーカー無し／`max_steps` 到達／API エラー／ユーザー停止）を続けて出す。

### コマンド

```text
/workflow <task>            default workflow を実行
/workflow <name> <task>     名前を指定して実行
/workflow                   定義済み workflow の一覧を出力ペインに表示
```

- 一覧には各 workflow の出所（`builtin` / `global` / `local`）を併記する。同名で上書きされた場合は、採用された側の出所を表示する。

- 第 1 引数が（マージ後の）`workflows` のキーに一致すればそれを workflow 名とみなし、残りを task とする。一致しなければ全体を task として `default` を使う。
- task が空の場合はエラー（`/workflow requires a task`）。

## 実装

### `lua/ai-chat/chat.lua`（リファクタ）

`send()` 内のリクエスト実行部分（`job.start` と `on_text` / `on_done` / `on_error` / `on_usage` の組み立て）を、モジュール内関数 `run_request(opts, req, cb)` に切り出す。`send()` は従来の挙動のまま `run_request` を呼び、`/workflow` も同じ関数を使う。

- `req`：`{ model, system, messages, label_prefix }`（`label_prefix` はスピナーのラベルの前置き。workflow では `<step名>: `）
- `cb`：
  - `on_done(text)`：ストリーム完了時（累積した応答全文）。usage の表示より前に呼ばれうる。`send()` はここで assistant メッセージを `state.messages` に積む。
  - `on_complete(text)`：Deno プロセスが正常終了（exit 0）した後。usage の表示まで済んでいる。workflow はここで次の step に進む（usage 行が次の step の出力に混ざらないようにするため）。
  - `on_error(msg)`：エラー時。stderr と終了コードの両方から複数回呼ばれうるため、呼び出し側で 1 回に絞る。
- 出力ペインへの追記、スピナー、usage 表示は `run_request` が共通で行う。
- `build_system(user_system, persona, notice)` に拡張し、`BASE_SYSTEM` + `CLAUDE.md` + persona + `state.system` + notice の順に連結する。
- `M.run_workflow(opts, full_rest)` を追加する。引数の解釈・検証・`@` コンテキストの展開・`workflow.run` の呼び出しを行う。実行中は `state.workflow`（`{ cancelled }`）を持ち、`send()` はこれがあれば送信を拒否する。`stop_job()` は `state.workflow.cancelled = true` にしてからジョブを止める（中断時は `[ERROR]` を表示しない）。

### `lua/ai-chat/diff.lua` / `lua/ai-chat/chat.lua`（`gA` の範囲限定）

- `diff.find_all_blocks(buf, start_line)`：第 2 引数（任意）を追加し、指定行以降のブロックだけを返す。省略時は従来どおり全ブロック。
- `chat.apply_all_blocks()`：`state.workflow_edit_start` を `find_all_blocks` に渡す。
- `edits = true` の step の見出しを出した直後に、出力バッファの最終行の行番号を `state.workflow_edit_start` に記録する（step の出力はこの最終行に追記されるため、出力が先頭のフェンスで始まっても対象に入る）。`find_all_blocks` は `start_line` 以上で始まるブロックを返す。
- `commands.lua` の `/clear` と `chat.send()`（通常のチャット送信）で `state.workflow_edit_start = nil` にする。

### `lua/ai-chat/workflow.lua`（新規）

- `M.load_local()`：`<cwd>/.ai-chat/workflows.lua` を `vim.secure.read()` で読み、`loadstring` で評価してテーブルを返す。ファイルが無い／trust 拒否の場合は `nil`、評価エラーの場合は `nil` とエラーメッセージを返す。
- `M.resolve(opts)`：ビルトイン `default` < `opts.workflows`（グローバル）< `load_local()`（ローカル）の順にマージし、`{ [name] = { def = ..., source = "builtin"|"global"|"local" } }` を返す。`/workflow` の実行ごとに呼ぶ。
- `M.run(def, name, task, env)`：workflow の実行ループ。`chat.lua` に依存せず、副作用は `env` 経由で行う（テストでは偽の `env` を渡す）。
  - `env.model_for(step)` / `env.request(step, user_text, cb)` / `env.print(lines)` / `env.mark_edit_start()` / `env.is_cancelled()` / `env.on_end()`
- `M.validate(def)`：定義の検証（steps が空／step 名の重複・予約語／必須フィールド欠落／`next`・`rules` の遷移先が存在しない／マーカー名が大文字でない／`max_steps` が不正）。実行前に呼び、問題があれば `[ERROR]` を表示して実行しない。
- `M.next_step(def, step, marker)`：次の遷移先（step 名 / `COMPLETE` / `ABORT`）と ABORT の理由を返す純粋関数。
- `M.build_instruction(step, vars)`：`instruction` の展開と、`rules` があるときのマーカー指示の追記。
- `M.parse_args(full_rest, map)` / `M.list_lines(map)` / `M.merge(global, local)`：引数の分解・一覧表示・マージ（純粋関数）。
- `M.NOTICE`：workflow 共通の注意書き。
- `M.default`：ビルトインの `default` workflow 定義（persona / instruction は日本語）。
- `render(template, vars)`：`{task}` / `{previous_response}` / `{iteration}` の展開。
- `parse_marker(text)`：最後のマーカー行を取り出し、マーカーを除いた本文と一緒に返す。
- 実行ループの骨子：

  ```lua
  local function run_step(step, ...)
    -- 1. instruction を render（rules があればマーカー指示を追記）
    -- 2. chat.run_request で実行
    -- 3. on_done: parse_marker → rules / next で次の step を決定
    -- 4. COMPLETE / ABORT / max_steps で終了処理
  end
  ```

### `lua/ai-chat/commands.lua`

`handlers.workflow` を追加し、`ctx.run_workflow(full_rest)` に委譲する。ハンドラには第 5 引数として「コマンド名以降の全文」（2 行目以降を含む）を渡すよう `M.handle` を拡張する（task は複数行になりうるため）。`@` コンテキストの展開は `chat.lua` 側（`context.build_user_content`）を使う。`/clear` は `state.workflow_edit_start` もリセットする。

### `lua/ai-chat/init.lua`

`default_opts.workflows` を追加する（デフォルトは空テーブル）。ビルトイン `default` とのマージは `workflow.resolve()` が行うため、`setup()` 時点ではユーザーが渡したグローバル定義をそのまま保持する。同名 workflow は丸ごと置き換わる（step 単位のマージはしない）ので、`default` の steps を一部だけ変えたい場合も steps 全体を書く必要がある。

### ビルトイン `default` workflow の中身

| step | persona（要旨） | instruction（要旨） | model | 遷移 |
| --- | --- | --- | --- | --- |
| plan | 設計担当。実装はしない | `{task}` から変更方針と対象ファイルを箇条書きで出す | セッションのモデル | → implement |
| implement | 実装担当 | `{previous_response}`（plan の出力）の計画に従い、SEARCH/REPLACE 形式で変更を出す | セッションのモデル | → review |
| review | レビュー担当。問題点の指摘のみ（コードブロックは使わない） | `{task}` と `{last_edit}` の実装をレビュー。`TODO:` コメントは未決定部分の意図的な印として許容（指摘しない）。問題なければ `[APPROVE]`、あれば指摘と `[REJECT]` | セッションのモデル | APPROVE → COMPLETE / REJECT → fix |
| fix | 修正担当 | `{last_edit}`（前回の実装）と `{previous_response}`（レビューの指摘）から、元のファイルに対する変更全体を SEARCH/REPLACE 形式で出し直す | セッションのモデル | → review |

- implement / fix は `edits = true`。
- 「未決定部分は `TODO:` コメントで残す」という指示は developer（implement / fix）側の persona には入れず、ユーザーがタスク入力時に書く。review はコード中の `TODO:` コメントを未完成として REJECT しない。
- 変更は workflow 中に適用されない（元のファイルのまま）ため、fix は前回の実装との差分ではなく、元のファイルに対する変更全体を出し直す。そのために fix には `{last_edit}` を渡す。
- plan の出力は implement にだけ渡る（review には `{task}` と実装を渡す）。
- ビルトインではモデルを固定しない（利用者の `providers` / モデル設定に依存させないため）。モデルを分けたい場合はユーザーが `workflows.default` を上書きする。

## テスト

Lua 側のテスト基盤を、この機能に先立って導入する（実装より先に基盤を作る）。外部プラグイン（plenary 等）には依存せず、Neovim 本体だけで動く自前の最小ランナーにする。

### 配置と実行

- 置き場所は `test/lua/`（既存の `test/` は LSP diagnostics 確認用のフィクスチャ置き場で、そこに `lua/` サブディレクトリを足す）。
- ランナー：`test/lua/run.lua`。テストファイルは `test/lua/*_test.lua`。
- 実行コマンド（リポジトリルートで）：

  ```bash
  nvim --headless -u NONE -l test/lua/run.lua
  ```

  全テスト成功で終了コード 0、1 つでも失敗すれば 1。

### ランナーの仕様

- 起動時に `package.path` へ `<repo>/lua/?.lua` と `<repo>/lua/?/init.lua` を追加し、`require("ai-chat.xxx")` が通るようにする。リポジトリルートは `run.lua` 自身のパスから求める。
- `test/lua/*_test.lua` を名前順に読み込む。各ファイルは `{ ["テスト名"] = function() ... end }` を `return` する。
- 各テストは `pcall` で実行し、失敗しても残りを続ける。出力は `ok` / `FAIL` + テスト名で、失敗時はエラーメッセージを添える。最後に `n passed, m failed` を出す。
- アサーションは標準の `assert` に加え、`test/lua/helper.lua` の `eq(actual, expected)`（`vim.deep_equal` で比較し、不一致時は両方を `vim.inspect` で出す）を使う。

### テスト対象

- 基盤の動作確認として、既存の純粋関数 `context.extract_token_keys`（`@` トークンの抽出）のテストを先に書く（`test/lua/context_test.lua`）。
- workflow 実装時に追加したテスト（`test/lua/workflow_test.lua`、`test/lua/diff_test.lua`）：`workflow.render`（テンプレート展開・未知変数の保持）、`workflow.parse_marker`（最後のマーカー行の採用・マーカー無し・マーカー除去後の本文）、`workflow.resolve`（ビルトイン < グローバル < ローカルのマージと出所）、遷移判定（`rules` / `next` / `COMPLETE` / `ABORT` / `max_steps`）、`validate`、`parse_args`、偽の `env` を使った実行ループ（承認・却下ループ・マーカー無し・`max_steps`・エラー・ユーザー中断）、`diff.find_all_blocks` の開始行指定。
- 対象外：UI（ウィンドウ・スピナー）と実際の API 通信。これらは手動確認とする（偽の `deno` を PATH に置いて `/workflow` を通しで動かす確認は実装時に行った）。
- Deno 側は今回変更しないため、テストを追加しない（`deno task test` は従来どおり）。

## 決定事項

- 遷移はマーカー行（`[NAME]`）のパースで決める。判定専用の追加リクエスト（takt 方式）は行わない（リクエスト数とコストを増やさないため）。
- 各 step は独立した `messages` で実行し、チャットの `state.messages` には書き込まない。workflow 後にチャットで続きを話したい場合は、出力ペインの内容を参照させる（`gp` などの既存手段）。
- ファイル適用は既存の差分適用（`ga` / `gA`）に任せ、workflow が自動適用することはしない。
- `rules` のマーカーが取れなかった場合は推測せず `ABORT` する。
- 次の step へは `on_complete`（Deno プロセス終了後）で進む。ストリーム完了（`on_done`）の時点では usage が未着のことがあり、次の step の出力に usage 行が混ざるため。
- `@cmd` は workflow 開始時に 1 回だけ実行する（スティッキー非対応の方針は維持）。workflow 中は作業ツリーが変わらない（変更は `ga` / `gA` で適用されるまで反映されない）ため、step ごとに再実行しても同じ出力にしかならず、時間と副作用のコストだけが増える。全 step で 1 回のスナップショットを共有する。
- workflow 中の AI による `@cmd` 実行依頼は、各 step の `system` で禁止する（受け取る人がいないため）。必要なコマンドはユーザーが task に先に含める。
- **`gA` の対象範囲**：workflow が implement / fix のように変更（SEARCH/REPLACE ブロック）を出す step を実行するたびに、その step の出力開始行を `state.workflow_edit_start` に記録する（上書き）。`gA` は `state.workflow_edit_start` があればそれ以降のブロックだけを対象にし、無ければ従来どおり全ブロックを対象にする。古い反復で出たブロックは適用されない。`/clear` と通常のチャット送信で `state.workflow_edit_start` をリセットする。
  - 「変更を出す step」は、step に `edits = true` を付けて明示する（ビルトインでは implement / fix）。
  - `ga`（カーソル位置のブロックのみ）は影響を受けない。
- **ローカル設定は Lua ファイル `<cwd>/.ai-chat/workflows.lua`**。JSON は persona / instruction のような長い複数行の文字列が書きづらいため採用しない。コード実行のリスクは `vim.secure.read()` の trust 確認で担保する（Neovim 0.9 以上で利用可能で、プロジェクトの前提バージョンと同じ）。
- グローバルとローカルは**同名なら workflow 単位で置き換え**、異名なら共存させる。優先順位はビルトイン < グローバル < ローカル。
- ローカル定義の探索は `getcwd()` のみ。親ディレクトリへの遡りやプロジェクトルート判定（`.git` 探索など）はしない。
- Lua のテストは外部プラグインを使わない自前ランナー（`test/lua/run.lua`）で行う。配置は既存の `test/` 配下の `test/lua/`。
- YAML 定義、Faceted Prompting 風のプロンプト分離（policy / knowledge / output contract）、並列 step（`all()` / `any()`）、worktree 隔離、`takt eject` 相当は**初期版のスコープ外**。

## 使い方

```text
/workflow @file:lua/ai-chat/job.lua のタイムアウト処理を追加して
/workflow review @buf このバッファのコードをレビューして
```

```lua
require("ai-chat").setup({
  workflows = {
    review = {
      steps = {
        { name = "review", persona = "あなたはコードレビュアーです。", instruction = "{task}" },
      },
    },
  },
})
```

ローカル定義（プロジェクト専用）の例：

```lua
-- <project>/.ai-chat/workflows.lua
return {
  default = {
    max_steps = 6,
    steps = {
      { name = "implement", persona = "このプロジェクトの実装担当。", instruction = "{task}", edits = true },
    },
  },
}
```

## 参考

- [TAKT の紹介記事（Zenn）](https://zenn.dev/nrs/articles/c6842288a526d7)
- `doc/deepseek-provider-spec.md`（`providers` によるモデルごとの接続先切り替え）
- `doc/cmd-context-spec.md`（`@cmd` コンテキスト）
