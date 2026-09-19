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
--- Highlighting the matched text: sync/code also returns the matched box's
--- `width`/`height`, but SumatraPDF has no flag to draw an arbitrary
--- rectangle. Its own forward-search highlight (the coloured, fading box
--- configured by `ForwardSearch.HighlightColor` in its settings) is only
--- drawn when it resolves a `-forward-search` from a local SyncTeX table.
--- So write a one-record SyncTeX table next to the PDF that maps a
--- placeholder source line onto that box, and let SumatraPDF resolve it.
--- (`write_highlight_synctex` below.)
---
--- Inverse search (PDF -> nvim) is not implemented: SumatraPDF only runs
--- an external inverse-search command when it has resolved the click
--- itself from a local SyncTeX table, and the one above only covers the
--- last forward-search box, not the document.
local config = require('overleaf.config')

local M = {}

--- Placeholder source name shared by the generated SyncTeX table and the
--- `-forward-search` call. It never has to exist on disk: SumatraPDF only
--- matches it by name against the table's `Input:` entry.
local HIGHLIGHT_SOURCE = 'overleaf-forward-search.tex'

--- One PDF point (bp, what sync/code returns) in TeX scaled points (sp, what
--- SyncTeX files store): 1 bp = 72.27/72 pt, 1 pt = 65536 sp.
local SP_PER_BP = 65536 * 72.27 / 72

--- Bounds on the extra work done to find the edges of the highlighted
--- range: source lines scanned each way for a paragraph's edge, and
--- sync/code queries per edge (see `M._probe`).
local MAX_PARAGRAPH_LINES = 40
local MAX_PROBES = 6

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

---@param bp number
---@return string
local function to_sp(bp) return string.format('%.0f', bp * SP_PER_BP) end

--- Build the SyncTeX table (text form) mapping `HIGHLIGHT_SOURCE` line 1
--- onto the box sync/code returned. The box is `(h, v)` = left/bottom edge,
--- `width` x `height` up from there, in PDF points measured from the page's
--- top-left, i.e. exactly SyncTeX's own `(h, v : W, H, D)` hbox record with
--- no depth. The enclosing sheet/vbox sizes only have to be non-degenerate.
---@param hit table sync/code result entry: page, h, v, width, height
---@return string|nil content nil when `hit` lacks a usable box
function M._highlight_synctex(hit)
  local page = tonumber(hit.page)
  local h, v, w, ht = tonumber(hit.h), tonumber(hit.v), tonumber(hit.width), tonumber(hit.height)
  if not (page and h and v and w and ht) or page < 1 or w <= 0 or ht <= 0 then return nil end
  page = math.floor(page)

  return table.concat({
    'SyncTeX Version:1',
    'Input:1:' .. HIGHLIGHT_SOURCE,
    'Output:pdf',
    'Magnification:1000',
    'Unit:1',
    'X Offset:0',
    'Y Offset:0',
    'Content:',
    string.format('{%d', page),
    string.format('[1,1:0,0:%s,%s,0', to_sp(2000), to_sp(2000)),
    string.format('(1,1:%s,%s:%s,%s,0', to_sp(h), to_sp(v), to_sp(w), to_sp(ht)),
    ')',
    ']',
    string.format('}%d', page),
    'Postamble:',
    'Count:3',
    'Post scriptum:',
    '',
  }, '\n')
end

--- Write the table next to `pdf_path` under the name SumatraPDF looks for
--- (same basename, `.synctex`). Written in binary mode so Windows doesn't
--- turn the newlines into CRLF.
---@param pdf_path string
---@param hit table
---@return boolean written
local function write_highlight_synctex(pdf_path, hit)
  local base = pdf_path:match('^(.*)%.[Pp][Dd][Ff]$')
  local content = base and M._highlight_synctex(hit)
  if not content then return false end

  local f, err = io.open(base .. '.synctex', 'wb')
  if not f then
    config.log('debug', 'Could not write highlight SyncTeX table: %s', tostring(err))
    return false
  end
  f:write(content)
  f:close()
  return true
end

--- Source lines to highlight around the cursor, inclusive and 1-indexed.
--- `range` is a number N (N lines before and after) or 'paragraph' (the
--- block of non-blank lines the cursor is in, capped at
--- MAX_PARAGRAPH_LINES each way so a missing blank line can't select the
--- whole file). A blank cursor line is never widened.
---@param lines string[]
---@param row integer
---@param range integer|string|nil
---@return integer first
---@return integer last
function M._highlight_range(lines, row, range)
  local n = #lines
  if type(range) == 'number' then
    range = math.max(0, math.floor(range))
    return math.max(1, row - range), math.min(n, row + range)
  end

  local function blank(i) return lines[i] == nil or lines[i]:match('^%s*$') ~= nil end
  if blank(row) then return row, row end

  local first, last = row, row
  while first > 1 and row - first < MAX_PARAGRAPH_LINES and not blank(first - 1) do
    first = first - 1
  end
  while last < n and last - row < MAX_PARAGRAPH_LINES and not blank(last + 1) do
    last = last + 1
  end
  return first, last
end

--- Smallest box covering every hit on `page`. Hits on other pages are
--- ignored: SumatraPDF only highlights on the page it scrolls to, so a
--- paragraph that runs across a page break is cut at that break.
---@param hits table[] sync/code result entries
---@param page integer
---@return table|nil box same shape as a hit, nil if none is usable
function M._union_hits(hits, page)
  local left, right, top, bottom
  for _, hit in ipairs(hits) do
    local h, v, w, ht = tonumber(hit.h), tonumber(hit.v), tonumber(hit.width), tonumber(hit.height)
    if tonumber(hit.page) == page and h and v and w and ht and w > 0 and ht > 0 then
      left = math.min(left or h, h)
      right = math.max(right or h + w, h + w)
      top = math.min(top or v - ht, v - ht)
      bottom = math.max(bottom or v, v)
    end
  end
  if not left then return nil end
  return { page = page, h = left, v = bottom, width = right - left, height = bottom - top }
end

--- Query sync/code for each of `candidates` (source lines) in turn until
--- one maps to at least one box, then call `cb` with those boxes (an empty
--- list if none does, or after MAX_PROBES tries).
---@param sync_code fun(line: integer, column: integer, cb: fun(err: table|nil, result: table|nil))
---@param candidates integer[]
---@param cb fun(pdf: table[])
function M._probe(sync_code, candidates, cb)
  local i = 0
  local function step()
    i = i + 1
    local candidate = candidates[i]
    if not candidate or i > MAX_PROBES then return cb({}) end
    sync_code(candidate, 0, function(err, result)
      local pdf = not err and result and result.pdf or {}
      if #pdf > 0 then
        cb(pdf)
      else
        step()
      end
    end)
  end
  step()
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
  local function sync_code(l, col, cb)
    bridge.request('syncCode', {
      cookie = config.get().cookie,
      csrfToken = ol._state.csrf_token,
      projectId = ol._state.project_id,
      file = sync_file,
      line = l,
      column = col,
      buildId = ol._state.last_build_id,
      editorId = M.ensure_editor_id(),
      clsiServerId = meta.clsiServerId,
    }, cb)
  end

  --- Open the PDF on `primary`, highlighting `box` when there is one.
  local function show(primary, box)
    local pdf_path = ol._state.last_pdf_path
    local cmd = { config.get().sumatra_path or 'SumatraPDF.exe', '-reuse-instance' }
    if box and write_highlight_synctex(pdf_path, box) then
      -- SumatraPDF scrolls to the box and draws its forward-search highlight
      -- there (see the header comment).
      vim.list_extend(cmd, { '-forward-search', HIGHLIGHT_SOURCE, '1' })
    else
      table.insert(cmd, '-page')
      table.insert(cmd, tostring(primary.page))
      -- h/v are the synctex-convention point offset on the page (same
      -- coordinate space SumatraPDF's own forward-search highlight uses) —
      -- scroll there directly instead of just landing on top of the page.
      if primary.h and primary.v then
        table.insert(cmd, '-scroll')
        table.insert(cmd, string.format('%s,%s', tostring(primary.h), tostring(primary.v)))
      end
    end
    table.insert(cmd, pdf_path)
    vim.fn.jobstart(cmd, { detach = true })
  end

  sync_code(line, column, function(err, result)
    if err then
      config.log('error', 'Forward search failed: %s', err.message)
      return
    end

    local cursor_hits = result.pdf or {}
    local highlight = config.get().forward_search_highlight ~= false

    -- The lines around the cursor to cover too. Each edge is probed on its
    -- own (concurrently), since sync/code only maps one source line at a
    -- time and the edge lines are often commands with no box of their own.
    local first, last = line, line
    if highlight then
      local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
      first, last = M._highlight_range(lines, line, config.get().forward_search_range)
    end
    local before, after = {}, {}
    for l = first, line - 1 do
      table.insert(before, l)
    end
    for l = last, line + 1, -1 do
      table.insert(after, l)
    end

    local before_hits, after_hits = {}, {}
    local pending = (#before > 0 and 1 or 0) + (#after > 0 and 1 or 0)

    local function finish()
      local all = vim.list_extend(vim.list_extend(vim.list_extend({}, cursor_hits), before_hits), after_hits)
      local primary = all[1]
      if not primary then
        config.log(
          'warn',
          'No matching PDF location found for this line — the file may not be part of the current compile (check the project'
            .. "'s Main file in Overleaf) or this line has no mapped position (e.g. blank lines, preamble)"
        )
        return
      end
      show(primary, highlight and M._union_hits(all, tonumber(primary.page)) or nil)
    end

    local function probe_edge(candidates, into)
      M._probe(sync_code, candidates, function(pdf)
        vim.list_extend(into, pdf)
        pending = pending - 1
        if pending == 0 then finish() end
      end)
    end

    if pending == 0 then return finish() end
    if #before > 0 then probe_edge(before, before_hits) end
    if #after > 0 then probe_edge(after, after_hits) end
  end)
end

return M
