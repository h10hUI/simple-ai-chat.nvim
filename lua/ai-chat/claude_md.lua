local M = {}

local MAX_DEPTH = 5
local TRAILING_PUNCT = { ".", ",", ")", "、", "。" }

local function read_file(path)
  if vim.fn.filereadable(path) ~= 1 then return nil end
  local ok, lines = pcall(vim.fn.readfile, path)
  if not ok or type(lines) ~= "table" then return nil end
  return (table.concat(lines, "\n"):gsub("%s+$", ""))
end

local function abs(path)
  return vim.fn.fnamemodify(path, ":p")
end

local function resolve(path, dir)
  if path:sub(1, 2) == "~/" then
    return (vim.env.HOME or "") .. path:sub(2)
  elseif path:sub(1, 1) == "/" then
    return path
  end
  return dir .. "/" .. path
end

local function strip_trailing_punct(tok)
  local suffix = ""
  local changed = true
  while changed do
    changed = false
    for _, p in ipairs(TRAILING_PUNCT) do
      if vim.endswith(tok, p) then
        tok = tok:sub(1, #tok - #p)
        suffix = p .. suffix
        changed = true
      end
    end
  end
  return tok, suffix
end

local expand_imports

-- コードスパンを含まない 1 区間のテキスト内の @path を展開する。
-- at_start: 区間の先頭が行頭 / 空白直後（= 直前が空白扱い）かどうか。
local function expand_segment(seg, at_start, dir, stack, depth)
  return (seg:gsub("()@(%S+)", function(pos, tok)
    local prev_ok = pos > 1 and seg:sub(pos - 1, pos - 1):match("%s") or (pos == 1 and at_start)
    if not prev_ok or depth >= MAX_DEPTH then return nil end
    local path, suffix = strip_trailing_punct(tok)
    if not path:find("[/~.]") then return nil end
    local full = abs(resolve(path, dir))
    if stack[full] then return nil end
    local content = read_file(full)
    if not content then return nil end
    local next_stack = vim.tbl_extend("keep", { [full] = true }, stack)
    return expand_imports(content, vim.fn.fnamemodify(full, ":h"), next_stack, depth + 1) .. suffix
  end))
end

local function expand_line(line, dir, stack, depth)
  local out, i, at_start = {}, 1, true
  while i <= #line do
    local s, e = line:find("`[^`]*`", i)
    local seg = line:sub(i, (s or #line + 1) - 1)
    if #seg > 0 then
      table.insert(out, expand_segment(seg, at_start, dir, stack, depth))
    end
    if not s then break end
    table.insert(out, line:sub(s, e))
    at_start = false
    i = e + 1
  end
  return table.concat(out)
end

-- text 内の @path を再帰的に展開する。dir は text を含むファイルのディレクトリ。
-- stack は展開中のファイル（絶対パス）の集合、depth は現在の深さ。
function expand_imports(text, dir, stack, depth)
  local lines = vim.split(text, "\n", { plain = true })
  local in_fence = false
  for idx, line in ipairs(lines) do
    if line:match("^%s*```") then
      in_fence = not in_fence
    elseif not in_fence then
      lines[idx] = expand_line(line, dir, stack, depth)
    end
  end
  return table.concat(lines, "\n")
end

M.expand_imports = function(text, dir, stack, depth)
  return expand_imports(text, dir, stack or {}, depth or 0)
end

local function load(path)
  local content = read_file(path)
  if not content or content == "" then return nil end
  local full = abs(path)
  return expand_imports(content, vim.fn.fnamemodify(full, ":h"), { [full] = true }, 0)
end

-- ~/.claude/CLAUDE.md → <cwd>/CLAUDE.md（なければ <cwd>/.claude/CLAUDE.md）の順に
-- 読み込み、@import を展開して連結する。何も無ければ nil。
function M.read(cwd)
  local parts = {}
  local global = load((vim.env.HOME or "") .. "/.claude/CLAUDE.md")
  if global then table.insert(parts, global) end
  for _, path in ipairs({ cwd .. "/CLAUDE.md", cwd .. "/.claude/CLAUDE.md" }) do
    local project = load(path)
    if project then
      table.insert(parts, project)
      break
    end
  end
  if #parts == 0 then return nil end
  return table.concat(parts, "\n\n")
end

return M
