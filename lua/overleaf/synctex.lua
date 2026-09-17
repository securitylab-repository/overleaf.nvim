--- SyncTeX forward search (nvim -> PDF).
---
--- Overleaf does not serve a compile's raw output.synctex.gz for direct
--- download (confirmed: a consistent 503 from its CDN, even though
--- output.pdf and output.log download fine from the same build) — its own
--- web client never does either. Instead it exposes a server-side lookup:
--- GET /project/<id>/sync/code?file=...&line=...&buildId=... returns the
--- matching {page, h, v} in the compiled PDF directly.
---
--- That response is a page + a position on it, not something a viewer's
--- own SyncTeX-file-based forward-search flag can consume (SumatraPDF's
--- `-forward-search` needs a local .synctex.gz, which we don't have), so
--- this jumps SumatraPDF to the right PAGE via `-page`, not the exact
--- position on it.
---
--- Inverse search (PDF -> nvim) is not implemented: SumatraPDF only runs
--- an external inverse-search command when it has resolved the click
--- itself from a local SyncTeX table, which — for the same reason as
--- above — isn't available here.
local config = require('overleaf.config')

local M = {}

--- Lazy require to avoid a load-order cycle with init.lua (same pattern as
--- the other submodules, e.g. tree.lua).
local function overleaf() return require('overleaf') end

local function generate_editor_id()
  math.randomseed(os.time() + (vim.uv or vim.loop).hrtime())
  local template = 'xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx'
  return (template:gsub('[xy]', function(c)
    local v = (c == 'x') and math.random(0, 0xf) or math.random(8, 0xb)
    return string.format('%x', v)
  end))
end

function M.forward_search()
  local ol = overleaf()
  if not ol._state.last_pdf_path then
    config.log('warn', 'No compiled PDF yet. Run :Overleaf compile first.')
    return
  end
  if not ol._state.last_build_id then
    config.log('warn', 'No build id from the last compile — run :Overleaf compile again.')
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

  if not ol._state.editor_id then ol._state.editor_id = generate_editor_id() end

  -- Overleaf's web editor (and this API) use 0-indexed lines, like CodeMirror;
  -- Neovim's cursor row is 1-indexed.
  local line = vim.api.nvim_win_get_cursor(0)[1] - 1

  local bridge = require('overleaf.bridge')
  bridge.request('syncCode', {
    cookie = config.get().cookie,
    projectId = ol._state.project_id,
    file = doc.path,
    line = line,
    column = 0,
    buildId = ol._state.last_build_id,
    editorId = ol._state.editor_id,
  }, function(err, result)
    if err then
      config.log('error', 'Forward search failed: %s', err.message)
      return
    end

    local hit = result.pdf and result.pdf[1]
    if not hit then
      config.log('warn', 'No matching PDF location found for this line')
      return
    end

    local cmd = {
      config.get().sumatra_path or 'SumatraPDF.exe',
      '-reuse-instance',
      '-page',
      tostring(hit.page),
      ol._state.last_pdf_path,
    }
    vim.fn.jobstart(cmd, { detach = true })
  end)
end

return M
