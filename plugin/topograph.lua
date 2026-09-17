vim.api.nvim_create_user_command("Topograph", function ()
	require("topograph").open()
end, {})
