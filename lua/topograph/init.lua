local M = {}

local state = {
	tab = nil,
	wins = {},
	bufs = {}
}

local mock_data = {
  ["Structs (3)"] = {
    { name = "Entity", file = "Entity.h", line = 6, code = { "namespace Monolith {", "  struct Entity {", "    uint32_t index = 0;", "    uint32_t generation = 0;", "  };", "}" } },
    { name = "Registry", file = "Registry.h", line = 12, code = { "struct Registry {", "  std::vector<Entity> entities;", "};" } },
    { name = "Transform", file = "Components.h", line = 20, code = { "struct Transform {", "  float x, y, z;", "};" } },
  },
  ["Classes (2)"] = {
    { name = "CollisionSystem", file = "CollisionSystem.h", line = 8, code = { "class CollisionSystem {", "public:", "  void update();", "};" } },
    { name = "ScriptEngine", file = "ScriptEngine.h", line = 15, code = { "class ScriptEngine {", "  void execute();", "};" } },
  },
  ["Namespaces (1)"] = {
    { name = "Monolith", file = "Common.h", line = 1, code = { "namespace Monolith {", "  // Global definitions", "}" } },
  },
}

local function createScratchBuf()
	local buf = vim.api.nvim_create_buf(false, true)
	vim.bo[buf].buftype = "nofile"
	vim.bo[buf].bufhidden = "wipe"
	return buf
end

local function closeUI()
	if state.tab and vim.api.nvim_tabpage_is_valid(state.tab) then
		vim.cmd("tabclose")
	end
	state.tab = nil
	state.wins = {}
	state.bufs = {}
end

local function updatePreview(codeLines)
	if not state.bufs[3] or not vim.api.nvim_buf_is_valid(state.bufs[3]) then return end
	vim.api.nvim_buf_set_lines(state.bufs[3], 0, -1, false, codeLines or {"// No preview avaiable"})
end

local function updateCol2(categoryName)
	local items = mock_data[categoryName] or {}
	local lines = {}
	for _, item in ipairs(items) do
		table.insert(lines, string.format("%-18s [%s]", item.name, item.file))
	end
	vim.api.nvim_buf_set_lines(state.bufs[2], 0, -1, false, lines)

	if #items > 0 then
		updatePreview(items[1].code)
	else
		updatePreview({"// Empty category"})
	end
end

local function attachEvents()
  local categories = { "Structs (3)", "Classes (2)", "Namespaces (1)" }
	
	for _, buf in ipairs(state.bufs) do
		vim.keymap.set("n", "q", closeUI, { buffer = buf, silent = true, nowait = true })
	end

	local navOpts = { buffer = state.bufs[1], silent = true }
	vim.keymap.set("n", "l", function() vim.api.nvim_set_current_win(state.wins[2]) end, navOpts)
	vim.keymap.set("n", "<CR>", function() vim.api.nvim_set_current_win(state.wins[2]) end, navOpts)

	vim.keymap.set("n", "h", function() vim.api.nvim_set_current_win(state.wins[1]) end, {buffer = state.bufs[2], silent = true})

	vim.api.nvim_create_autocmd("CursorMoved", {
			buffer = state.bufs[1],
			callback = function()
				local cursor = vim.api.nvim_win_get_cursor(state.wins[1])
				local selected_cat = categories[cursor[1]]
				if selected_cat then
					updateCol2(selected_cat)
				end
			end,
		})
	end

	function M.open()
		vim.cmd("tabnew")
		state.tab = vim.api.nvim_get_current_tabpage()

		state.bufs[1] = createScratchBuf()
		state.bufs[2] = createScratchBuf()
		state.bufs[3] = createScratchBuf()

		local totalCols = vim.o.columns
		local col1Width = math.floor(totalCols * 0.2)
		local col2Widht = math.floor(totalCols * 0.3)

		state.wins[1] = vim.api.nvim_get_current_win()
		vim.api.nvim_win_set_buf(state.wins[1], state.bufs[1])

		state.wins[2] = vim.api.nvim_open_win(state.bufs[2], false, {
				win = state.wins[1],
				split = "right",
			})

		state.wins[3] = vim.api.nvim_open_win(state.bufs[3], false, {
				win = state.wins[2],
				split = "right",
			})

	vim.api.nvim_win_set_width(state.wins[1], col1Width)
	vim.api.nvim_win_set_width(state.wins[2], col2Widht)

  local categories = { "Structs (3)", "Classes (2)", "Namespaces (1)" }
	vim.api.nvim_buf_set_lines(state.bufs[1], 0, -1, false, categories)

	updateCol2(categories[1])
	attachEvents()
end

return M
