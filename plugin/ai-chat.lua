if vim.g.loaded_ai_chat then return end
vim.g.loaded_ai_chat = 1

vim.api.nvim_create_user_command("AiChatTest", function(args)
  require("ai-chat").test_send(args.args)
end, { nargs = "+", desc = "Send a one-shot test prompt to Claude" })
