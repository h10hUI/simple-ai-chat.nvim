local eq = require("helper").eq
local context = require("ai-chat.context")

return {
  ["extract_token_keys: simple tokens"] = function()
    eq(context.extract_token_keys("@buf @sel explain"), { ["@buf"] = true, ["@sel"] = true })
  end,

  ["extract_token_keys: file and diag"] = function()
    eq(
      context.extract_token_keys("@file:lua/ai-chat/job.lua @diag"),
      { ["@file:lua/ai-chat/job.lua"] = true, ["@diag"] = true }
    )
  end,

  ["extract_token_keys: backtick cmd"] = function()
    eq(
      context.extract_token_keys("@cmd:`git diff --stat` summarize"),
      { ["@cmd:`git diff --stat`"] = true }
    )
  end,

  ["extract_token_keys: unknown token is ignored"] = function()
    eq(context.extract_token_keys("@unknown hello"), {})
  end,

  ["extract_token_keys: duplicates collapse"] = function()
    eq(context.extract_token_keys("@buf @buf"), { ["@buf"] = true })
  end,
}
