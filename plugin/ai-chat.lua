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
