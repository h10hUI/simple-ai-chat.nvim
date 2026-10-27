-- 最小の Lua テストランナー。
-- 実行: nvim --headless -u NONE -l test/lua/run.lua
local this = debug.getinfo(1, "S").source:sub(2)
local test_dir = vim.fn.fnamemodify(this, ":p:h")
local root = vim.fn.fnamemodify(test_dir, ":h:h")

package.path = table.concat({
  root .. "/lua/?.lua",
  root .. "/lua/?/init.lua",
  test_dir .. "/?.lua",
  package.path,
}, ";")

local files = vim.fn.glob(test_dir .. "/*_test.lua", false, true)
table.sort(files)

local passed, failed = 0, 0

for _, file in ipairs(files) do
  local name = vim.fn.fnamemodify(file, ":t")
  local ok, tests = pcall(dofile, file)
  if not ok or type(tests) ~= "table" then
    failed = failed + 1
    print(("FAIL %s (load error)\n     %s"):format(name, tostring(tests)))
  else
    local names = vim.tbl_keys(tests)
    table.sort(names)
    for _, test_name in ipairs(names) do
      local ok_run, err = pcall(tests[test_name])
      if ok_run then
        passed = passed + 1
        print(("ok   %s: %s"):format(name, test_name))
      else
        failed = failed + 1
        print(("FAIL %s: %s\n     %s"):format(name, test_name, tostring(err)))
      end
    end
  end
end

print(("\n%d passed, %d failed"):format(passed, failed))
os.exit(failed == 0 and 0 or 1)
