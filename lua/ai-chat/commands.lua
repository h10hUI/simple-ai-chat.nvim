local M = {}

local handlers = {}

function handlers.clear(state, _, _, ctx)
  state.messages = {}
  ctx.append_output_lines({ "", "--- cleared ---", "" })
end

function handlers.quit(_, _, _, ctx)
  ctx.close()
end

local function contains(list, v)
  for _, x in ipairs(list) do
    if x == v then return true end
  end
  return false
end

function handlers.pin(state, args, _, ctx)
  for _, t in ipairs(args) do
    if not contains(state.stickies, t) then
      table.insert(state.stickies, t)
    end
  end
  ctx.update_winbar()
end

function handlers.unpin(state, args, _, ctx)
  if #args == 0 then
    state.stickies = {}
  else
    local set = {}
    for _, a in ipairs(args) do set[a] = true end
    local new = {}
    for _, t in ipairs(state.stickies) do
      if not set[t] then table.insert(new, t) end
    end
    state.stickies = new
  end
  ctx.update_winbar()
end

function handlers.model(state, args, _, ctx)
  if #args == 0 then
    ctx.append_output_lines({ "", "[ERROR] /model requires a model name", "" })
    return
  end
  state.session_model = args[1]
  ctx.append_output_lines({ "", "--- model: " .. args[1] .. " ---", "" })
end

function handlers.system(state, _, rest, ctx)
  state.system = rest or ""
  local display = state.system
  if display == "" then display = "(cleared)" end
  ctx.append_output_lines({ "", "--- system: " .. display .. " ---", "" })
end

function M.handle(prompt, state, ctx)
  local first_line = prompt:match("^([^\n]*)")
  local cmd, rest = first_line:match("^/(%S+)%s*(.*)$")
  if not cmd then return false end

  local handler = handlers[cmd]
  if not handler then
    ctx.append_output_lines({ "", "[ERROR] unknown command: /" .. cmd, "" })
    return true
  end

  local args = {}
  for arg in (rest or ""):gmatch("%S+") do
    table.insert(args, arg)
  end

  handler(state, args, rest or "", ctx)
  return true
end

return M
