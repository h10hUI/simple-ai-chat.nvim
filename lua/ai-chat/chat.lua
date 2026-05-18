local M = {}
local job = require("ai-chat.job")
local context = require("ai-chat.context")
local commands = require("ai-chat.commands")
local diff = require("ai-chat.diff")

local BASE_SYSTEM = [[
ファイルを修正するときは、必ず次の SEARCH/REPLACE 形式のコードブロックで変更部分のみを返してください。ファイル全文を返す必要はありません。

```<lang>:<path>
<<<<<<< SEARCH
<変更前のコード。既存ファイルの内容と完全一致する必要があります（空白・インデントを含む）>
=======
<変更後のコード>
>>>>>>> REPLACE
```

- 1 ファイルに複数の変更がある場合は、SEARCH/REPLACE ブロックを 1 つのコードブロック内に複数並べてください。
- SEARCH 部分はファイル内で一意に特定できる十分な context（前後数行）を含めてください。
- 新規ファイル作成の場合は SEARCH を空にして REPLACE のみ書いてください。
- ファイル全文を書き換える必要がある場合のみ、SEARCH/REPLACE を使わずに通常のコードブロックでファイル全文を返してください。
]]

local function read_claude_md()
  local cwd = vim.fn.getcwd()
  local candidates = { cwd .. "/CLAUDE.md", cwd .. "/.claude/CLAUDE.md" }
  for _, path in ipairs(candidates) do
    if vim.fn.filereadable(path) == 1 then
      local ok, lines = pcall(vim.fn.readfile, path)
      if ok and type(lines) == "table" and #lines > 0 then
        return table.concat(lines, "\n"), path
      end
    end
  end
  return nil, nil
end

local function build_system(user_system)
  local parts = { BASE_SYSTEM }
  local claude_md = read_claude_md()
  if claude_md and claude_md ~= "" then
    table.insert(parts, claude_md)
  end
  if user_system and user_system ~= "" then
    table.insert(parts, user_system)
  end
  return table.concat(parts, "\n\n")
end

local state = {}

local function reset_state()
  state = {}
end

local function with_modifiable(buf, fn)
  if not (buf and vim.api.nvim_buf_is_valid(buf)) then return end
  vim.bo[buf].modifiable = true
  local ok, err = pcall(fn)
  vim.bo[buf].modifiable = false
  if not ok then error(err) end
end

local function append_lines(buf, lines)
  with_modifiable(buf, function()
    vim.api.nvim_buf_set_lines(buf, -1, -1, false, lines)
  end)
end

local function append_text(buf, text)
  with_modifiable(buf, function()
    local new_lines = vim.split(text, "\n", { plain = true })
    local last = vim.api.nvim_buf_get_lines(buf, -2, -1, false)[1] or ""
    new_lines[1] = last .. new_lines[1]
    vim.api.nvim_buf_set_lines(buf, -2, -1, false, new_lines)
  end)
end

local function scroll_to_bottom(win, buf)
  if not (win and vim.api.nvim_win_is_valid(win)) then return end
  if not (buf and vim.api.nvim_buf_is_valid(buf)) then return end
  local line_count = vim.api.nvim_buf_line_count(buf)
  pcall(vim.api.nvim_win_set_cursor, win, { line_count, 0 })
end

local function is_open()
  return state.output_win and vim.api.nvim_win_is_valid(state.output_win)
    and state.input_win and vim.api.nvim_win_is_valid(state.input_win)
end

local function focus_input()
  if state.input_win and vim.api.nvim_win_is_valid(state.input_win) then
    vim.api.nvim_set_current_win(state.input_win)
  end
end

local function focus_output()
  if state.output_win and vim.api.nvim_win_is_valid(state.output_win) then
    vim.api.nvim_set_current_win(state.output_win)
  end
end

local function build_winbar(stickies)
  if not stickies or #stickies == 0 then
    return "📌 (none)"
  end
  return "📌 " .. table.concat(stickies, " ")
end

local function update_winbar()
  if state.input_win and vim.api.nvim_win_is_valid(state.input_win) then
    vim.wo[state.input_win].winbar = build_winbar(state.stickies)
  end
end

local function output_append(lines)
  if not (state.output_buf and vim.api.nvim_buf_is_valid(state.output_buf)) then return end
  append_lines(state.output_buf, lines)
  scroll_to_bottom(state.output_win, state.output_buf)
end

local function build_cmd_ctx()
  return {
    append_output_lines = output_append,
    update_winbar = update_winbar,
    close = function() M.close() end,
  }
end

local function bufmap(buf, mode, lhs, rhs, desc)
  vim.keymap.set(mode, lhs, rhs, { buffer = buf, silent = true, desc = desc })
end

local function setup_output_keymaps(buf)
  bufmap(buf, "n", "i", focus_input, "ai-chat: focus input")
  bufmap(buf, "n", "<C-c>", function() M.stop_job() end, "ai-chat: stop streaming")
  bufmap(buf, "n", "gp", function()
    local word = vim.fn.expand("<cWORD>")
    local cleaned = word:match("^(@[%w:/._%-]+)")
    if cleaned then
      require("ai-chat").pin(cleaned)
    end
  end, "ai-chat: pin context under cursor")
  bufmap(buf, "n", "ga", function() require("ai-chat").apply_block_at_cursor() end, "ai-chat: apply diff at cursor")
  bufmap(buf, "n", "gA", function() require("ai-chat").apply_all_blocks() end, "ai-chat: apply all diffs")
  bufmap(buf, "n", "gy", function() require("ai-chat").yank_block_at_cursor() end, "ai-chat: yank code block")
  bufmap(buf, "n", "]]", function() require("ai-chat").next_block() end, "ai-chat: next code block")
  bufmap(buf, "n", "[[", function() require("ai-chat").prev_block() end, "ai-chat: prev code block")
end

local function setup_input_keymaps(buf)
  bufmap(buf, "n", "<CR>", function() require("ai-chat").send() end, "ai-chat: send")
  bufmap(buf, "i", "<C-CR>", function()
    vim.cmd("stopinsert")
    require("ai-chat").send()
  end, "ai-chat: send")
  bufmap(buf, { "n", "i" }, "<C-c>", function() M.stop_job() end, "ai-chat: stop streaming")
  bufmap(buf, "n", "<Esc>", focus_output, "ai-chat: focus output")
  bufmap(buf, "n", "<Up>", function() M.history_prev() end, "ai-chat: history prev")
  bufmap(buf, "n", "<Down>", function() M.history_next() end, "ai-chat: history next")
end

function M.open(opts)
  if is_open() then
    focus_input()
    return
  end

  state.origin_win = vim.api.nvim_get_current_win()
  state.messages = {}
  state.prompt_history = {}
  state.history_index = nil
  state.stickies = {}
  state.system = ""
  state.session_model = nil

  vim.cmd("topleft vsplit")
  state.output_win = vim.api.nvim_get_current_win()
  vim.cmd("vertical resize " .. math.floor(vim.o.columns * opts.window.width))

  state.output_buf = vim.api.nvim_create_buf(false, true)
  vim.bo[state.output_buf].buftype = "nofile"
  vim.bo[state.output_buf].bufhidden = "hide"
  vim.bo[state.output_buf].swapfile = false
  vim.bo[state.output_buf].filetype = "ai-chat"
  vim.api.nvim_win_set_buf(state.output_win, state.output_buf)
  vim.api.nvim_buf_call(state.output_buf, function()
    vim.cmd("setlocal syntax=markdown")
  end)
  vim.bo[state.output_buf].modifiable = false

  vim.cmd("rightbelow split")
  state.input_win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_height(state.input_win, opts.window.input_height)
  vim.wo[state.input_win].number = false
  vim.wo[state.input_win].relativenumber = false
  vim.wo[state.input_win].signcolumn = "no"

  state.input_buf = vim.api.nvim_create_buf(false, true)
  vim.bo[state.input_buf].buftype = "nofile"
  vim.bo[state.input_buf].bufhidden = "hide"
  vim.bo[state.input_buf].swapfile = false
  vim.bo[state.input_buf].filetype = "ai-chat-input"
  vim.bo[state.input_buf].modifiable = true
  vim.api.nvim_win_set_buf(state.input_win, state.input_buf)

  update_winbar()

  setup_output_keymaps(state.output_buf)
  setup_input_keymaps(state.input_buf)

  focus_input()
end

function M.close()
  if state.job_id then
    job.stop(state.job_id)
    state.job_id = nil
  end
  if state.input_win and vim.api.nvim_win_is_valid(state.input_win) then
    pcall(vim.api.nvim_win_close, state.input_win, true)
  end
  if state.output_win and vim.api.nvim_win_is_valid(state.output_win) then
    pcall(vim.api.nvim_win_close, state.output_win, true)
  end
  if state.input_buf and vim.api.nvim_buf_is_valid(state.input_buf) then
    pcall(vim.api.nvim_buf_delete, state.input_buf, { force = true })
  end
  if state.output_buf and vim.api.nvim_buf_is_valid(state.output_buf) then
    pcall(vim.api.nvim_buf_delete, state.output_buf, { force = true })
  end
  reset_state()
end

function M.toggle_focus(opts)
  if not is_open() then
    M.open(opts)
    return
  end
  local cur = vim.api.nvim_get_current_win()
  if cur == state.output_win then
    focus_input()
  elseif cur == state.input_win then
    focus_output()
  else
    focus_input()
  end
end

function M.open_with_sel(opts, sel)
  local just_opened = not is_open()
  if just_opened then
    M.open(opts)
  end
  state.sel = sel
  if state.input_buf and vim.api.nvim_buf_is_valid(state.input_buf) then
    local first_line = vim.api.nvim_buf_get_lines(state.input_buf, 0, 1, false)[1] or ""
    if not first_line:match("@sel") then
      local new_first = "@sel " .. first_line
      vim.api.nvim_buf_set_lines(state.input_buf, 0, 1, false, { new_first })
      if state.input_win and vim.api.nvim_win_is_valid(state.input_win) then
        pcall(vim.api.nvim_win_set_cursor, state.input_win, { 1, #new_first })
      end
    end
  end
  focus_input()
end

function M.stop_job()
  if state.job_id then
    job.stop(state.job_id)
    state.job_id = nil
  end
end

function M.pin(token)
  if not state.stickies then state.stickies = {} end
  for _, s in ipairs(state.stickies) do
    if s == token then return end
  end
  table.insert(state.stickies, token)
  update_winbar()
end

function M.send(opts)
  if state.job_id then return end
  if not is_open() then return end

  local lines = vim.api.nvim_buf_get_lines(state.input_buf, 0, -1, false)
  local prompt = table.concat(lines, "\n"):gsub("^%s+", ""):gsub("%s+$", "")
  if #prompt == 0 then return end

  -- 入力 buf をクリア（コマンド処理で state がリセットされる前に先に行う）
  vim.api.nvim_buf_set_lines(state.input_buf, 0, -1, false, { "" })

  -- スラッシュコマンド
  if commands.handle(prompt, state, build_cmd_ctx()) then
    return
  end

  table.insert(state.prompt_history, prompt)
  state.history_index = nil

  -- スティッキー prepend（本文に既出のものは除外）
  local effective_prompt = prompt
  if state.stickies and #state.stickies > 0 then
    local in_prompt = context.extract_token_keys(prompt)
    local additions = {}
    for _, t in ipairs(state.stickies) do
      if not in_prompt[t] then table.insert(additions, t) end
    end
    if #additions > 0 then
      effective_prompt = table.concat(additions, " ") .. " " .. prompt
    end
  end

  local model = state.session_model or opts.model

  -- 出力 buf には原文を表示
  local user_lines = { "**You**:", "" }
  for _, line in ipairs(vim.split(prompt, "\n", { plain = true })) do
    table.insert(user_lines, line)
  end
  table.insert(user_lines, "")
  table.insert(user_lines, "**" .. model .. "**:")
  table.insert(user_lines, "")
  output_append(user_lines)

  local user_content = context.build_user_content(effective_prompt, state)
  table.insert(state.messages, { role = "user", content = user_content })
  state.assistant_acc = ""

  local function on_text(text)
    vim.schedule(function()
      if not state.output_buf then return end
      state.assistant_acc = (state.assistant_acc or "") .. text
      append_text(state.output_buf, text)
      scroll_to_bottom(state.output_win, state.output_buf)
    end)
  end

  local done_completed = false
  local pending_usage = nil

  local function emit_usage(json)
    local ok, usage = pcall(vim.json.decode, json)
    if not ok or type(usage) ~= "table" then return end
    local parts = {}
    table.insert(parts, "input=" .. (usage.input_tokens or 0))
    if usage.cache_read_input_tokens and usage.cache_read_input_tokens > 0 then
      table.insert(parts, "cached_read=" .. usage.cache_read_input_tokens)
    end
    if usage.cache_creation_input_tokens and usage.cache_creation_input_tokens > 0 then
      table.insert(parts, "cached_write=" .. usage.cache_creation_input_tokens)
    end
    table.insert(parts, "output=" .. (usage.output_tokens or 0))
    local line = "--- usage: " .. table.concat(parts, " ") .. " ---"
    if state.output_buf and vim.api.nvim_buf_is_valid(state.output_buf) then
      append_lines(state.output_buf, { line, "" })
      scroll_to_bottom(state.output_win, state.output_buf)
    end
  end

  local function on_done()
    vim.schedule(function()
      if state.assistant_acc and #state.assistant_acc > 0 then
        table.insert(state.messages, { role = "assistant", content = state.assistant_acc })
      end
      if state.output_buf and vim.api.nvim_buf_is_valid(state.output_buf) then
        append_lines(state.output_buf, { "", "" })
        scroll_to_bottom(state.output_win, state.output_buf)
      end
      state.job_id = nil
      state.assistant_acc = nil
      done_completed = true
      if pending_usage then
        emit_usage(pending_usage)
        pending_usage = nil
      end
    end)
  end

  local function on_error(msg)
    vim.schedule(function()
      if state.output_buf and vim.api.nvim_buf_is_valid(state.output_buf) then
        append_lines(state.output_buf, { "", "[ERROR] " .. msg, "" })
        scroll_to_bottom(state.output_win, state.output_buf)
      end
      vim.notify(msg, vim.log.levels.ERROR, { title = "ai-chat" })
      state.job_id = nil
      state.assistant_acc = nil
    end)
  end

  local function on_usage(json)
    vim.schedule(function()
      if done_completed then
        emit_usage(json)
      else
        pending_usage = json
      end
    end)
  end

  state.job_id = job.start({
    deno_script = opts.deno_script,
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
end

function M.apply_block_at_cursor()
  if not (state.output_buf and state.output_win and vim.api.nvim_win_is_valid(state.output_win)) then return end
  local row = vim.api.nvim_win_get_cursor(state.output_win)[1]
  local block = diff.find_block_at_cursor(state.output_buf, row)
  if not block then
    vim.notify("No code block at cursor", vim.log.levels.WARN, { title = "ai-chat" })
    return
  end
  diff.show_diff_for_block(block, state, nil)
end

function M.apply_all_blocks()
  if not state.output_buf then return end
  local blocks = diff.find_all_blocks(state.output_buf)
  if #blocks == 0 then
    vim.notify("No code blocks in chat", vim.log.levels.WARN, { title = "ai-chat" })
    return
  end
  state.diff_queue = blocks
  local function next_one()
    if not state.diff_queue or #state.diff_queue == 0 then
      state.diff_queue = nil
      return
    end
    local b = table.remove(state.diff_queue, 1)
    diff.show_diff_for_block(b, state, next_one)
  end
  next_one()
end

function M.yank_block_at_cursor()
  if not (state.output_buf and state.output_win and vim.api.nvim_win_is_valid(state.output_win)) then return end
  local row = vim.api.nvim_win_get_cursor(state.output_win)[1]
  local block = diff.find_block_at_cursor(state.output_buf, row)
  if not block then
    vim.notify("No code block at cursor", vim.log.levels.WARN, { title = "ai-chat" })
    return
  end
  local body = table.concat(block.body_lines, "\n")
  vim.fn.setreg("+", body)
  vim.fn.setreg('"', body)
  vim.notify("Yanked code block (" .. #block.body_lines .. " lines)", vim.log.levels.INFO, { title = "ai-chat" })
end

function M.jump_to_block(direction)
  if not (state.output_buf and state.output_win and vim.api.nvim_win_is_valid(state.output_win)) then return end
  local row = vim.api.nvim_win_get_cursor(state.output_win)[1]
  local target = direction > 0
    and diff.find_next_block(state.output_buf, row)
    or diff.find_prev_block(state.output_buf, row)
  if target then
    vim.api.nvim_win_set_cursor(state.output_win, { target.start_line, 0 })
  end
end

local function set_input_lines(text)
  if not (state.input_buf and vim.api.nvim_buf_is_valid(state.input_buf)) then return end
  vim.api.nvim_buf_set_lines(state.input_buf, 0, -1, false, vim.split(text, "\n", { plain = true }))
end

function M.history_prev()
  if not state.prompt_history or #state.prompt_history == 0 then return end
  if state.history_index == nil then
    state.history_index = #state.prompt_history
  elseif state.history_index > 1 then
    state.history_index = state.history_index - 1
  end
  local prompt = state.prompt_history[state.history_index]
  if prompt then set_input_lines(prompt) end
end

function M.history_next()
  if not state.prompt_history or state.history_index == nil then return end
  if state.history_index < #state.prompt_history then
    state.history_index = state.history_index + 1
    set_input_lines(state.prompt_history[state.history_index])
  else
    state.history_index = nil
    set_input_lines("")
  end
end

return M
