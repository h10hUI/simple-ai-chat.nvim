local M = {}

local DONE_MARKER = "\n[DONE]\n"

local function find_last_newline(s)
  local last
  local i = 1
  while true do
    local pos = s:find("\n", i, true)
    if not pos then break end
    last = pos
    i = pos + 1
  end
  return last
end

function M.start(opts)
  local stdout_buf = ""
  local done_emitted = false

  local job_id = vim.fn.jobstart({
    "deno",
    "run",
    "--allow-net=api.anthropic.com",
    "--allow-env",
    opts.deno_script,
  }, {
    on_stdout = function(_, data, _)
      if not data or #data == 0 then return end
      stdout_buf = stdout_buf .. table.concat(data, "\n")
      local done_idx = stdout_buf:find(DONE_MARKER, 1, true)
      if done_idx then
        local before = stdout_buf:sub(1, done_idx - 1)
        if #before > 0 then opts.on_text(before) end
        stdout_buf = ""
        done_emitted = true
        opts.on_done()
        return
      end
      local last_nl = find_last_newline(stdout_buf)
      if last_nl then
        opts.on_text(stdout_buf:sub(1, last_nl))
        stdout_buf = stdout_buf:sub(last_nl + 1)
      end
    end,
    on_stderr = function(_, data, _)
      if not data then return end
      local raw = table.concat(data, "\n")
      local errors = {}
      for line in (raw .. "\n"):gmatch("([^\n]+)\n") do
        local trimmed = line:gsub("^%s+", ""):gsub("%s+$", "")
        if #trimmed > 0 then
          local usage_json = trimmed:match("^USAGE:(.+)$")
          if usage_json then
            if opts.on_usage then opts.on_usage(usage_json) end
          else
            table.insert(errors, trimmed)
          end
        end
      end
      if #errors > 0 then opts.on_error(table.concat(errors, "\n")) end
    end,
    on_exit = function(_, code, _)
      if code ~= 0 and not done_emitted then
        opts.on_error("deno exited with code " .. code)
      end
    end,
  })

  if job_id <= 0 then
    opts.on_error("failed to start deno (jobstart returned " .. job_id .. ")")
    return job_id
  end

  vim.fn.chansend(job_id, vim.json.encode(opts.payload))
  vim.fn.chanclose(job_id, "stdin")
  return job_id
end

function M.stop(job_id)
  if job_id and job_id > 0 then
    vim.fn.jobstop(job_id)
  end
end

return M
