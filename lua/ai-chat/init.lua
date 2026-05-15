local M = {}
local job = require("ai-chat.job")

local default_opts = {
  model = "claude-sonnet-4-6",
  max_tokens = 8096,
  deno_script = nil,
}

M.opts = vim.deepcopy(default_opts)

function M.setup(user_opts)
  M.opts = vim.tbl_deep_extend("force", default_opts, user_opts or {})
end

local function resolve_deno_script()
  if M.opts.deno_script then return M.opts.deno_script end
  local source = debug.getinfo(1, "S").source:sub(2)
  return (source:gsub("lua/ai%-chat/init%.lua$", "deno/main.ts"))
end

function M.test_send(prompt)
  vim.cmd("vnew")
  local buf = vim.api.nvim_get_current_buf()
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].filetype = "ai-chat"
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "> " .. prompt, "" })

  local function append(text)
    vim.schedule(function()
      if not vim.api.nvim_buf_is_valid(buf) then return end
      vim.bo[buf].modifiable = true
      local lines = vim.split(text, "\n", { plain = true })
      local last = vim.api.nvim_buf_get_lines(buf, -2, -1, false)[1] or ""
      lines[1] = last .. lines[1]
      vim.api.nvim_buf_set_lines(buf, -2, -1, false, lines)
    end)
  end

  local job_id
  job_id = job.start({
    deno_script = resolve_deno_script(),
    payload = {
      model = M.opts.model,
      system = "",
      messages = { { role = "user", content = prompt } },
      max_tokens = M.opts.max_tokens,
    },
    on_text = append,
    on_done = function()
      vim.schedule(function()
        if vim.api.nvim_buf_is_valid(buf) then
          vim.bo[buf].modifiable = false
        end
      end)
    end,
    on_error = function(msg)
      vim.schedule(function()
        append("\n[ERROR] " .. msg .. "\n")
        vim.notify(msg, vim.log.levels.ERROR, { title = "ai-chat" })
      end)
    end,
  })

  vim.keymap.set("n", "<C-c>", function()
    job.stop(job_id)
  end, { buffer = buf, silent = true, desc = "ai-chat: stop streaming" })
end

return M
