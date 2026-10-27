local M = {}

local SEVERITY_NAME = { "ERROR", "WARN", "INFO", "HINT" }

local function buf_path(buf)
  local path = vim.api.nvim_buf_get_name(buf)
  if path == "" then path = ("[No Name #%d]"):format(buf) end
  return path
end

local function buf_lang(buf)
  return vim.bo[buf].filetype or ""
end

local function get_buf_content(buf)
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  return table.concat(lines, "\n")
end

local function fence(lang, header, body)
  local info = lang or ""
  if header and header ~= "" then
    info = info .. ":" .. header
  end
  -- 本文中の最長バッククォート列より長いフェンスを使い、入れ子（md ファイル等）で壊れないようにする
  local longest = 0
  for run in body:gmatch("`+") do
    longest = math.max(longest, #run)
  end
  local ticks = string.rep("`", math.max(3, longest + 1))
  return ticks .. info .. "\n" .. body .. "\n" .. ticks
end

local function origin_buf(state)
  if not (state.origin_win and vim.api.nvim_win_is_valid(state.origin_win)) then
    return nil
  end
  local buf = vim.api.nvim_win_get_buf(state.origin_win)
  if not vim.api.nvim_buf_is_valid(buf) then return nil end
  return buf
end

local function context_buf(state)
  local buf = origin_buf(state)
  if not buf then return nil end
  return fence(buf_lang(buf), buf_path(buf), get_buf_content(buf))
end

local function is_regular_buffer(buf)
  return vim.api.nvim_buf_is_valid(buf)
    and vim.bo[buf].buftype == ""
    and vim.bo[buf].filetype ~= "ai-chat"
    and vim.bo[buf].filetype ~= "ai-chat-input"
end

local function context_bufs(state)
  local blocks = {}
  local seen = {}

  local function add(buf)
    if buf and not seen[buf] and is_regular_buffer(buf) then
      seen[buf] = true
      table.insert(blocks, fence(buf_lang(buf), buf_path(buf), get_buf_content(buf)))
    end
  end

  add(origin_buf(state))

  for _, win in ipairs(vim.api.nvim_list_wins()) do
    add(vim.api.nvim_win_get_buf(win))
  end

  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.bo[buf].buflisted then
      if vim.api.nvim_buf_is_loaded(buf) then
        add(buf)
      elseif not seen[buf] and is_regular_buffer(buf) then
        -- 未ロードの listed バッファ（セッション復元・:badd 等）はバッファ内容が空なのでディスクから読む
        local path = vim.api.nvim_buf_get_name(buf)
        if path ~= "" and vim.fn.filereadable(path) == 1 then
          seen[buf] = true
          local ft = vim.filetype.match({ filename = path }) or ""
          table.insert(blocks, fence(ft, path, table.concat(vim.fn.readfile(path), "\n")))
        end
      end
    end
  end

  if #blocks == 0 then return nil end
  return table.concat(blocks, "\n\n")
end

local function context_sel(state)
  if not state.sel then return nil end
  local header = state.sel.path or ""
  if state.sel.range then header = header .. ":" .. state.sel.range end
  return fence(state.sel.ft or "", header, state.sel.body or "")
end

local function context_file(path)
  local expanded = vim.fn.expand(path)
  local ok, lines = pcall(vim.fn.readfile, expanded)
  if not ok or type(lines) ~= "table" then
    return "[Error reading file: " .. expanded .. "]"
  end
  local ft = ""
  local detect_ok, detected = pcall(vim.filetype.match, { filename = expanded })
  if detect_ok and detected then ft = detected end
  return fence(ft, expanded, table.concat(lines, "\n"))
end

local CMD_TIMEOUT_MS = 10000
local CMD_MAX_BYTES = 100000

local function context_cmd(command)
  local chunks = {}
  local function collect(_, data)
    if data then table.insert(chunks, table.concat(data, "\n")) end
  end
  local ok, job_id = pcall(vim.fn.jobstart, { "sh", "-c", command }, {
    stdout_buffered = true,
    stderr_buffered = true,
    on_stdout = collect,
    on_stderr = collect,
  })
  if not ok or job_id <= 0 then
    return "[Error running command: " .. command .. "]"
  end

  local code = vim.fn.jobwait({ job_id }, CMD_TIMEOUT_MS)[1]
  local notes = {}
  if code == -1 then
    vim.fn.jobstop(job_id)
    table.insert(notes, "[timeout after " .. (CMD_TIMEOUT_MS / 1000) .. "s]")
  elseif code ~= 0 then
    table.insert(notes, "[exit code: " .. code .. "]")
  end

  local out = table.concat(chunks, "")
  if #out > CMD_MAX_BYTES then
    out = out:sub(1, CMD_MAX_BYTES)
    table.insert(notes, 1, "[truncated]")
  end
  out = out:gsub("\n+$", "")
  if #notes > 0 then out = out .. "\n" .. table.concat(notes, "\n") end
  return fence("sh", command, out), "─── $ " .. command .. "\n" .. out .. "\n───"
end

local function format_native_diags(diags)
  local lines = {}
  for _, d in ipairs(diags) do
    table.insert(lines, string.format(
      "[%s] L%d:%d %s",
      SEVERITY_NAME[d.severity] or "?",
      (d.lnum or 0) + 1,
      (d.col or 0) + 1,
      d.message or ""
    ))
  end
  return lines
end

local function get_coc_diags(buf)
  if vim.fn.exists("*CocAction") == 0 then return nil end
  local ok, list = pcall(vim.fn.CocAction, "diagnosticList")
  if not ok or type(list) ~= "table" or #list == 0 then return nil end
  local target = vim.api.nvim_buf_get_name(buf)
  local target_real = vim.fn.resolve(target)
  local filtered = {}
  for _, d in ipairs(list) do
    local p = d.file or ""
    if p == target or vim.fn.resolve(p) == target_real then
      table.insert(filtered, d)
    end
  end
  return filtered
end

local function format_coc_diags(diags)
  local lines = {}
  for _, d in ipairs(diags) do
    table.insert(lines, string.format(
      "[%s] L%d:%d %s",
      d.severity or "?",
      d.lnum or 0,
      d.col or 0,
      d.message or ""
    ))
  end
  return lines
end

local function context_diag(state)
  local buf = origin_buf(state)
  if not buf then return nil end

  local native = vim.diagnostic.get(buf)
  if #native > 0 then
    return fence("diagnostics", buf_path(buf), table.concat(format_native_diags(native), "\n"))
  end

  local coc = get_coc_diags(buf)
  if coc and #coc > 0 then
    return fence("diagnostics", buf_path(buf), table.concat(format_coc_diags(coc), "\n"))
  end

  return fence("diagnostics", buf_path(buf), "(no diagnostics)")
end

local function extract_tokens(prompt)
  local seen = {}
  local order = {}
  for command in prompt:gmatch("@cmd:`([^`]+)`") do
    local key = "@cmd:`" .. command .. "`"
    if not seen[key] then
      seen[key] = true
      table.insert(order, { kind = "cmd", arg = command, key = key })
    end
  end
  for word in prompt:gmatch("@cmd:([^%s`]%S*)") do
    local key = "@cmd:" .. word
    if not seen[key] then
      seen[key] = true
      table.insert(order, { kind = "cmd", arg = word, key = key })
    end
  end
  for path in prompt:gmatch("@file:(%S+)") do
    local key = "@file:" .. path
    if not seen[key] then
      seen[key] = true
      table.insert(order, { kind = "file", arg = path, key = key })
    end
  end
  for token in prompt:gmatch("@(%w+)") do
    if token == "bufs" or token == "buf" or token == "sel" or token == "diag" then
      local key = "@" .. token
      if not seen[key] then
        seen[key] = true
        table.insert(order, { kind = token, key = key })
      end
    end
  end
  return order
end

function M.build_user_content(prompt, state)
  local tokens = extract_tokens(prompt)
  if #tokens == 0 then return prompt, {} end

  local blocks = {}
  local cmd_blocks = {}
  for _, t in ipairs(tokens) do
    local body
    if t.kind == "buf" then
      body = context_buf(state)
    elseif t.kind == "bufs" then
      body = context_bufs(state)
    elseif t.kind == "sel" then
      body = context_sel(state)
    elseif t.kind == "diag" then
      body = context_diag(state)
    elseif t.kind == "file" then
      body = context_file(t.arg)
    elseif t.kind == "cmd" then
      local display
      body, display = context_cmd(t.arg)
      table.insert(cmd_blocks, display)
    end
    if body then
      table.insert(blocks, "<context " .. t.key .. ">\n" .. body)
    end
  end

  if #blocks == 0 then return prompt, cmd_blocks end
  return table.concat(blocks, "\n\n") .. "\n\n" .. prompt, cmd_blocks
end

function M.extract_token_keys(prompt)
  local tokens = extract_tokens(prompt)
  local set = {}
  for _, t in ipairs(tokens) do set[t.key] = true end
  return set
end

return M
