local M = {}

local function parse_header(info)
  if info == nil or info == "" then return "", nil end
  local lang, path = info:match("^([^:]*):(.+)$")
  if path then return lang, path end
  return info, nil
end

function M.find_all_blocks(buf)
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local blocks = {}
  local in_block = false
  local current
  for i, line in ipairs(lines) do
    local fence = line:match("^```(.*)$")
    if fence ~= nil then
      if not in_block then
        local lang, path = parse_header(fence)
        current = {
          start_line = i,
          lang = lang,
          path = path,
          body_lines = {},
        }
        in_block = true
      else
        current.end_line = i
        table.insert(blocks, current)
        current = nil
        in_block = false
      end
    elseif in_block then
      table.insert(current.body_lines, line)
    end
  end
  return blocks
end

function M.find_block_at_cursor(buf, cursor_row)
  for _, b in ipairs(M.find_all_blocks(buf)) do
    if cursor_row >= b.start_line and cursor_row <= b.end_line then
      return b
    end
  end
  return nil
end

function M.find_next_block(buf, cursor_row)
  for _, b in ipairs(M.find_all_blocks(buf)) do
    if b.start_line > cursor_row then return b end
  end
  return nil
end

function M.find_prev_block(buf, cursor_row)
  local prev
  for _, b in ipairs(M.find_all_blocks(buf)) do
    if b.start_line < cursor_row then
      prev = b
    else
      break
    end
  end
  return prev
end

local function resolve_target(block, state)
  if block.path and block.path ~= "" then
    return {
      kind = "path",
      path = vim.fn.fnamemodify(vim.fn.expand(block.path), ":p"),
    }
  end
  if state and state.origin_win and vim.api.nvim_win_is_valid(state.origin_win) then
    local buf = vim.api.nvim_win_get_buf(state.origin_win)
    if vim.api.nvim_buf_is_valid(buf) then
      return {
        kind = "buf",
        buf = buf,
        path = vim.api.nvim_buf_get_name(buf),
      }
    end
  end
  return nil
end

local function parse_search_replace(body_lines)
  local pairs_list = {}
  local mode = "outside"
  local cur_search, cur_replace
  for _, line in ipairs(body_lines) do
    if mode == "outside" and line:match("^<<<<<<<%s*SEARCH") then
      mode = "search"
      cur_search = {}
      cur_replace = {}
    elseif mode == "search" and line:match("^=======%s*$") then
      mode = "replace"
    elseif mode == "replace" and line:match("^>>>>>>>%s*REPLACE") then
      table.insert(pairs_list, { search = cur_search, replace = cur_replace })
      mode = "outside"
    elseif mode == "search" then
      table.insert(cur_search, line)
    elseif mode == "replace" then
      table.insert(cur_replace, line)
    end
  end
  if #pairs_list == 0 then return nil end
  return pairs_list
end

local function apply_pairs(current_lines, pairs_list)
  local text = table.concat(current_lines, "\n")
  for i, pair in ipairs(pairs_list) do
    local search_text = table.concat(pair.search, "\n")
    local replace_text = table.concat(pair.replace, "\n")
    local s, e = text:find(search_text, 1, true)
    if not s then
      return nil, string.format("SEARCH block #%d not found in target", i)
    end
    text = text:sub(1, s - 1) .. replace_text .. text:sub(e + 1)
  end
  return vim.split(text, "\n", { plain = true }), nil
end

local function read_target_lines(target)
  if target.kind == "path" then
    if vim.fn.filereadable(target.path) == 1 then
      return vim.fn.readfile(target.path)
    end
    return {}
  end
  return vim.api.nvim_buf_get_lines(target.buf, 0, -1, false)
end

local function apply(target, new_lines)
  if target.kind == "path" then
    local dir = vim.fn.fnamemodify(target.path, ":h")
    if dir ~= "" and vim.fn.isdirectory(dir) == 0 then
      vim.fn.mkdir(dir, "p")
    end
    vim.fn.writefile(new_lines, target.path)
    for _, b in ipairs(vim.api.nvim_list_bufs()) do
      if vim.api.nvim_buf_is_valid(b) and vim.api.nvim_buf_get_name(b) == target.path then
        vim.api.nvim_buf_set_lines(b, 0, -1, false, new_lines)
        vim.bo[b].modified = false
      end
    end
    vim.notify("Applied: " .. target.path, vim.log.levels.INFO, { title = "ai-chat" })
  else
    vim.api.nvim_buf_set_lines(target.buf, 0, -1, false, new_lines)
    vim.notify("Applied to buffer", vim.log.levels.INFO, { title = "ai-chat" })
  end
end

function M.show_diff_for_block(block, state, on_done)
  local target = resolve_target(block, state)
  if not target then
    vim.notify("No target file or buffer for diff", vim.log.levels.ERROR, { title = "ai-chat" })
    if on_done then on_done() end
    return
  end

  local current_lines = read_target_lines(target)
  local pairs_list = parse_search_replace(block.body_lines)
  local new_lines
  if pairs_list then
    local result, err = apply_pairs(current_lines, pairs_list)
    if err then
      vim.notify("ai-chat diff: " .. err, vim.log.levels.ERROR, { title = "ai-chat" })
      if on_done then vim.schedule(on_done) end
      return
    end
    new_lines = result
  else
    new_lines = vim.deepcopy(block.body_lines)
  end

  vim.cmd("tabnew")
  local tabpage = vim.api.nvim_get_current_tabpage()

  local left_win = vim.api.nvim_get_current_win()
  local left_buf = vim.api.nvim_get_current_buf()
  vim.bo[left_buf].buftype = "nofile"
  vim.bo[left_buf].bufhidden = "wipe"
  vim.bo[left_buf].swapfile = false
  vim.api.nvim_buf_set_lines(left_buf, 0, -1, false, current_lines)
  local label_target = (target.path ~= "" and target.path) or "[buffer]"
  pcall(vim.api.nvim_buf_set_name, left_buf, "[ai-chat current] " .. label_target)
  if block.lang and block.lang ~= "" then
    pcall(function() vim.bo[left_buf].filetype = block.lang end)
  end
  vim.cmd("diffthis")
  vim.wo[left_win].foldenable = false

  vim.cmd("rightbelow vnew")
  local right_win = vim.api.nvim_get_current_win()
  local right_buf = vim.api.nvim_get_current_buf()
  vim.bo[right_buf].buftype = "nofile"
  vim.bo[right_buf].bufhidden = "wipe"
  vim.bo[right_buf].swapfile = false
  vim.api.nvim_buf_set_lines(right_buf, 0, -1, false, new_lines)
  pcall(vim.api.nvim_buf_set_name, right_buf, "[ai-chat new] " .. label_target)
  if block.lang and block.lang ~= "" then
    pcall(function() vim.bo[right_buf].filetype = block.lang end)
  end
  vim.cmd("diffthis")
  vim.wo[right_win].foldenable = false

  local closed = false
  local function close_and_done(do_apply)
    if closed then return end
    closed = true
    if do_apply then
      local final_lines = (vim.api.nvim_buf_is_valid(right_buf)
        and vim.api.nvim_buf_get_lines(right_buf, 0, -1, false))
        or new_lines
      apply(target, final_lines)
    end
    if vim.api.nvim_tabpage_is_valid(tabpage) then
      local nr = vim.api.nvim_tabpage_get_number(tabpage)
      pcall(vim.cmd, "tabclose " .. nr)
    end
    if on_done then
      vim.schedule(on_done)
    end
  end

  for _, b in ipairs({ left_buf, right_buf }) do
    vim.keymap.set("n", "<CR>", function() close_and_done(true) end,
      { buffer = b, silent = true, desc = "ai-chat: apply diff" })
    vim.keymap.set("n", "q", function() close_and_done(false) end,
      { buffer = b, silent = true, desc = "ai-chat: cancel diff" })
    vim.keymap.set("n", "]]", function() vim.cmd("normal! ]c") end,
      { buffer = b, silent = true, desc = "ai-chat: next diff hunk" })
    vim.keymap.set("n", "[[", function() vim.cmd("normal! [c") end,
      { buffer = b, silent = true, desc = "ai-chat: prev diff hunk" })
  end
end

return M
