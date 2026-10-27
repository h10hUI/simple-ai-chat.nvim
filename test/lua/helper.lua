local M = {}

function M.eq(actual, expected)
  if not vim.deep_equal(actual, expected) then
    error(
      ("not equal\n  expected: %s\n  actual:   %s"):format(vim.inspect(expected), vim.inspect(actual)),
      2
    )
  end
end

return M
