--- SyncTeX forward/inverse search.
---
--- Forward search (nvim -> PDF): shells out to SumatraPDF's own
--- `-forward-search` flag, which reads the .synctex.gz table itself — this
--- module never parses SyncTeX data.
---
--- Inverse search (PDF -> nvim): SumatraPDF is configured (via its
--- "Set inverse search command-line" setting) to run node/inverse-search.js
--- on double-click, which reaches this already-running Neovim instance
--- through `nvim --server <addr> --remote-expr` and calls M.inverse_goto().
---
--- Both directions require `sync_dir` to be set: SyncTeX only knows about
--- real file paths, so documents must be mirrored to disk.
local config = require('overleaf.config')
local sync = require('overleaf.sync')

local M = {}

--- Lazy require to avoid a load-order cycle with init.lua (same pattern as
--- the other submodules, e.g. tree.lua).
local function overleaf() return require('overleaf') end

local function server_file() return vim.fn.stdpath('data') .. '/overleaf-nvim-server.txt' end

--- Start (or reuse) a --listen server and publish its address to a
--- well-known file so the external inverse-search helper can find it.
function M.setup_server()
  local ok, addr = pcall(vim.fn.serverstart)
  if not ok or not addr or addr == '' then
    -- Already listening (e.g. started via `nvim --listen`) — reuse it.
    local list = vim.fn.serverlist()
    addr = list[1]
  end
  if not addr or addr == '' then return end

  local f = io.open(server_file(), 'w')
  if f then
    f:write(addr)
    f:close()
  end
end

function M.forward_search()
  local ol = overleaf()
  if not ol._state.last_pdf_path then
    config.log('warn', 'No compiled PDF yet. Run :Overleaf compile first.')
    return
  end

  if not config.get().sync_dir then
    config.log('error', 'Forward search needs `sync_dir` set in setup() (SyncTeX needs real files on disk).')
    return
  end

  local bufnr = vim.api.nvim_get_current_buf()
  local doc
  for _, d in pairs(ol._state.documents) do
    if d.bufnr == bufnr then
      doc = d
      break
    end
  end

  if not doc then
    config.log('warn', 'Not an Overleaf document')
    return
  end

  local src_path = sync.file_path(doc.path)
  local line = vim.api.nvim_win_get_cursor(0)[1]

  local cmd = {
    config.get().sumatra_path or 'SumatraPDF.exe',
    '-reuse-instance',
    '-forward-search',
    src_path,
    tostring(line),
    ol._state.last_pdf_path,
  }
  vim.fn.jobstart(cmd, { detach = true })
end

--- Called (via `nvim --remote-expr`) by node/inverse-search.js when the
--- user double-clicks a location in the PDF.
---@param file string absolute path to the .tex source, as resolved by SumatraPDF
---@param line number 1-indexed line number
function M.inverse_goto(file, line)
  local sync_dir = config.get().sync_dir
  if not sync_dir then return end
  sync_dir = vim.fn.expand(sync_dir)

  -- Normalize slashes/case for comparison (Windows paths, case-insensitive FS)
  local norm_file = file:gsub('\\', '/'):lower()
  local norm_dir = sync_dir:gsub('\\', '/'):lower()
  if norm_dir:sub(-1) ~= '/' then norm_dir = norm_dir .. '/' end

  if norm_file:sub(1, #norm_dir) ~= norm_dir then
    config.log('debug', 'Inverse search: %s is outside sync_dir', file)
    return
  end

  local doc_path = file:gsub('\\', '/'):sub(#norm_dir + 1)

  local project = require('overleaf.project')
  local info = project.get_doc_by_path(doc_path)
  if not info then
    config.log('warn', 'Inverse search: document not found for %s', doc_path)
    return
  end

  local ol = overleaf()
  ol.open_document(info.id, info.path, function(doc)
    if not (doc.bufnr and vim.api.nvim_buf_is_valid(doc.bufnr)) then return end

    local win = vim.fn.bufwinid(doc.bufnr)
    if win == -1 then
      vim.api.nvim_set_current_buf(doc.bufnr)
      win = vim.api.nvim_get_current_win()
    else
      vim.api.nvim_set_current_win(win)
    end

    local last_line = vim.api.nvim_buf_line_count(doc.bufnr)
    pcall(vim.api.nvim_win_set_cursor, win, { math.min(math.max(line, 1), last_line), 0 })
    vim.cmd('normal! zz')
  end)
end

return M
