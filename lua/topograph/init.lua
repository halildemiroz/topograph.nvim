local M = {}

local state = {
	tab = nil,
	wins = {},
	bufs = {},
	categories = {},
	grouped_data = {}
}

local KIND_NAMES = {
	[3] = "Namespaces",
	[5] = "Classes",
	[6] = "Methods",
	[11] = "Functios",
	[23] = "Structs",
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
	state.grouped_data = {}
	state.categories = {}
end

local function updatePreview(targetFile, startLine)
	if not state.bufs[3] or not vim.api.nvim_buf_is_valid(state.bufs[3]) then return end

	local fname = vim.fs.normalize(targetFile)
	if vim.fn.filereadable(fname) == 0 then
		vim.api.nvim_buf_set_lines(state.bufs[3], 0, -1, false, {"// File not readable: " .. fname})
		return
	end
	
	local allLines = vim.fn.readfile(fname)
	local lineIndex = startLine + 1
	local previewStart = math.max(1, lineIndex - 2)
	local previewEnd = math.min(#allLines, lineIndex + 25)

	local previewLines = {}
	for i = previewStart, previewEnd do
		table.insert(previewLines, allLines[i])
	end
	
	vim.api.nvim_buf_set_lines(state.bufs[3], 0, -1, false, previewLines)
	
	local ft = vim.filetype.match({filename = fname})
	if ft then
		vim.bo[state.bufs[3]].syntax = ft
	end
end

local function updateCol2(categoryName)
	local items = state.grouped_data[categoryName] or {}
	local lines = {}
	
	for _, sym in ipairs(items) do
		local shortFile = vim.fs.basename(sym.file)
		table.insert(lines, string.format("%-26s [%s:%d]"), sym.name, shortFile, sym.line + 1)
	end
	
	vim.api.nvim_buf_set_lines(state.bufs[2], 0, -1, false, lines)

	if #items > 0 then
		updatePreview(items[1].file, items[1].line)
	else
		vim.api.nvim_buf_set_lines(state.bufs[3], 0, -1, false, {"// No symbols in this category"})
	end
end

local function attachEvents()
  local categories = { "Structs (3)", "Classes (2)", "Namespaces (1)" }
	
	for _, buf in ipairs(state.bufs) do
		vim.keymap.set("n", "q", closeUI, { buffer = buf, silent = true, nowait = true })
	end
	
	local navCol1 = {buffer = state.bufs[1], silent = true}
	vim.keymap.set("n", "l", function() vim.api.nvim_set_current_win(state.wins[1]) end, {buffer = state.bufs[2], silent=true})
  vim.keymap.set("n", "<CR>", function() vim.api.nvim_set_current_win(state.wins[2]) end, navCol1)
	vim.keymap.set("n", "h", function() vim.api.nvim_set_current_win(state.wins[1]) end, { buffer = state.bufs[2], silent = true })

	vim.keymap.set("n", "<CR>", function()
		local cursor1 = vim.api.nvim_win_get_cursor(state.wins[1])
		local catName = state.categories[cursor1[1]]
		local items = state.grouped_data[catName] or {}
		local cursor2 = vim.api.nvim_win_get_cursor(state.wins[2])
		local selectedSym = items[cursor2[1]]
		
		if selectedSym then
			closeUI()
			vim.cmd("edit " .. vim.fn.fnameescape(selectedSym.file))
			vim.api.nvim_win_set_cursor(0, {selectedSym.line + 1, selectedSym.col})
		end
	end, {buffer = state.bufs[2], silent = true})

	vim.api.nvim_create_autocmd("CursorMoved", {
		buffer = state.bufs[1],
		callback = function()
			local cursor = vim.api.nvim_win_get_cursor(state.wins[1])
			local catName = state.categories[cursor[1]]
			if catName then
				updateCol2(catName)
			end
		end
	})

	vim.api.nvim_create_autocmd("CursorMoved", {
		buffer = state.bufs[2],
		callback = function()
			local cursor1 = vim.api.nvim_win_get_cursor(state.wins[1])
			local cat_name = state.categories[cursor1[1]]
      local items = state.grouped_data[cat_name] or {}
      local cursor2 = vim.api.nvim_win_get_cursor(state.wins[2])
      local selectedSym = items[cursor2[1]]

			if selectedSym then
				updatePreview(selectedSym.file, selectedSym.line)
			end
		end,
	})
end

local function processLSPSymbols(rawSym)
	state.grouped_data = {}
	state.categories = {}

	for _, sym in ipairs(rawSym) do
		local group = KIND_NAMES[sym.kind]
		if group then
			state.grouped_data[group] = state.grouped_data[group] or {}

			local loc = sym.location or sym.locationInformation
			local uri = loc and loc.uri or sym.uri
			local range = loc and loc.range or sym.range

			if uri and range then
				table.insert(state.grouped_data[group], {
						name = sym.name,
						file = vim.uri_to_fname(uri),
						line = range.start.line,
						col = range.start.character,
					})
			end
		end
	end
	
	local col1Labels = {}
	for _, kindName in pairs(KIND_NAMES) do
		local count = state.grouped_data[kindName] and #state.grouped_data[kindName] or 0
		if count > 0 then
			table.insert(state.categories, kindName)
			table.insert(col1Labels, string.format("%s (%d)", kindName, count))
		end
	end
	return col1Labels
end

function M.open()
	vim.lsp.buf_request(0, "workspace/symbol", { query = "" }, function(err, result)
		if err or not result or #result == 0 then
			vim.notify("No workspace symbols found from active LSP", vim.log.levels.WARN)
			return
		end
		
		local col1Labels = processLSPSymbols(result)
		if #col1Labels == 0 then
			vim.notify("No matching symbol found", vim.log.levels.INFO)
			return
		end

		vim.cmd("tabnew")
    state.tab = vim.api.nvim_get_current_tabpage()

    state.bufs[1] = create_scratch_buf()
    state.bufs[2] = create_scratch_buf()
    state.bufs[3] = create_scratch_buf()

    -- 2 : 3 : 5 column sizing
    local total_cols = vim.o.columns
    local col1_width = math.floor(total_cols * 0.2)
    local col2_width = math.floor(total_cols * 0.3)

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

    vim.api.nvim_win_set_width(state.wins[1], col1_width)
    vim.api.nvim_win_set_width(state.wins[2], col2_width)

    -- Populate Column 1 and trigger initial preview
    vim.api.nvim_buf_set_lines(state.bufs[1], 0, -1, false, col1_labels)
    update_col2(state.categories[1])

    attach_events()
  end)
end

return M
