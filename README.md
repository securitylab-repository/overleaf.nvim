# overleaf.nvim

Neovim plugin for real-time collaborative LaTeX editing on [Overleaf](https://www.overleaf.com).

Edit your Overleaf projects directly in Neovim with full real-time collaboration support via Operational Transformation (OT). Use your favorite Neovim plugins — treesitter, LSP, snippets, copilot, and more — while collaborating with others on Overleaf.

## Features

- **Real-time collaboration** — edits sync instantly with other Overleaf users via OT
- **Full Neovim ecosystem** — treesitter, LSP, snippets, copilot, and all your plugins work out of the box
- **File tree** — browse and manage project files in a sidebar
- **Auto-authentication** — extracts session cookie from Chrome automatically (macOS)
- **Auto-reconnect** — recovers from disconnects and document restores seamlessly
- **Compile & PDF preview** — compile LaTeX and open the PDF
- **Comments & reviews** — view, reply, resolve comment threads
- **Collaborator cursors** — see where other users are editing
- **Project-wide search** — grep across all documents
- **File management** — create, delete, rename, upload files
- **History** — view project version history
- **Diagnostics** — chktex linter + LaTeX compile errors via `vim.diagnostic`
- **LSP support** — auto-attaches texlab, ltex, harper_ls to overleaf buffers
- **Local file sync** — mirror documents to disk for external tools (Claude Code, etc.)

## Requirements

- Neovim >= 0.10
- Node.js >= 18
- An [Overleaf](https://www.overleaf.com) account
- Chrome / Chromium (for automatic cookie extraction) or a session cookie

## Installation

### lazy.nvim

```lua
{
  'richwomanbtc/overleaf.nvim',
  config = function()
    require('overleaf').setup()
  end,
  build = 'cd node && npm install',
}
```

If Node.js is not on your default PATH (e.g., installed via Homebrew on macOS):

```lua
{
  'richwomanbtc/overleaf.nvim',
  config = function()
    require('overleaf').setup({
      node_path = '/opt/homebrew/bin/node',
    })
  end,
  build = 'cd node && npm install',
}
```

### Manual

```sh
git clone https://github.com/richwomanbtc/overleaf.nvim ~/.local/share/nvim/lazy/overleaf.nvim
cd ~/.local/share/nvim/lazy/overleaf.nvim/node && npm install
```

## Authentication

### Option 1: Chrome (automatic)

Just log in to [overleaf.com](https://www.overleaf.com) in Chrome. The plugin extracts the session cookie automatically. If you have multiple Chrome profiles, you'll be prompted to select one.

### Option 2: Manual cookie

Create a `.env` file in your working directory:

```
OVERLEAF_COOKIE=your_overleaf_session2_cookie_here
```

Or pass it directly in setup:

```lua
require('overleaf').setup({
  cookie = 'your_overleaf_session2_cookie_here',
})
```

> **Warning:** If you use this method, make sure your Neovim config is not committed to a public dotfiles repository — the cookie would grant full access to your Overleaf account.

To get the cookie manually: open overleaf.com in your browser → DevTools (F12) → Application → Cookies → `www.overleaf.com` → find `overleaf_session2` → copy the cookie value (starts with `overleaf_session2=s%3A...`).

## Usage

### Commands

| Command | Description |
|---------|-------------|
| `:Overleaf` | Connect (or show status if connected) |
| `:Overleaf connect` | Connect to Overleaf |
| `:Overleaf disconnect` | Disconnect |
| `:Overleaf compile` | Compile LaTeX project |
| `:Overleaf tree` | Toggle file tree |
| `:Overleaf open` | Open a document |
| `:Overleaf projects` | Switch project |
| `:Overleaf status` | Show connection status |
| `:Overleaf preview` | Preview binary file (images, etc.) |
| `:Overleaf new [name]` | Create new document |
| `:Overleaf mkdir [name]` | Create new folder |
| `:Overleaf delete` | Delete file/folder |
| `:Overleaf rename` | Rename file/folder |
| `:Overleaf upload [path]` | Upload local file |
| `:Overleaf search [pattern]` | Search across all documents |
| `:Overleaf comments` | List all comments |
| `:Overleaf comments refresh` | Refresh comments from server |
| `:Overleaf history` | View project history |
| `:Overleaf sync` | Sync all documents to/from disk |
| `:Overleaf sync import` | Import external changes from disk to Overleaf |
| `:Overleaf sync export` | Export all documents to disk |
| `:Overleaf forwardsearch` | Jump from the cursor to the matching position in the compiled PDF (SyncTeX) |

### Default Keymaps

| Key | Description |
|-----|-------------|
| `<leader>oc` | Connect |
| `<leader>od` | Disconnect |
| `<leader>ob` | Build (compile) |
| `<leader>ot` | Toggle file tree |
| `<leader>oo` | Open document picker |
| `<leader>op` | Preview file |
| `<leader>or` | Read comment at cursor |
| `<leader>oR` | Reply to comment |
| `<leader>ox` | Resolve/reopen comment |
| `<leader>of` | Find in project (search) |
| `<leader>ov` | Forward search: jump to cursor's page in PDF (SyncTeX) |

### Tree Keymaps

| Key | Description |
|-----|-------------|
| `Enter` | Open document |
| `a` | New document |
| `A` | New folder |
| `d` | Delete |
| `r` | Rename |
| `u` | Upload file |
| `R` | Refresh tree |
| `q` | Close tree |

## Configuration

```lua
require('overleaf').setup({
  -- Path to .env file containing OVERLEAF_COOKIE (default: '.env')
  env_file = '.env',

  -- Session cookie (overrides .env)
  cookie = nil,

  -- Path to Node.js binary (default: 'node')
  node_path = 'node',

  -- Log level: 'debug', 'info', 'warn', 'error' (default: 'info')
  log_level = 'info',

  -- Local file sync directory for external tools like Claude Code (default: nil = disabled)
  -- When set, all documents are mirrored to disk and external changes are synced back.
  sync_dir = '~/.overleaf',

  -- Base Overleaf instance URL (default: 'https://www.overleaf.com'; set for self-hosted)
  base_url = 'https://www.overleaf.com',

  -- PDF viewer command (default: nil = auto-detect — 'open' on macOS, 'xdg-open'
  -- on Linux, 'start' on Windows). Give it SumatraPDF's full path on Windows to
  -- get SyncTeX forward search (see below).
  pdf_viewer = nil,

  -- Directory downloaded PDFs are written to (default: nil = system temp dir)
  pdf_dir = nil,

  -- SumatraPDF binary, used for SyncTeX forward search (Windows only)
  sumatra_path = 'SumatraPDF.exe',

  -- Highlight the matched text in SumatraPDF on forward search (default: true).
  -- Set to false to only scroll to the position.
  forward_search_highlight = true,

  -- Lines highlighted around the cursor: 'paragraph' (default, the block of
  -- non-blank lines the cursor is in) or a number N for N lines before and
  -- after (0 = only the cursor line).
  forward_search_range = 'paragraph',

  -- Set to false to disable default keymaps
  keys = true,
})
```

### A nicer picker (optional)

Every list in this plugin (`:Overleaf projects`, document picker, history, …) goes through `vim.ui.select`. Neovim's built-in fallback for that is a numbered list where you type a digit and press Enter. Installing a `vim.ui.select` provider — [dressing.nvim](https://github.com/stevearc/dressing.nvim), [telescope-ui-select](https://github.com/nvim-telescope/telescope-ui-select.nvim), [fzf-lua](https://github.com/ibhagwan/fzf-lua), [snacks.nvim](https://github.com/folke/snacks.nvim)'s picker, etc. — replaces it everywhere (not just in this plugin) with an interactive list you navigate with arrows/`j`/`k`/`Tab` and confirm with Enter. Simplest option:

```lua
{ 'stevearc/dressing.nvim', lazy = false, opts = {} }
```

## Workflow

1. `:Overleaf` — authenticate and select a project
2. File tree appears — press `Enter` to open a document
3. Edit normally — changes sync to Overleaf in real-time
4. `:w` — triggers compile and opens PDF
5. `:Overleaf tree` — switch between documents

## External Tool Integration (Claude Code, etc.)

By default, Overleaf documents exist only as virtual buffers — they have no files on disk. This means external tools like Claude Code cannot read or edit them.

Set `sync_dir` to enable local file mirroring:

```lua
require('overleaf').setup({
  sync_dir = '~/.overleaf',  -- or any directory
})
```

When connected to a project, all text documents are synced to `~/.overleaf/<project-name>/`. External tools can read and edit these files — changes are automatically detected and synced back to Overleaf.

### How it works

- **On connect**: all documents are fetched and written to disk
- **Neovim edits**: debounced writes keep disk files up to date
- **Remote edits**: disk files are updated when collaborators make changes
- **External edits**: file watchers detect changes and sync them to Overleaf via OT
  - For open documents: buffer is updated, triggering the normal OT pipeline
  - For closed documents: changes are sent directly via the bridge

### Commands

- `:Overleaf sync` — re-sync all documents (fetch from Overleaf and write to disk)
- `:Overleaf sync import` — import all external disk changes to Overleaf
- `:Overleaf sync export` — export all documents to disk

### Usage with Claude Code

```bash
# Start Claude Code in the sync directory
cd ~/.overleaf/My\ Project
claude
```

Claude Code can now read all your LaTeX files and make edits that sync back to Overleaf in real-time.

## SyncTeX forward search (nvim → PDF)

`:Overleaf forwardsearch` (or `<leader>ov`) jumps from the cursor in your `.tex` source to the matching position in the compiled PDF, via SumatraPDF on Windows.

Overleaf doesn't serve a compile's raw `.synctex.gz` for direct download (its own web client doesn't either — confirmed via a consistent 503), so this can't hand a local SyncTeX table to a PDF viewer's own `-forward-search`. It instead calls Overleaf's own `/project/<id>/sync/code` endpoint — the same one the web editor's "jump to PDF" button uses — which returns a page + position (`page`, `h`, `v`) directly; those are passed to SumatraPDF (see below).

### Highlighting the matched text

`sync/code` also returns the size of the matched box (`width`, `height`). SumatraPDF has no flag to draw an arbitrary rectangle, but it draws its own coloured highlight for `-forward-search` results. That only happens when it resolves the search from a local SyncTeX table. So the plugin writes a tiny one next to the PDF (`<name>.synctex`, one record covering the matched box) and calls `-forward-search` on it. This replaces the `-page`/`-scroll` call. The generated table is only used for this and never contains the real document.

A single source line often maps to a small or oddly placed box. So by default the highlight covers the whole paragraph around the cursor. `sync/code` maps one source line at a time, so the plugin asks for the first and last line of the paragraph and highlights the box that covers both. Edge lines that produce no text (`\begin{...}`, `\label{...}`) are skipped in favour of the next line inward, up to 6 tries per edge. Set `forward_search_range = 2` to highlight 2 lines before and after the cursor instead, or `0` for the cursor line only.

Limits:
- A paragraph is delimited by blank lines only, capped at 40 lines each way. Without blank lines, a `\section{...}` directly followed by text counts as part of the same block.
- If the paragraph runs across a page break, only the part on the cursor's page is highlighted.

The colour comes from SumatraPDF's own settings (Settings → Advanced Options), not from this plugin:

```
ForwardSearch [
	HighlightColor = #ffff00
	HighlightPermanent = true
]
```

By default the highlight fades after a moment. `HighlightPermanent = true` keeps it until you click in the PDF. `HighlightOffset` above 0 turns the box into a bar in the page margin instead. Set `forward_search_highlight = false` to go back to plain scrolling.

For multi-file projects where the root document lives inside a subfolder, the `file` path sent to `sync/code` has to follow synctex's own convention (the root doc's directory gets a literal `/.` segment inserted — see `to_synctex_path` in `lua/overleaf/synctex.lua`), otherwise the lookup silently returns no match for files in that same folder. Single-file projects and root-at-project-root layouts never hit this.

If forward search consistently finds no match for one particular file in a project but works for others, check which file is actually set as the project's **Main file** in Overleaf (right-click it in the web editor's file tree → "Set as Main File") — `sync/code` can only resolve lines that were part of the compiled build, so a file that isn't the root document (or `\input`/`\include`d from it) legitimately has no match.

**Inverse search (double-click in the PDF → jump in Neovim) isn't implemented at all**: SumatraPDF only invokes an external command on double-click when it has resolved the click itself from a local SyncTeX table, which isn't available here either way. The one-box table written for the highlight only covers the last forward-search result, so clicking elsewhere in the PDF still finds nothing.

### SumatraPDF reliability on Windows

`open_file` in `lua/overleaf/init.lua` doesn't rely on SumatraPDF's own instance-reuse (neither its `-reuse-instance` flag nor its `ReuseInstance` setting): on at least one Windows ARM64 machine, that mechanism reliably exited the new SumatraPDF process with code 1 instead of updating the existing window — reproduced manually outside Neovim too, so it isn't specific to this plugin's launcher. Instead the plugin tracks the window it opened for the last compile, closes it itself, and launches a plain new one, retrying with backoff if SumatraPDF exits fast (before ever showing a window) — which can still happen occasionally, most likely a race with the previous process's mutex/window not yet being released by the OS.

If you're on Windows on ARM (not just an ARM64 machine running the x64 build under emulation), get the native ARM64 build of SumatraPDF from [sumatrapdfreader.org](https://www.sumatrapdfreader.org/download-free-pdf-viewer) — the x64 build under emulation was seen to intermittently create its window without ever showing it, independent of anything this plugin does.

## How It Works

The plugin spawns a Node.js bridge process that connects to Overleaf's real-time collaboration server via Socket.IO. Edits in Neovim are converted to OT operations and sent to the server. Remote edits from other collaborators are transformed and applied to your buffer in real-time.

## Disclaimer

This is an **unofficial** plugin and is not affiliated with, endorsed by, or supported by [Overleaf](https://www.overleaf.com). It relies on Overleaf's internal real-time collaboration protocol, which is undocumented and may change at any time without notice. Such changes could cause the plugin to stop working, or in the worst case, lead to document corruption or data loss.

Overleaf maintains version history for all projects, so you can restore previous versions from the Overleaf web interface if anything goes wrong.

**Use this plugin at your own risk.** Always keep important work backed up.

## Acknowledgments

This project was developed with reference to the following projects for understanding Overleaf's real-time collaboration protocol:

- [AirLatex.vim](https://github.com/dmadisetti/AirLatex.vim) (MIT) — Neovim plugin for Overleaf by David Hartmann. Referenced for Chrome cookie extraction approach and Socket.IO connection patterns.
- [Overleaf-Workshop](https://github.com/iamhyc/Overleaf-Workshop) (AGPL-3.0) — VS Code extension for Overleaf. Referenced for protocol details including the v2 connection scheme, OT update hashing, and joinDoc parameters.

The code in this repository is an independent implementation in Lua/Node.js. No source code was directly copied from either project.

## License

MIT
