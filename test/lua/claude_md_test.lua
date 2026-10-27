local eq = require("helper").eq
local claude_md = require("ai-chat.claude_md")

local function tmpdir()
  local d = vim.fn.tempname()
  vim.fn.mkdir(d, "p")
  return d
end

local function write(path, text)
  vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")
  vim.fn.writefile(vim.split(text, "\n", { plain = true }), path)
end

local function expand(text, dir)
  return claude_md.expand_imports(text, dir)
end

return {
  ["relative path resolves against containing file"] = function()
    local d = tmpdir()
    write(d .. "/sub/a.md", "A: @b.md")
    write(d .. "/sub/b.md", "B")
    write(d .. "/CLAUDE.md", "top @sub/a.md end")
    eq(expand("top @sub/a.md end", d), "top A: B end")
  end,

  ["tilde and absolute paths"] = function()
    local d, home = tmpdir(), tmpdir()
    local old = vim.env.HOME
    vim.env.HOME = home
    write(home .. "/x.md", "X")
    write(d .. "/y.md", "Y")
    local out = expand("@~/x.md @" .. d .. "/y.md", d)
    vim.env.HOME = old
    eq(out, "X Y")
  end,

  ["words without path markers are untouched"] = function()
    eq(expand("@buf @sel user@example.com", tmpdir()), "@buf @sel user@example.com")
  end,

  ["code span and fenced block are not expanded"] = function()
    local d = tmpdir()
    write(d .. "/a.md", "A")
    eq(expand("`@a.md` @a.md", d), "`@a.md` A")
    eq(expand("```\n@a.md\n```\n@a.md", d), "```\n@a.md\n```\nA")
  end,

  ["trailing punctuation is kept outside the path"] = function()
    local d = tmpdir()
    write(d .. "/a.md", "A")
    eq(expand("see @a.md.", d), "see A.")
    eq(expand("@a.md。", d), "A。")
  end,

  ["missing file is left as-is"] = function()
    eq(expand("@nope/none.md", tmpdir()), "@nope/none.md")
  end,

  ["circular import is left as-is"] = function()
    local d = tmpdir()
    write(d .. "/a.md", "A @b.md")
    write(d .. "/b.md", "B @a.md")
    eq(expand("@a.md", d), "A B @a.md")
  end,

  ["depth limit is 5"] = function()
    local d = tmpdir()
    for i = 1, 7 do
      write(d .. "/f" .. i .. ".md", "f" .. i .. " @f" .. (i + 1) .. ".md")
    end
    write(d .. "/f8.md", "end")
    eq(expand("@f1.md", d), "f1 f2 f3 f4 f5 @f6.md")
  end,

  ["read: global then project, first project file only"] = function()
    local d, home = tmpdir(), tmpdir()
    local old = vim.env.HOME
    vim.env.HOME = home
    write(home .. "/.claude/CLAUDE.md", "global")
    write(d .. "/CLAUDE.md", "root")
    write(d .. "/.claude/CLAUDE.md", "dotclaude")
    local out = claude_md.read(d)
    vim.env.HOME = old
    eq(out, "global\n\nroot")
  end,

  ["read: nil when nothing exists"] = function()
    local d, home = tmpdir(), tmpdir()
    local old = vim.env.HOME
    vim.env.HOME = home
    local out = claude_md.read(d)
    vim.env.HOME = old
    eq(out, nil)
  end,
}
