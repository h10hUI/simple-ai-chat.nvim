local eq = require("helper").eq
local workflow = require("ai-chat.workflow")

local function def()
  return {
    max_steps = 5,
    steps = {
      { name = "a", persona = "p", instruction = "A {task}", edits = true },
      {
        name = "b",
        persona = "p",
        instruction = "B {previous_response} / {last_edit} / {iteration}",
        rules = {
          { marker = "APPROVE", next = "COMPLETE" },
          { marker = "REJECT", next = "c" },
          { marker = "STOP", next = "ABORT" },
        },
      },
      { name = "c", persona = "p", instruction = "C", next = "b", edits = true },
    },
  }
end

-- 応答を順に返す偽の env。requests に呼び出し内容を記録する。
local function fake_env(responses, opts)
  opts = opts or {}
  local env = { requests = {}, printed = {}, edit_marks = 0, ended = false }
  local i = 0
  env.model_for = function() return "m" end
  env.request = function(step, text, cb)
    i = i + 1
    table.insert(env.requests, { step = step.name, text = text })
    local r = responses[i]
    if r and r.error then
      cb.on_error(r.error)
    elseif r then
      cb.on_complete(r)
    end
  end
  env.print = function(lines)
    for _, l in ipairs(lines) do table.insert(env.printed, l) end
  end
  env.mark_edit_start = function() env.edit_marks = env.edit_marks + 1 end
  env.is_cancelled = function() return opts.cancelled or false end
  env.on_end = function() env.ended = true end
  return env
end

local function has_line(env, pattern)
  for _, l in ipairs(env.printed) do
    if l:find(pattern, 1, true) then return true end
  end
  return false
end

return {
  ["render: expands known vars and keeps unknown"] = function()
    eq(workflow.render("{task} {unknown} {iteration}", { task = "T", iteration = 2 }), "T {unknown} 2")
  end,

  ["render: replacement containing % is safe"] = function()
    eq(workflow.render("{task}", { task = "100%s %1" }), "100%s %1")
  end,

  ["parse_marker: takes the last marker line"] = function()
    local body, marker = workflow.parse_marker("text\n[REJECT]\nmore\n[APPROVE]\n")
    eq(marker, "APPROVE")
    eq(body, "text\n[REJECT]\nmore")
  end,

  ["parse_marker: no marker"] = function()
    local body, marker = workflow.parse_marker("just text [APPROVE] inline")
    eq(marker, nil)
    eq(body, "just text [APPROVE] inline")
  end,

  ["parse_marker: allows trailing whitespace"] = function()
    local _, marker = workflow.parse_marker("x\n[APPROVE]  ")
    eq(marker, "APPROVE")
  end,

  ["parse_marker: lower-case brackets are not markers"] = function()
    local _, marker = workflow.parse_marker("[x]\n[link]")
    eq(marker, nil)
  end,

  ["build_instruction: appends marker instruction for rules"] = function()
    local d = def()
    local text = workflow.build_instruction(d.steps[2], { previous_response = "P", last_edit = "E", iteration = 2 })
    assert(text:find("B P / E / 2", 1, true))
    assert(text:find("[APPROVE] / [REJECT] / [STOP]", 1, true))
  end,

  ["build_instruction: no marker instruction without rules"] = function()
    local d = def()
    eq(workflow.build_instruction(d.steps[1], { task = "T" }), "A T")
  end,

  ["next_step: rules match"] = function()
    local d = def()
    eq({ workflow.next_step(d, d.steps[2], "APPROVE") }, { "COMPLETE" })
    eq({ workflow.next_step(d, d.steps[2], "REJECT") }, { "c" })
  end,

  ["next_step: missing or unknown marker aborts"] = function()
    local d = def()
    local t1, r1 = workflow.next_step(d, d.steps[2], nil)
    eq(t1, "ABORT")
    assert(r1:find("no marker", 1, true))
    local t2, r2 = workflow.next_step(d, d.steps[2], "NOPE")
    eq(t2, "ABORT")
    assert(r2:find("unknown marker", 1, true))
  end,

  ["next_step: rule next = ABORT"] = function()
    local d = def()
    eq((workflow.next_step(d, d.steps[2], "STOP")), "ABORT")
  end,

  ["next_step: explicit next, array order, and end of steps"] = function()
    local d = def()
    eq((workflow.next_step(d, d.steps[3], nil)), "b")
    eq((workflow.next_step(d, d.steps[1], nil)), "b")
    local last = { steps = { { name = "x", persona = "p", instruction = "i" } } }
    eq((workflow.next_step(last, last.steps[1], nil)), "COMPLETE")
  end,

  ["validate: accepts builtin default"] = function()
    eq(workflow.validate(workflow.default), nil)
  end,

  ["validate: rejects bad definitions"] = function()
    assert(workflow.validate({}))
    assert(workflow.validate({ steps = {} }))
    assert(workflow.validate({ steps = { { name = "a", persona = "p" } } }))
    assert(workflow.validate({
      steps = {
        { name = "a", persona = "p", instruction = "i" },
        { name = "a", persona = "p", instruction = "i" },
      },
    }))
    assert(workflow.validate({ steps = { { name = "a", persona = "p", instruction = "i", next = "zzz" } } }))
    assert(workflow.validate({
      steps = { { name = "a", persona = "p", instruction = "i", rules = { { marker = "lower", next = "COMPLETE" } } } },
    }))
    assert(workflow.validate({ steps = { { name = "COMPLETE", persona = "p", instruction = "i" } } }))
    assert(workflow.validate({ max_steps = 0, steps = { { name = "a", persona = "p", instruction = "i" } } }))
  end,

  ["merge: builtin < global < local with sources"] = function()
    local g = { default = { steps = {} }, shared = { steps = { 1 } }, only_global = {} }
    local l = { shared = { steps = { 2 } }, only_local = {} }
    local map = workflow.merge(g, l)
    eq(map.default.source, "global")
    eq(map.shared.source, "local")
    eq(map.shared.def, { steps = { 2 } })
    eq(map.only_global.source, "global")
    eq(map.only_local.source, "local")
    eq(workflow.merge(nil, nil).default.source, "builtin")
  end,

  ["parse_args: name and task"] = function()
    local map = workflow.merge({ review = {} }, nil)
    eq({ workflow.parse_args("review check this\nsecond line", map) }, { "review", "check this\nsecond line" })
    eq({ workflow.parse_args("fix the bug", map) }, { "default", "fix the bug" })
    eq({ workflow.parse_args("review", map) }, { "review", "" })
    eq({ workflow.parse_args("   ", map) }, {})
  end,

  ["list_lines: sorted with sources"] = function()
    local map = workflow.merge({ zeta = {}, alpha = {} }, nil)
    eq(workflow.list_lines(map), {
      "",
      "--- workflows ---",
      "  alpha (global)",
      "  default (builtin)",
      "  zeta (global)",
      "",
    })
  end,

  ["run: approve on first review completes"] = function()
    local env = fake_env({ "plan-ish", "ok\n[APPROVE]" })
    workflow.run(def(), "t", "TASK", env)
    eq(#env.requests, 2)
    eq(env.requests[1].text, "A TASK")
    assert(has_line(env, "--- workflow: COMPLETE (2 steps) ---"))
    eq(env.ended, true)
    eq(env.edit_marks, 1)
  end,

  ["run: reject loops through fix and review, passing last_edit"] = function()
    local env = fake_env({ "impl1", "bad\n[REJECT]", "impl2", "good\n[APPROVE]" })
    workflow.run(def(), "t", "TASK", env)
    eq(
      vim.tbl_map(function(r) return r.step end, env.requests),
      { "a", "b", "c", "b" }
    )
    assert(env.requests[2].text:find("B impl1 / impl1 / 2", 1, true))
    assert(env.requests[4].text:find("B impl2 / impl2 / 4", 1, true))
    assert(has_line(env, "--- workflow: COMPLETE (4 steps) ---"))
    eq(env.edit_marks, 2)
  end,

  ["run: step without marker aborts"] = function()
    local env = fake_env({ "impl", "no marker here" })
    workflow.run(def(), "t", "TASK", env)
    assert(has_line(env, "--- workflow: ABORT (2 steps) ---"))
    assert(has_line(env, "no marker found in step 'b'"))
    eq(env.ended, true)
  end,

  ["run: max_steps aborts a rejecting loop"] = function()
    local d = def()
    d.max_steps = 3
    local env = fake_env({ "impl", "[REJECT]", "impl", "[REJECT]" })
    workflow.run(d, "t", "TASK", env)
    eq(#env.requests, 3)
    assert(has_line(env, "--- workflow: ABORT (3 steps) ---"))
    assert(has_line(env, "max_steps (3) reached"))
  end,

  ["run: request error aborts once"] = function()
    local env = fake_env({ { error = "boom" } })
    workflow.run(def(), "t", "TASK", env)
    assert(has_line(env, "--- workflow: ABORT (1 steps) ---"))
    assert(has_line(env, "error: boom"))
  end,

  ["run: cancelled error reports user stop"] = function()
    local env = fake_env({ { error = "deno exited with code 143" } }, { cancelled = true })
    workflow.run(def(), "t", "TASK", env)
    assert(has_line(env, "stopped by user"))
  end,

  ["run: builtin default completes on approve"] = function()
    local env = fake_env({ "plan", "impl", "fine\n[APPROVE]" })
    workflow.run(workflow.default, "default", "TASK", env)
    eq(
      vim.tbl_map(function(r) return r.step end, env.requests),
      { "plan", "implement", "review" }
    )
    assert(has_line(env, "--- workflow: COMPLETE (3 steps) ---"))
  end,
}
