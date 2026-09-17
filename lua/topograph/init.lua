local M = {}

local state = {
  tab = nil,
  wins = {},
  bufs = {},
  categories = {},
  grouped_data = {},
  client = nil,
  col3_members = {},
  col3_mode = "preview", -- "preview" | "members"
}

local KIND_NAMES = {
  [3]  = "Namespaces",
  [5]  = "Classes",
  [6]  = "Methods",
  [11] = "Interfaces",
  [12] = "Functions",
  [23] = "Structs",
}

local MEMBER_KINDS = {
  [6]  = "Method",
  [7]  = "Property",
  [8]  = "Field",
  [9]  = "Constructor",
  [10] = "Enum",
  [11] = "Interface",
  [12] = "Function",
  [13] = "Variable",
  [22] = "EnumMember",
  [23] = "Struct",
  [25] = "Operator",
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
  state.col3_members = {}
  state.col3_mode = "preview"
end

local function isProjectSource(filePath, root)
  if not filePath or filePath == "" then return false end

  local normFile = vim.fs.normalize(vim.uv.fs_realpath(filePath) or filePath)
  local normRoot = vim.fs.normalize(vim.uv.fs_realpath(root) or root)

  if not vim.startswith(normFile, normRoot) then
    return false
  end

  local rel = normFile:sub(#normRoot + 1):lower()
  local ignorePatterns = {
    "/vendor/",
    "/build/",
    "/_deps/",
    "/external/",
    "/third_party/",
    "/submodules/",
  }

  for _, pattern in ipairs(ignorePatterns) do
    if rel:find(pattern, 1, true) then
      return false
    end
  end

  return true
end

local function updatePreview(targetFile, startLine)
  if not state.bufs[3] or not vim.api.nvim_buf_is_valid(state.bufs[3]) then return end

  local fname = vim.fs.normalize(targetFile)
  if vim.fn.filereadable(fname) == 0 then
    vim.api.nvim_buf_set_lines(state.bufs[3], 0, -1, false, { "// File not readable: " .. fname })
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

  local ft = vim.filetype.match({ filename = fname })
  if ft then
    vim.bo[state.bufs[3]].syntax = ft
  end
end

local function updateCol2(categoryName)
  local items = state.grouped_data[categoryName] or {}
  local lines = {}

  for _, sym in ipairs(items) do
    local shortFile = vim.fs.basename(sym.file)
    table.insert(lines, string.format("%-26s [%s:%d]", sym.name, shortFile, sym.line + 1))
  end

  vim.api.nvim_buf_set_lines(state.bufs[2], 0, -1, false, lines)

  if #items > 0 then
    updatePreview(items[1].file, items[1].line)
  else
    vim.api.nvim_buf_set_lines(state.bufs[3], 0, -1, false, { "// No symbols in this category" })
  end
end

local function findSymbolNode(nodes, targetName, targetLine)
  if not nodes then return nil end
  for _, node in ipairs(nodes) do
    local range = node.range or (node.location and node.location.range)
    if node.name == targetName and range and range.start.line == targetLine then
      return node
    end
    if node.children and #node.children > 0 then
      local found = findSymbolNode(node.children, targetName, targetLine)
      if found then return found end
    end
  end
  return nil
end

local function drillDownMembers(sym)
  if not state.client then return end

  local uri = vim.uri_from_fname(sym.file)
  local params = { textDocument = { uri = uri } }

  state.client:request("textDocument/documentSymbol", params, function(err, result)
    if err or not result or #result == 0 then
      vim.notify("Could not retrieve members for " .. sym.name, vim.log.levels.WARN)
      return
    end

    local node = findSymbolNode(result, sym.name, sym.line)
    if not node or not node.children or #node.children == 0 then
      vim.notify("No child members found in " .. sym.name, vim.log.levels.INFO)
      return
    end

    state.col3_members = {}
    local lines = {}

    for _, child in ipairs(node.children) do
      local childRange = child.range or (child.location and child.location.range)
      local kindLabel = MEMBER_KINDS[child.kind] or "Member"

      table.insert(state.col3_members, {
        name = child.name,
        file = sym.file,
        line = childRange and childRange.start.line or sym.line,
        col = childRange and childRange.start.character or 0,
      })

      table.insert(lines, string.format("%-14s %s", "[" .. kindLabel .. "]", child.name))
    end

    state.col3_mode = "members"
    vim.bo[state.bufs[3]].syntax = ""
    vim.api.nvim_buf_set_lines(state.bufs[3], 0, -1, false, lines)
    vim.api.nvim_set_current_win(state.wins[3])
  end)
end

local function attachEvents()
  for _, buf in ipairs(state.bufs) do
    vim.keymap.set("n", "q", closeUI, { buffer = buf, silent = true, nowait = true })
  end

  local navCol1 = { buffer = state.bufs[1], silent = true }
  vim.keymap.set("n", "l", function() vim.api.nvim_set_current_win(state.wins[2]) end, navCol1)
  vim.keymap.set("n", "<CR>", function() vim.api.nvim_set_current_win(state.wins[2]) end, navCol1)

  vim.keymap.set("n", "h", function()
    vim.api.nvim_set_current_win(state.wins[1])
  end, { buffer = state.bufs[2], silent = true })

  vim.keymap.set("n", "l", function()
    local cursor1 = vim.api.nvim_win_get_cursor(state.wins[1])
    local catName = state.categories[cursor1[1]]
    local items = state.grouped_data[catName] or {}
    local cursor2 = vim.api.nvim_win_get_cursor(state.wins[2])
    local selectedSym = items[cursor2[1]]

    if selectedSym and (catName == "Classes" or catName == "Structs") then
      drillDownMembers(selectedSym)
    else
      vim.notify("Drill-down only available for Classes and Structs", vim.log.levels.INFO)
    end
  end, { buffer = state.bufs[2], silent = true })

  vim.keymap.set("n", "<CR>", function()
    local cursor1 = vim.api.nvim_win_get_cursor(state.wins[1])
    local catName = state.categories[cursor1[1]]
    local items = state.grouped_data[catName] or {}
    local cursor2 = vim.api.nvim_win_get_cursor(state.wins[2])
    local selectedSym = items[cursor2[1]]

    if selectedSym then
      closeUI()
      vim.cmd("edit " .. vim.fn.fnameescape(selectedSym.file))
      vim.api.nvim_win_set_cursor(0, { selectedSym.line + 1, selectedSym.col })
    end
  end, { buffer = state.bufs[2], silent = true })

  vim.keymap.set("n", "h", function()
    state.col3_mode = "preview"
    vim.api.nvim_set_current_win(state.wins[2])
    local cursor1 = vim.api.nvim_win_get_cursor(state.wins[1])
    local catName = state.categories[cursor1[1]]
    local items = state.grouped_data[catName] or {}
    local cursor2 = vim.api.nvim_win_get_cursor(state.wins[2])
    local selectedSym = items[cursor2[1]]
    if selectedSym then
      updatePreview(selectedSym.file, selectedSym.line)
    end
  end, { buffer = state.bufs[3], silent = true })

  vim.keymap.set("n", "<CR>", function()
    if state.col3_mode == "members" then
      local cursor3 = vim.api.nvim_win_get_cursor(state.wins[3])
      local member = state.col3_members[cursor3[1]]
      if member then
        closeUI()
        vim.cmd("edit " .. vim.fn.fnameescape(member.file))
        vim.api.nvim_win_set_cursor(0, { member.line + 1, member.col })
      end
    end
  end, { buffer = state.bufs[3], silent = true })

  vim.api.nvim_create_autocmd("CursorMoved", {
    buffer = state.bufs[1],
    callback = function()
      local cursor = vim.api.nvim_win_get_cursor(state.wins[1])
      local catName = state.categories[cursor[1]]
      if catName then
        state.col3_mode = "preview"
        updateCol2(catName)
      end
    end,
  })

  vim.api.nvim_create_autocmd("CursorMoved", {
    buffer = state.bufs[2],
    callback = function()
      if state.col3_mode ~= "preview" then return end
      local cursor1 = vim.api.nvim_win_get_cursor(state.wins[1])
      local catName = state.categories[cursor1[1]]
      local items = state.grouped_data[catName] or {}
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

  local root = vim.fs.root(0, { "compile_commands.json", "CMakeLists.txt", ".git" }) or vim.fn.getcwd()

  for _, sym in ipairs(rawSym) do
    local group = KIND_NAMES[sym.kind]
    if group then
      local loc = sym.location or sym.locationInformation
      local uri = loc and loc.uri or sym.uri
      local range = loc and loc.range or sym.range

      if uri and range then
        local filePath = vim.uri_to_fname(uri)

        if isProjectSource(filePath, root) then
          state.grouped_data[group] = state.grouped_data[group] or {}
          table.insert(state.grouped_data[group], {
            name = sym.name,
            file = filePath,
            line = range.start.line,
            col = range.start.character,
          })
        end
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

local function getOrStartClient(callback)
  local clients = vim.lsp.get_clients()
  for _, client in ipairs(clients) do
    if client:supports_method("workspace/symbol") then
      callback(client)
      return
    end
  end

  local root = vim.fs.root(0, { "compile_commands.json", "CMakeLists.txt", ".git" }) or vim.fn.getcwd()
  vim.notify("Starting clangd for workspace: " .. vim.fs.basename(root), vim.log.levels.INFO)

  local clientId = vim.lsp.start({
    name = "clangd",
    cmd = {
      "clangd",
      "--background-index",
      "--limit-results=0",
      "--header-insertion=never",
    },
    root_dir = root,
  })

  if not clientId then
    vim.notify("Could not launch clangd", vim.log.levels.ERROR)
    return
  end

  local client = vim.lsp.get_client_by_id(clientId)
  if not client then return end

  if vim.api.nvim_buf_get_name(0) == "" then
    local sourceFiles = vim.fs.find(function(name, path)
      if path:match("/vendor") or path:match("/build") or path:match("/%.git") then
        return false
      end
      return name:match("%.cpp$") or name:match("%.c$") or name:match("%.h$") or name:match("%.hpp$")
    end, { path = root, type = "file", limit = 50 })

    for _, targetFile in ipairs(sourceFiles) do
      local preloadBuf = vim.fn.bufadd(targetFile)
      vim.fn.bufload(preloadBuf)
      vim.lsp.buf_attach_client(preloadBuf, clientId)
    end
  end

  vim.defer_fn(function()
    callback(client)
  end, 2000)
end

function M.open()
  getOrStartClient(function(client)
    state.client = client

    client:request("workspace/symbol", { query = "" }, function(err, result)
      if err or not result or #result == 0 then
        vim.notify("No workspace symbols found in current project", vim.log.levels.WARN)
        return
      end

      local col1Labels = processLSPSymbols(result)
      if #col1Labels == 0 then
        vim.notify("No matching Classes, Structs, or Functions found", vim.log.levels.INFO)
        return
      end

      vim.cmd("tabnew")
      state.tab = vim.api.nvim_get_current_tabpage()

      state.bufs[1] = createScratchBuf()
      state.bufs[2] = createScratchBuf()
      state.bufs[3] = createScratchBuf()

      local totalCols = vim.o.columns
      local col1Width = math.floor(totalCols * 0.2)
      local col2Width = math.floor(totalCols * 0.3)

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
      vim.api.nvim_win_set_width(state.wins[2], col2Width)

      vim.api.nvim_buf_set_lines(state.bufs[1], 0, -1, false, col1Labels)
      updateCol2(state.categories[1])

      attachEvents()
    end)
  end)
end

return M

