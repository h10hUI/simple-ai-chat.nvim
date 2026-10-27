local eq = require("helper").eq
local diff = require("ai-chat.diff")

local function scratch(lines)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  return buf
end

local LINES = {
  "intro",
  "```lua:a.lua", -- 2
  "x",
  "```", -- 4
  "middle",
  "```lua:b.lua", -- 6
  "y",
  "```", -- 8
}

return {
  ["find_all_blocks: all blocks without start_line"] = function()
    local blocks = diff.find_all_blocks(scratch(LINES))
    eq(vim.tbl_map(function(b) return b.path end, blocks), { "a.lua", "b.lua" })
  end,

  ["find_all_blocks: only blocks starting at or after start_line"] = function()
    local buf = scratch(LINES)
    eq(vim.tbl_map(function(b) return b.path end, diff.find_all_blocks(buf, 5)), { "b.lua" })
    eq(vim.tbl_map(function(b) return b.path end, diff.find_all_blocks(buf, 6)), { "b.lua" })
    eq(#diff.find_all_blocks(buf, 7), 0)
    eq(#diff.find_all_blocks(buf, 1), 2)
  end,

  ["find_all_blocks: longer outer fence keeps nested fences in body"] = function()
    local buf = scratch({
      "````markdown:README.md",
      "```lua",
      "x",
      "```",
      "````",
      "```lua:b.lua",
      "y",
      "```",
    })
    local blocks = diff.find_all_blocks(buf)
    eq(vim.tbl_map(function(b) return b.path end, blocks), { "README.md", "b.lua" })
    eq(blocks[1].body_lines, { "```lua", "x", "```" })
    eq(blocks[1].end_line, 5)
  end,

  ["validate_edit: clean SEARCH/REPLACE passes"] = function()
    local text = table.concat({
      "```lua:a.lua",
      "<<<<<<< SEARCH",
      "old",
      "=======",
      "new",
      ">>>>>>> REPLACE",
      "```",
    }, "\n")
    eq(diff.validate_edit(text, function() return { "x", "old", "y" } end), {})
  end,

  ["validate_edit: unclosed fence and missing code block"] = function()
    local p = diff.validate_edit("```lua:a.lua\nx", function() return {} end)
    eq(#p, 1)
    assert(p[1]:find("閉じていない", 1, true))
    local q = diff.validate_edit("no code here", function() return {} end)
    assert(q[1]:find("見つからない", 1, true))
  end,

  ["validate_edit: broken markers and missing SEARCH text"] = function()
    local broken = diff.validate_edit(table.concat({
      "```lua:a.lua", "<<<<<<< SEARCH", "old", "new", "```",
    }, "\n"), function() return {} end)
    eq(#broken, 1)
    local missing = diff.validate_edit(table.concat({
      "```lua:a.lua", "<<<<<<< SEARCH", "nope", "=======", "new", ">>>>>>> REPLACE", "```",
    }, "\n"), function() return { "old" } end)
    eq(#missing, 1)
    assert(missing[1]:find("not found", 1, true))
  end,

  ["validate_edit: nil target skips SEARCH existence check"] = function()
    local text = table.concat({
      "```lua", "<<<<<<< SEARCH", "nope", "=======", "new", ">>>>>>> REPLACE", "```",
    }, "\n")
    eq(diff.validate_edit(text, function() return nil end), {})
  end,
}
