local M = {}

local default_opts = {
  model = "claude-sonnet-4-6",
  max_tokens = 8096,
  deno_script = nil,
  window = {
    width = 0.4,
    input_height = 5,
    side = "left",
  },
}

M.opts = vim.deepcopy(default_opts)

function M.setup(user_opts)
  M.opts = vim.tbl_deep_extend("force", default_opts, user_opts or {})
end

local function resolve_deno_script()
  if M.opts.deno_script then return M.opts.deno_script end
  local source = debug.getinfo(1, "S").source:sub(2)
  return (source:gsub("lua/ai%-chat/init%.lua$", "deno/main.ts"))
end

local function with_deno_script()
  local copy = vim.tbl_deep_extend("force", {}, M.opts)
  copy.deno_script = copy.deno_script or resolve_deno_script()
  return copy
end

function M.open()
  require("ai-chat.chat").open(with_deno_script())
end

function M.close()
  require("ai-chat.chat").close()
end

function M.toggle_focus()
  require("ai-chat.chat").toggle_focus(with_deno_script())
end

function M.send()
  require("ai-chat.chat").send(with_deno_script())
end

function M.open_with_sel(sel)
  require("ai-chat.chat").open_with_sel(with_deno_script(), sel)
end

function M.pin(token)
  require("ai-chat.chat").pin(token)
end

function M.apply_block_at_cursor() require("ai-chat.chat").apply_block_at_cursor() end
function M.apply_all_blocks()      require("ai-chat.chat").apply_all_blocks() end
function M.yank_block_at_cursor()  require("ai-chat.chat").yank_block_at_cursor() end
function M.next_block()            require("ai-chat.chat").jump_to_block(1) end
function M.prev_block()            require("ai-chat.chat").jump_to_block(-1) end

return M
