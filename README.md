# simple-ai-chat.nvim

A minimal, zero-dependency AI chat plugin for Neovim that talks to the
Anthropic Claude API (and Anthropic-compatible endpoints such as DeepSeek). UI
and keybindings are written in Lua. API communication
is handled by a Deno script spawned per request via `jobstart()`. No Neovim
plugin dependencies.

## Features

- Two-pane chat window (output + input) with streaming responses
- Context tokens for injecting code into prompts: `@buf`, `@bufs`, `@sel`, `@file:<path>`, `@diag`, `` @cmd:`<command>` ``
- Sticky context pinned across the session (shown in the input pane's winbar)
- Slash commands: `/clear`, `/quit`, `/pin`, `/unpin`, `/model`, `/system`, `/workflow`
- `/model` with no arguments shows the current model (session override or configured default)
- Workflows: run a plan → implement → review → fix loop with multiple personas
  (`/workflow`), with transitions decided by the plugin, not the AI
- Diff-and-apply for AI-generated code blocks, with SEARCH/REPLACE patch format
- LSP diagnostics integration (Neovim builtin LSP + coc.nvim)
- Per-model provider routing: switch between Claude and Anthropic-compatible
  endpoints (e.g. DeepSeek) with `/model`
- Automatic `~/.claude/CLAUDE.md` / `CLAUDE.md` / `.claude/CLAUDE.md` loading (with `@import` expansion) as system prompt
- Visual selection via `<leader>ac` automatically populates `@sel`

## Requirements

- Neovim >= 0.9
- [Deno](https://deno.com/) >= 1.40 on `PATH`
- `ANTHROPIC_API_KEY` environment variable
- API key environment variable for each additional provider (e.g.
  `DEEPSEEK_API_KEY`), if used

## Installation

With [lazy.nvim](https://github.com/folke/lazy.nvim):

```lua
{
  "h10hUI/simple-ai-chat.nvim",
  lazy = false,
  config = function()
    require("ai-chat").setup({
      -- defaults shown; everything is optional
      model = "claude-sonnet-4-6",
      max_tokens = 8096,
      -- Route models to other Anthropic-compatible endpoints (default: none)
      providers = {
        -- {
        --   match = "^deepseek",
        --   base_url = "https://api.deepseek.com/anthropic",
        --   api_key_env = "DEEPSEEK_API_KEY",
        -- },
      },
      window = {
        width = 0.4,
        input_height = 5,
        side = "left",
      },
    })
  end,
}
```

On first run, the Deno script will fetch its npm dependencies automatically.

### Providers

Each `providers` entry has:

| Field | Description |
| --- | --- |
| `match` | Lua pattern tested against the model name |
| `base_url` | Anthropic-compatible endpoint URL |
| `api_key_env` | Name of the environment variable holding the API key |

Entries are evaluated in order and the first match wins. A model that matches
no entry is sent to Anthropic (`api.anthropic.com`) as before. The model name
is the one currently in effect, including changes made with `/model`.

For a matching provider, the Deno process is started with `--allow-net` limited
to the `base_url` host, and `ANTHROPIC_BASE_URL` / `ANTHROPIC_API_KEY` are set
for that process only. If `api_key_env` is unset or empty, the request is
aborted with an error (your `ANTHROPIC_API_KEY` is never sent to the provider).

Example with DeepSeek:

```lua
require("ai-chat").setup({
  providers = {
    {
      match = "^deepseek",
      base_url = "https://api.deepseek.com/anthropic",
      api_key_env = "DEEPSEEK_API_KEY",
    },
  },
})
```

```text
/model deepseek-flash
/model deepseek-v4-pro
/model claude-sonnet-4-6   ← back to Anthropic
```

Notes:

- Do not point `ANTHROPIC_BASE_URL` at a provider in your shell; it would also
  redirect other tools such as Claude Code. Keep the endpoint in `providers`
  and only export the provider's API key.
- `/clear` resets the session model to the configured default, so the provider
  follows the default model afterwards.
- DeepSeek models may spend tokens on thinking before the answer, so a very
  small `max_tokens` can yield an empty reply.

## Usage

### Global keymaps

| Key | Action |
| --- | --- |
| `<leader>ac` | Open chat / toggle focus between panes |
| `<leader>ac` (visual) | Open chat with selection pre-loaded as `@sel` |
| `<leader>aq` | Close chat |

User commands: `:AiChatOpen`, `:AiChatClose`, `:AiChatToggle`.

### Output pane keymaps

| Key | Action |
| --- | --- |
| `i` | Focus input pane |
| `<C-c>` | Stop streaming |
| `gp` | Pin the `@token` under cursor to sticky context |
| `ga` | Apply diff for code block at cursor |
| `gA` | Apply all code blocks sequentially |
| `gy` | Yank code block at cursor |
| `]]` / `[[` | Jump to next/previous code block |

### Input pane keymaps

| Key | Mode | Action |
| --- | --- | --- |
| `<CR>` | normal | Send |
| `<C-CR>` | insert | Send |
| `<C-c>` | normal/insert | Stop streaming |
| `<Esc>` | normal | Focus output pane |
| `<C-j>` | normal | Focus output pane |
| `<Up>` / `<Down>` | normal | Prompt history |

### Context tokens

Reference these `@` tokens in your prompt and they are expanded into the
message sent to Claude:

| Token | Content |
| --- | --- |
| `@buf` | The buffer focused before opening chat |
| `@bufs` | All loaded regular buffers (visible or hidden) |
| `@sel` | Last visual selection (auto-populated when chat is opened from visual mode) |
| `@file:<path>` | Contents of the given file |
| `@diag` | LSP diagnostics of the original buffer (Neovim builtin LSP + coc.nvim) |
| `` @cmd:`<command>` `` | Output of an external command (run via `sh -c`, 10s timeout; not pinnable) |

Example:

```
@diag fix all the errors please
@cmd:`git diff --staged` write a commit message for this
```

`@cmd` runs the command with `sh -c` in Neovim's cwd when you send the prompt
and attaches its stdout/stderr (a non-zero exit code is noted). The output is
also shown in the output pane right after your prompt. It times out after 10
seconds and is truncated at 100,000 bytes. Use backticks when the command
contains spaces; a bare `@cmd:ls` also works. `@cmd` cannot be pinned, because
pinned tokens would re-run on every send.

The AI never runs commands itself. The built-in system prompt tells it to ask
you to run `` @cmd:`...` `` when it needs command output.

### Sticky context

Tokens can be pinned to apply automatically on every send. Pinned tokens are
shown on the winbar above the input pane (e.g. `📌 @buf @diag`). Tokens
already present in the prompt body are not duplicated.

- `/pin @buf @diag` — add
- `/unpin @buf` — remove one
- `/unpin` — clear all
- `gp` (output pane) — pin the token under cursor

### Slash commands

Type these in the input pane:

| Command | Action |
| --- | --- |
| `/clear` | Clear conversation history (output pane keeps its log) |
| `/quit` | Close chat |
| `/pin <tokens...>` | Add tokens to sticky context |
| `/unpin [tokens...]` | Remove (or clear all if no args) |
| `/model [name]` | Switch model for the session (no arguments: show the current model) |
| `/system <text>` | Append additional system prompt for the session |
| `/workflow [name] <task>` | Run a workflow (see below). Without arguments, list workflows |

### Workflows

`/workflow` runs a sequence of steps, each one an independent request with its
own persona. The built-in `default` workflow is
plan → implement → review → (fix → review)…, ending when the reviewer
approves or `max_steps` (default 10) is reached.

```
/workflow @file:lua/ai-chat/job.lua add a timeout
/workflow review @buf review this buffer
/workflow @cmd:`git diff` @cmd:`deno task test` fix the failing test
```

- If the first word matches a workflow name it selects that workflow;
  otherwise the whole text is the task for `default`.
- `@` context tokens (including `@cmd`) and sticky context are expanded once,
  when the workflow starts. The AI cannot run commands during a workflow, so
  put any command output it needs in the task (`` @cmd:`git diff` ``).
- Transitions are decided by the plugin: a step with `rules` must end with a
  marker line such as `[APPROVE]` / `[REJECT]`. A missing or unknown marker
  aborts the workflow.
- Press `<C-c>` to stop. Edits are never applied automatically: use `ga` /
  `gA`. After a workflow, `gA` only applies the blocks from the last step that
  produced edits, so superseded blocks from earlier iterations are skipped.

Define workflows globally in `setup()` or per project in
`<cwd>/.ai-chat/workflows.lua`. Project definitions override global ones, which
override the built-in `default`, by name (a workflow is replaced as a whole).
The project file is loaded through `vim.secure.read()`, so Neovim asks you to
trust it first.

```lua
-- <project>/.ai-chat/workflows.lua  (or `workflows = { ... }` in setup())
return {
  review = {
    max_steps = 4,
    steps = {
      { name = "review", persona = "You are a code reviewer.", instruction = "{task}" },
    },
  },
}
```

Step fields: `name`, `persona`, `instruction` (required); `model`, `rules`
(`{ marker = "APPROVE", next = "COMPLETE" }`), `next`, `edits` (optional).
`instruction` can use `{task}`, `{previous_response}`, `{last_edit}` (output of
the latest `edits = true` step) and `{iteration}`. `next` / rule targets are a
step name, `COMPLETE` or `ABORT`. See [doc/workflow-spec.md](doc/workflow-spec.md).

### Diff and apply

The plugin sends a built-in system prompt that instructs Claude to return
code edits as SEARCH/REPLACE blocks:

````
```typescript:src/foo.ts
<<<<<<< SEARCH
const x = 1;
=======
const x = 2;
>>>>>>> REPLACE
```
````

A code block without SEARCH/REPLACE markers is treated as a whole-file
replacement. Multiple SEARCH/REPLACE pairs can live inside a single code
block.

When you press `ga` on a code block, a new tab opens with a vimdiff view:
left = current file, right = result after applying the patch. Edit the right
pane to selectively reject hunks (`do` pulls from the left, undoing that
change), then press `<CR>` to commit. Press `q` to cancel. Use `]]` / `[[` to
jump between hunks inside the diff tab as well.

If the code block targets a path that does not exist, the file (and its
parent directories) is created on apply.

### CLAUDE.md auto-loading

On each send, the following are appended to the system prompt (before any
`/system` text):

1. `~/.claude/CLAUDE.md` (user-global)
2. `<cwd>/CLAUDE.md`, or `<cwd>/.claude/CLAUDE.md` if the former is absent

Parent-directory CLAUDE.md files are not loaded. `@path` imports inside
CLAUDE.md are expanded recursively (max depth 5): paths are relative to the
importing file, `~/` and absolute paths work, and `@...` inside code spans /
fenced blocks is left alone. Missing files and circular imports are left as-is.
Other files under `.claude/` are only loaded when imported this way.

This follows the convention used by Claude Code.

## Architecture

```
Neovim (Lua)
  │
  ├── UI & keymaps         (lua/ai-chat/chat.lua, plugin/ai-chat.lua)
  ├── Context expansion    (lua/ai-chat/context.lua)
  ├── CLAUDE.md loading    (lua/ai-chat/claude_md.lua)
  ├── Slash commands       (lua/ai-chat/commands.lua)
  ├── Workflows            (lua/ai-chat/workflow.lua)
  ├── Diff & apply         (lua/ai-chat/diff.lua)
  └── jobstart() → Deno    (lua/ai-chat/job.lua)
          │ stdin:  JSON { model, system, messages, max_tokens }
          │ stdout: text deltas + "\n[DONE]\n"
          ▼
       Deno script         (deno/main.ts, deno/api.ts)
          └── Anthropic API / compatible endpoint (@anthropic-ai/sdk) streaming
```

The Deno process is spawned per request and exits when the stream finishes.
All conversation state lives in Lua.

See [doc/spec.md](doc/spec.md) for the full specification,
[doc/deepseek-provider-spec.md](doc/deepseek-provider-spec.md) for the provider
routing design, [doc/cmd-context-spec.md](doc/cmd-context-spec.md) for the
`@cmd` context token, and [doc/workflow-spec.md](doc/workflow-spec.md) for
workflows.

## License

MIT — see [LICENSE](LICENSE).
