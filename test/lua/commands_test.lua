local commands = require("ai-chat.commands")

-- nvim.api に依存せず、handle() を直接呼んで検証する。
-- ctx.append_output_lines は受け取った行を蓄積するスタブ。
local function make_ctx(opts)
  opts = opts or {}
  local out = {}
  local ctx = {
    append_output_lines = function(lines)
      for _, l in ipairs(lines) do table.insert(out, l) end
    end,
    update_winbar = function() end,
    close = function() end,
    run_workflow = function() end,
    current_model = opts.current_model or function()
      return opts.current_value or "stub-default"
    end,
  }
  return ctx, out
end

local function assert_lines(out, expected)
  assert(#out == #expected,
    ("line count mismatch: expected %d, got %d (%s)")
      :format(#expected, #out, table.concat(out, "|")))
  for i = 1, #expected do
    assert(out[i] == expected[i],
      ("line %d mismatch: expected %q, got %q"):format(i, expected[i], tostring(out[i])))
  end
end

-- ctx.current_model はスタブ化し、commands.lua の表示ロジックのみを検証している。
-- chat.lua 側の current_model（session_model or opts.model）はローカル関数のため未テスト。

return {
  ["/model with no args shows default model"] = function()
    local state = {}
    local ctx, out = make_ctx({ current_value = "claude-sonnet-4-6" })
    commands.handle("/model", state, ctx)
    assert_lines(out, { "", "--- model: claude-sonnet-4-6 ---", "" })
    assert(state.session_model == nil, "session_model should not be set by query")
  end,

  ["/model with no args shows session model"] = function()
    local state = { session_model = "deepseek-flash" }
    local ctx, out = make_ctx({ current_value = "deepseek-flash" })
    commands.handle("/model", state, ctx)
    assert_lines(out, { "", "--- model: deepseek-flash ---", "" })
  end,

  ["/model with args sets session model without querying current_model"] = function()
    local state = {}
    local ctx, out = make_ctx({
      current_model = function()
        error("current_model should not be called when args are given")
      end,
    })
    commands.handle("/model claude-opus-4-7", state, ctx)
    assert(state.session_model == "claude-opus-4-7", "session_model not updated")
    assert_lines(out, { "", "--- model: claude-opus-4-7 ---", "" })
  end,

  ["unknown command yields error"] = function()
    local state = {}
    local ctx, out = make_ctx()
    commands.handle("/bogus", state, ctx)
    assert_lines(out, { "", "[ERROR] unknown command: /bogus", "" })
  end,

  ["plain prompt is not treated as a command"] = function()
    local state = {}
    local ctx, out = make_ctx()
    local handled = commands.handle("hello", state, ctx)
    assert(handled == false, "plain prompt should not be handled")
    assert(#out == 0, "plain prompt should not emit lines")
  end,

  ["/clear still clears messages and workflow_edit_start"] = function()
    local state = {
      messages = { { role = "user", content = "x" } },
      workflow_edit_start = 5,
    }
    local ctx, out = make_ctx()
    commands.handle("/clear", state, ctx)
    assert(#state.messages == 0, "messages not cleared")
    assert(state.workflow_edit_start == nil, "workflow_edit_start not reset")
    assert_lines(out, { "", "--- cleared ---", "" })
  end,
}
