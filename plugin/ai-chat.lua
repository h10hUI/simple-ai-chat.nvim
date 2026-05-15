if vim.g.loaded_ai_chat then return end
vim.g.loaded_ai_chat = 1

local function lazy_call(fn)
  return function() require("ai-chat")[fn]() end
end

vim.api.nvim_create_user_command("AiChatOpen", lazy_call("open"), { desc = "Open AI chat" })
vim.api.nvim_create_user_command("AiChatClose", lazy_call("close"), { desc = "Close AI chat" })
vim.api.nvim_create_user_command("AiChatToggle", lazy_call("toggle_focus"), {
  desc = "Open AI chat or toggle pane focus",
})

vim.keymap.set("n", "<leader>ac", lazy_call("toggle_focus"), { desc = "ai-chat: open / toggle focus" })
vim.keymap.set("n", "<leader>aq", lazy_call("close"), { desc = "ai-chat: close" })

vim.keymap.set("x", "<leader>ac", function()
  -- visual から normal に抜けて `<` `>` マークを確定
  local esc = vim.api.nvim_replace_termcodes("<Esc>", true, false, true)
  vim.api.nvim_feedkeys(esc, "x", false)
  local buf = vim.api.nvim_get_current_buf()
  local s = vim.api.nvim_buf_get_mark(buf, "<")
  local e = vim.api.nvim_buf_get_mark(buf, ">")
  local lines = vim.api.nvim_buf_get_lines(buf, s[1] - 1, e[1], false)
  if #lines == 0 then return end
  -- 列単位の切り出し（charwise/linewise/blockwise を全部 charwise として扱う簡易版）
  local mode = vim.fn.visualmode()
  if mode == "v" and #lines > 0 then
    if #lines == 1 then
      lines[1] = lines[1]:sub(s[2] + 1, e[2] + 1)
    else
      lines[1] = lines[1]:sub(s[2] + 1)
      lines[#lines] = lines[#lines]:sub(1, e[2] + 1)
    end
  end
  local path = vim.api.nvim_buf_get_name(buf)
  if path == "" then path = ("[No Name #%d]"):format(buf) end
  local sel = {
    body = table.concat(lines, "\n"),
    path = path,
    ft = vim.bo[buf].filetype or "",
    range = string.format("L%d-L%d", s[1], e[1]),
  }
  require("ai-chat").open_with_sel(sel)
end, { desc = "ai-chat: open with selection as @sel" })
