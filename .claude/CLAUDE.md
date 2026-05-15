# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## プロジェクト概要

Neovim 上で動作する AI チャットプラグイン。**Lua（UI／Neovim 連携）と Deno（Anthropic API 通信）を `jobstart()` で分離する 2 言語アーキテクチャ**が最大の特徴。外部 Neovim プラグイン依存は持たない（スタンドアロン）。

完全な仕様は `doc/spec.md` に集約されている。実装方針・UI 挙動・キーマップ・プロトコル詳細はすべて spec.md が正典。実装と spec.md が食い違ったら、まず spec.md 側を更新するか、ズレた理由を明確にしてから着手すること。

## 現在のリポジトリ状態

- 実装はまだ存在しない。トラックされているのは `doc/spec.md` のみ。
- spec.md で計画されているディレクトリ構成は `plugin/ai-chat.lua` / `lua/ai-chat/*.lua` / `deno/{main,api}.ts`。
- ビルド・テスト・リントのコマンドはまだ定義されていない。導入する際はこの CLAUDE.md にも追記すること。

## アーキテクチャの肝

- **Deno プロセスはリクエスト毎に都度起動・終了する**。常駐プロセスではない。会話履歴などの状態は Lua 側だけが保持する。
- Lua → Deno：stdin に JSON 一発（`model`, `system`, `messages`, `max_tokens`）。
- Deno → Lua：stdout にストリーミング delta をテキストで逐次書き出し、終端に `\n[DONE]\n` を出力。Lua 側はこの `[DONE]` を区切りとしてストリーム完了を判定する。
- エラーは stderr へ。Lua 側 `on_stderr` でチャットウィンドウに表示する。
- Anthropic SDK (`@anthropic-ai/sdk`) は Deno 側でのみ使う。Lua 側から HTTP を直接叩かない。
- API キーは環境変数 `ANTHROPIC_API_KEY`（Deno プロセス側で読む）。

## 守るべき設計ルール

- **コンテキストは `@` プレフィックスで明示指定する方式のみ**。自動挿入はしない。対応タイプは `@buf` / `@bufs` / `@sel` / `@file:<path>` / `@diag` の 5 種。新しいタイプを足す際は spec.md の表を更新する。
- スティッキーコンテキストは**セッションスコープ**（チャットを閉じたらリセット）。プロンプト送信時に先頭へ自動付与するが、ユーザーが本文中で明示指定したものと重複させない。
- **差分適用のコードブロックヘッダは ` ```<lang>:<path> ` 形式**でファイルパスを指定する規約（例: ` ```lua:lua/ai-chat/chat.lua `）。ヘッダにパスが無い場合は、チャットを開く直前にフォーカスしていた編集バッファを対象とする。AI への指示プロンプトにもこの規約を含める想定。
- チャット出力ペインは `filetype=ai-chat` / Markdown シンタックス / `nomodifiable`。出力は追記のみ。入力ペインは別バッファとして 2 ペイン構成。

## 実装の進め方

`doc/spec.md` の「実装ステップ」に定義された **Step 1 → 5 の順**で進める。前ステップの完了条件を満たすまで次へ進まない。先回り実装はしないこと（例：Step 1 でスティッキー UI を作り込まない、Step 2 で差分適用ロジックを書き始めない）。

各ステップで実装すべき範囲・完了条件は spec.md が正典。実装と spec.md にズレが生じたら spec.md を先に更新する。

## 依存とスコープ

- Neovim >= 0.9 / Deno >= 1.40（PATH 必須）/ `ANTHROPIC_API_KEY`。
- **Neovim プラグイン依存は追加しない**（plenary 等を含めて）。スタンドアロンであることが設計上の制約。
- spec.md「未対応（スコープ外）」に挙がっている項目は実装しないこと：マルチプロバイダー対応、telescope / fzf-lua 連携、セッション保存・復元、ビジュアルモードでのインライン編集。スコープ拡張が必要になったら、まず spec.md を更新して合意を取ってから。

## コミュニケーション

このリポジトリではユーザー向けの応答は日本語で行う。
