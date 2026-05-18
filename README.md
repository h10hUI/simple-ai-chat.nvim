# simple-ai-chat.nvim

A minimal, zero-dependency AI chat plugin for Neovim that talks to the
Anthropic Claude API. UI and keybindings are written in Lua. API communication
is handled by a Deno script spawned per request via `jobstart()`. No Neovim
plugin dependencies.

## Features

- Two-pane chat window (output + input) with streaming responses
- Context tokens for injecting code into prompts: `@buf`, `@bufs`, `@sel`, `@file:<path>`, `@diag`
- Sticky context pinned across the session (shown in the input pane's winbar)
- Slash commands: `/clear`, `/quit`, `/pin`, `/unpin`, `/model`, `/system`
- Diff-and-apply for AI-generated code blocks, with SEARCH/REPLACE patch format
- LSP diagnostics integration (Neovim builtin LSP + coc.nvim)
- Automatic `CLAUDE.md` / `.claude/CLAUDE.md` loading as system prompt
- Visual selection via `<leader>ac` automatically populates `@sel`

## Requirements

- Neovim >= 0.9
- [Deno](https://deno.com/) >= 1.40 on `PATH`
- `ANTHROPIC_API_KEY` environment variable

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
| `<Up>` / `<Down>` | normal | Prompt history |

### Context tokens

Reference these `@` tokens in your prompt and they are expanded into the
message sent to Claude:

| Token | Content |
| --- | --- |
| `@buf` | The buffer focused before opening chat |
| `@bufs` | All visible regular buffers |
| `@sel` | Last visual selection (auto-populated when chat is opened from visual mode) |
| `@file:<path>` | Contents of the given file |
| `@diag` | LSP diagnostics of the original buffer (Neovim builtin LSP + coc.nvim) |

Example:

```
@diag fix all the errors please
```

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
| `/model <name>` | Switch model for the session |
| `/system <text>` | Append additional system prompt for the session |

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

If `CLAUDE.md` or `.claude/CLAUDE.md` exists in the cwd, its contents are
automatically appended to the system prompt on each send, before any
`/system` text. This follows the convention used by Claude Code.

## Architecture

```
Neovim (Lua)
  │
  ├── UI & keymaps         (lua/ai-chat/chat.lua, plugin/ai-chat.lua)
  ├── Context expansion    (lua/ai-chat/context.lua)
  ├── Slash commands       (lua/ai-chat/commands.lua)
  ├── Diff & apply         (lua/ai-chat/diff.lua)
  └── jobstart() → Deno    (lua/ai-chat/job.lua)
          │ stdin:  JSON { model, system, messages, max_tokens }
          │ stdout: text deltas + "\n[DONE]\n"
          ▼
       Deno script         (deno/main.ts, deno/api.ts)
          └── Anthropic API (@anthropic-ai/sdk) streaming
```

The Deno process is spawned per request and exits when the stream finishes.
All conversation state lives in Lua.

See [doc/spec.md](doc/spec.md) for the full specification.

## License

MIT — see [LICENSE](LICENSE).
