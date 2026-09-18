--- SyncTeX forward search (nvim -> PDF).
---
--- Overleaf does not serve a compile's raw output.synctex.gz for direct
--- download (confirmed: a consistent 503 from its CDN, even though
--- output.pdf and output.log download fine from the same build) — its own
--- web client never does either. Instead it exposes a server-side lookup:
--- GET /project/<id>/sync/code?file=...&line=...&buildId=...&editorId=...
--- returns the matching {page, h, v} in the compiled PDF directly (the
--- same endpoint its "jump to PDF" button uses). `page`/`h`/`v` are passed
--- to SumatraPDF via `-page`/`-scroll`, landing on the exact position, not
--- just the page.
---
--- `file` has to be given in synctex's own path convention, which is
--- relative to the root document's directory and marks that directory with
--- a literal "/." segment (see `to_synctex_path` below) — get this wrong
--- and sync/code silently returns no match for otherwise-valid requests.
--- This only bites multi-file projects whose root doc lives in a
--- subfolder; a root-level main.tex never needs the transform.
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
local function project() return require('overleaf.project') end

--- SyncTeX records a compiled-in file's path relative to the root
--- document's own directory (its compile working directory) — so a file
--- that lives in the *same* directory as the root doc appears in synctex
--- as "<rootDir>/./name.tex", not plain "<rootDir>/name.tex". Overleaf's
--- own web client applies this exact transform before calling sync/code
--- (services/web/.../use-synctex.ts, getCurrentFilePath) — single-file and
--- root-at-project-root projects never hit it (rootDir is empty), which is
--- why this only showed up on multi-file projects with the root doc inside
--- a subfolder.
---@param doc_path string
---@param root_doc_path string|nil
---@return string
local function to_synctex_path(doc_path, root_doc_path)
  local root_dir = root_doc_path and root_doc_path:match('^(.*)/[^/]+$')
  if root_dir and root_dir ~= '' and doc_path:sub(1, #root_dir) == root_dir then
    return root_dir .. '/.' .. doc_path:sub(#root_dir + 1)
  end
  return doc_path
end

--- Ensure this session has a stable editorId, creating one if needed.
---@return string
function M.ensure_editor_id()
  local ol = overleaf()
  if not ol._state.editor_id then
    math.randomseed(os.time() + (vim.uv or vim.loop).hrtime())
    local template = 'xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx'
    ol._state.editor_id = (template:gsub('[xy]', function(c)
      local v = (c == 'x') and math.random(0, 0xf) or math.random(8, 0xb)
      return string.format('%x', v)
    end))
  end
  return ol._state.editor_id
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

  -- Overleaf's web editor sends 1-indexed lines (`row + 1` from its
  -- 0-indexed CodeMirror row) — matches Neovim's cursor row as-is.
  local cursor = vim.api.nvim_win_get_cursor(0)
  local line, column = cursor[1], cursor[2]

  local meta = ol._state.last_compile_meta or {}

  local root_doc_id = ol._state.project_data and ol._state.project_data.rootDoc_id
  local root_doc = root_doc_id and project().get_doc_by_id(root_doc_id)
  local sync_file = to_synctex_path(doc.path, root_doc and root_doc.path)

  local bridge = require('overleaf.bridge')
  bridge.request('syncCode', {
    cookie = config.get().cookie,
    csrfToken = ol._state.csrf_token,
    projectId = ol._state.project_id,
    file = sync_file,
    line = line,
    column = column,
    buildId = ol._state.last_build_id,
    editorId = M.ensure_editor_id(),
    clsiServerId = meta.clsiServerId,
  }, function(err, result)
    if err then
      config.log('error', 'Forward search failed: %s', err.message)
      return
    end

    local hit = result.pdf and result.pdf[1]
    if not hit then
      config.log(
        'warn',
        'No matching PDF location found for this line — the file may not be part of the current compile (check the project'
          .. "'s Main file in Overleaf) or this line has no mapped position (e.g. blank lines, preamble)"
      )
      return
    end

    local cmd = {
      config.get().sumatra_path or 'SumatraPDF.exe',
      '-reuse-instance',
      '-page',
      tostring(hit.page),
    }
    -- h/v are the synctex-convention point offset on the page (same
    -- coordinate space SumatraPDF's own forward-search highlight uses) —
    -- scroll there directly instead of just landing on top of the page.
    if hit.h and hit.v then
      table.insert(cmd, '-scroll')
      table.insert(cmd, string.format('%s,%s', tostring(hit.h), tostring(hit.v)))
    end
    table.insert(cmd, ol._state.last_pdf_path)
    vim.fn.jobstart(cmd, { detach = true })
  end)
end

return M
