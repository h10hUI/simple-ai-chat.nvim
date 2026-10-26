# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## プロジェクト概要

Neovim 上で動作する AI チャットプラグイン。**Lua（UI／Neovim 連携）と Deno（Anthropic API 通信）を `jobstart()` で分離する 2 言語アーキテクチャ**が最大の特徴。外部 Neovim プラグイン依存は持たない（スタンドアロン）。

完全な仕様は `doc/spec.md` に集約されている。実装方針・UI 挙動・キーマップ・プロトコル詳細はすべて spec.md が正典。実装と spec.md が食い違ったら、まず spec.md 側を更新するか、ズレた理由を明確にしてから着手すること。

## 現在のリポジトリ状態

- `doc/spec.md` の Step 1〜5 はすべて実装済み。以降は個別の機能追加として、機能ごとの仕様ファイルを `doc/` に置く方式で進めている。
  - `doc/deepseek-provider-spec.md`：モデル名に応じた接続先の切り替え（`providers`）。
  - `doc/cmd-context-spec.md`：`@cmd` コンテキスト（外部コマンド出力の添付）。
- ディレクトリ構成：`plugin/ai-chat.lua` / `lua/ai-chat/{init,chat,commands,context,diff,job}.lua` / `deno/{main,api}.ts`。
- Deno 側のタスクは `deno/deno.json` に定義されている（`run` / `fmt` / `lint` / `test`）。Lua 側のテスト・リントは未導入。導入する際はこの CLAUDE.md にも追記すること。

## アーキテクチャの肝

- **Deno プロセスはリクエスト毎に都度起動・終了する**。常駐プロセスではない。会話履歴などの状態は Lua 側だけが保持する。
- Lua → Deno：stdin に JSON 一発（`model`, `system`, `messages`, `max_tokens`）。
- Deno → Lua：stdout にストリーミング delta をテキストで逐次書き出し、終端に `\n[DONE]\n` を出力。Lua 側はこの `[DONE]` を区切りとしてストリーム完了を判定する。
- エラーは stderr へ。Lua 側 `on_stderr` でチャットウィンドウに表示する。
- Anthropic SDK (`@anthropic-ai/sdk`) は Deno 側でのみ使う。Lua 側から HTTP を直接叩かない。
- API キーは環境変数 `ANTHROPIC_API_KEY`（Deno プロセス側で読む）。`providers` にマッチしたモデル（例: DeepSeek）では、Lua 側が `api_key_env` の値を `ANTHROPIC_API_KEY` として Deno に渡し、`--allow-net` もその host に絞る。キー未設定時は Anthropic のキーにフォールバックせずエラーにする。
- 外部コマンドの実行は Lua 側（`@cmd`）だけで行う。AI の応答に含まれるコマンドの自動実行（tool use）はしない。必要なときは AI がユーザーに `` @cmd:`...` `` の実行を依頼する（`BASE_SYSTEM` で指示）。

## 守るべき設計ルール

- **コンテキストは `@` プレフィックスで明示指定する方式のみ**。自動挿入はしない。対応タイプは `@buf` / `@bufs` / `@sel` / `@file:<path>` / `@diag` / `` @cmd:`<command>` `` の 6 種。新しいタイプを足す際は spec.md の表を更新する。
- `@cmd` はスティッキー非対応（送信のたびに再実行されるため）。出力はチャット出力ペインにも表示する。
- スティッキーコンテキストは**セッションスコープ**（チャットを閉じたらリセット）。プロンプト送信時に先頭へ自動付与するが、ユーザーが本文中で明示指定したものと重複させない。
- **差分適用のコードブロックヘッダは ` ```<lang>:<path> ` 形式**でファイルパスを指定する規約（例: ` ```lua:lua/ai-chat/chat.lua `）。ヘッダにパスが無い場合は、チャットを開く直前にフォーカスしていた編集バッファを対象とする。AI への指示プロンプトにもこの規約を含める想定。
- チャット出力ペインは `filetype=ai-chat` / Markdown シンタックス / `nomodifiable`。出力は追記のみ。入力ペインは別バッファとして 2 ペイン構成。

## 実装の進め方

基本ステップ（`doc/spec.md` の Step 1 → 5）は完了済み。新機能は次の手順で進める。

1. 機能ごとの仕様ファイルを `doc/` に作る（`doc/deepseek-provider-spec.md` と同じ形式：目的／変更不要な箇所／設計／実装／決定事項）。
2. ユーザーが「実装して」と言うまで `lua/` や `deno/` は編集しない。仕様の合意が先。
3. 実装後、`doc/spec.md`・`README.md`・この CLAUDE.md に影響する箇所を更新する。

先回り実装はしないこと。実装と spec にズレが生じたら spec を先に更新する。

## 依存とスコープ

- Neovim >= 0.9 / Deno >= 1.40（PATH 必須）/ `ANTHROPIC_API_KEY`。
- **Neovim プラグイン依存は追加しない**（plenary 等を含めて）。スタンドアロンであることが設計上の制約。
- spec.md「未対応（スコープ外）」に挙がっている項目は実装しないこと：マルチプロバイダー対応、telescope / fzf-lua 連携、セッション保存・復元、ビジュアルモードでのインライン編集。スコープ拡張が必要になったら、まず spec.md を更新して合意を取ってから。

## コミュニケーション

- ユーザー向けの応答は日本語で行う。
- **ユーザーの環境は正しい前提で動く**。「ファイルが本当にあるか」「パスが正しいか」「カレントディレクトリは合っているか」のような切り分け質問を重ねない。ユーザーが既に伝えた事実（cwd、エラー内容、設定状況）を疑い直さない。
- **エラーが起きたら、まず自分（Claude）の直近の変更・指示・コード生成を疑う**。実装側のバグ、コマンドの組み立てミス、プロトコル/プロセス設計のズレ、前提の取り違えを優先的に確認する。
- 過剰な選択肢提示・段階的切り分け・確認質問の連発をしない。一度で済む解決策を出す。同じトラブルで 2 ターン以上やり取りが続いたら、それは自分の出力が冗長か的外れな兆候。
